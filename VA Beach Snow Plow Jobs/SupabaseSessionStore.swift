import Foundation
import SwiftUI
import Combine

@MainActor
final class SupabaseSessionStore: ObservableObject {
    
    // Session
    @Published var accessToken: String?
    @Published var refreshToken: String?
    @Published var userId: String?
    
    // UI
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var displayName: String?   // <-- add near other @Published vars
    @Published var needsNameSetup = false // <-- add near other @Published vars
    // MARK: - Admin: Drivers / Properties / Storms / Assignments
    @Published var driverStatuses: [DriverStatusRow] = []
    @Published var dashboardTotals = DashboardTotals()
    @Published var assignedProperties: [PropertyRow] = []
    
    @Published var activeStormId: UUID?
    @Published var role: String? = nil
    var isAdmin: Bool { role == "admin" }
    
    @Published var activeStorm: StormRow?
    @Published var recentLogs: [LogRow] = []
    
    @Published var assignments: [AssignmentRow] = []
    @Published var didLoadProfile = false
    
    @Published var driverGroups: [DriverGroupRow] = []
    @Published var selectedGroupId: UUID?
    @Published var groupMembers: [DriverGroupMemberRow] = []
    
    struct DashboardTotals {
        var completed = 0
        var issues = 0
        var skipped = 0
        var totalHours: Double = 0
    }
    
    func emailFromUsername(_ username: String) -> String {
        
        let clean = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        
        // REAL EMAIL → use directly
        if clean.contains("@") {
            return clean
        }
        
        // USERNAME → fake local email
        return clean.replacingOccurrences(of: " ", with: "")
        + "@vabeachsnow.local"
    }
    
    func updateUserRole(userId: UUID, role: String) async throws {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/profiles")!
        c.query = "id=eq.\(userId.uuidString)"
        
        var req = try authedRequest(url: c.url!, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        
        let body: [String: String] = [
            "role": role
        ]
        
        req.httpBody = try JSONSerialization.data(
            withJSONObject: body,
            options: []
        )
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "updateUserRole",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8) ?? "Role update failed"
                ]
            )
        }
    }
    
    func updatePropertyCoordinates(
        propertyId: UUID,
        latitude: Double,
        longitude: Double
    ) async throws {
        
        guard let token = accessToken else { return }
        
        let url = URL(
            string:
                "\(SupabaseConfig.url)/rest/v1/properties?id=eq.\(propertyId.uuidString)"
        )!
        
        var req = URLRequest(url: url)
        
        req.httpMethod = "PATCH"
        
        req.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        
        req.setValue(
            SupabaseConfig.anonKey,
            forHTTPHeaderField: "apikey"
        )
        
        req.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        
        let body: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude
        ]
        
        req.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )
        
        let (_, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
    
    func updateAssignmentStatus(
        stormId: UUID,
        propertyId: UUID,
        driverId: UUID,
        status: String
    ) async throws {
        
        var c = URLComponents(
            string: "\(SupabaseConfig.url)/rest/v1/assignments"
        )!
        
        c.query =
        "storm_id=eq.\(stormId.uuidString)" +
        "&property_id=eq.\(propertyId.uuidString)" +
        "&driver_id=eq.\(driverId.uuidString)"
        
        var req = try authedRequest(url: c.url!, method: "PATCH")
        
        req.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        
        req.setValue(
            "return=minimal",
            forHTTPHeaderField: "Prefer"
        )
        
        let body = [
            "status": status
        ]
        
        req.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "updateAssignmentStatus",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8)
                    ?? "Status update failed"
                ]
            )
        }
    }
    
    func setActiveStorm(_ id: UUID?) {
        activeStormId = id
        
        if let id = id {
            UserDefaults.standard.set(id.uuidString, forKey: "activeStormId")
        } else {
            UserDefaults.standard.removeObject(forKey: "activeStormId")
        }
    }
    
    func restoreActiveStorm() {
        if let str = UserDefaults.standard.string(forKey: "activeStormId"),
           let id = UUID(uuidString: str) {
            activeStormId = id
        }
    }
    
    
    func fetchDriverStatuses() async throws -> [DriverStatusRow] {
        
        var c = URLComponents(
            string: "\(SupabaseConfig.url)/rest/v1/driver_status"
        )!
        
        c.percentEncodedQuery =
        "select=driver_id,storm_id,status,active_service,started_at,last_seen,notes,current_lat,current_lon," +
        "profiles:driver_id(name)," +
        "properties:active_property_id(map_number,name)" +
        "&order=last_seen.desc"
        
        var req = try authedRequest(url: c.url!, method: "GET")
        
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "fetchDriverStatuses",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8) ?? "Error"
                ]
            )
        }
        
        return try JSONDecoder().decode(
            [DriverStatusRow].self,
            from: data
        )
    }
    
    func fetchDriverGroups() async {
        guard let token = accessToken else { return }
        
        do {
            let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/driver_groups?select=*&order=name.asc"
            )!
            
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            
            guard (200...299).contains(http.statusCode) else {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            
            let rows = try JSONDecoder().decode(
                [DriverGroupRow].self,
                from: data
            )
            
            self.driverGroups = rows
            
        } catch {
            print("fetchDriverGroups:", error)
        }
    }
    
    func createDriverGroup(name: String) async {
        guard let token = accessToken else { return }
        
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else { return }
        
        do {
            let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/driver_groups"
            )!
            
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("return=representation", forHTTPHeaderField: "Prefer")
            
            let body = [
                "name": trimmed
            ]
            
            req.httpBody = try JSONSerialization.data(
                withJSONObject: body
            )
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            
            guard (200...299).contains(http.statusCode) else {
                self.lastError = String(data: data, encoding: .utf8) ?? "Create group failed"
                print("Create group failed:", self.lastError ?? "")
                return
            }
            
            let created = try JSONDecoder().decode(
                [DriverGroupRow].self,
                from: data
            )
            
            if let g = created.first {
                driverGroups.append(g)
                selectedGroupId = g.id
            }
            
        } catch {
            print("createDriverGroup:", error)
        }
    }
    
    func updateDriverGroupName(groupId: UUID, name: String) async {
        guard let token = accessToken else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        do {
            let url = URL(string: "\(SupabaseConfig.url)/rest/v1/driver_groups?id=eq.\(groupId.uuidString)")!
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["name": trimmed]
            )
            
            let (_, http) = try await dataWithAutoRefresh(for: req)
            
            if (200...299).contains(http.statusCode) {
                await fetchDriverGroups()
            }
        } catch {
            print("updateDriverGroupName:", error)
        }
    }
    
    func deleteDriverGroup(groupId: UUID) async {
        guard let token = accessToken else { return }
        
        do {
            let url = URL(string: "\(SupabaseConfig.url)/rest/v1/driver_groups?id=eq.\(groupId.uuidString)")!
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            
            let (_, http) = try await dataWithAutoRefresh(for: req)
            
            if (200...299).contains(http.statusCode) {
                await fetchDriverGroups()
            }
        } catch {
            print("deleteDriverGroup:", error)
        }
    }
    
    func fetchGroupMembers(groupId: UUID) async {
        guard let token = accessToken else { return }
        
        do {
            let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/driver_group_members?select=*&group_id=eq.\(groupId.uuidString)"
            )!
            
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            
            guard (200...299).contains(http.statusCode) else {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            
            self.groupMembers = try JSONDecoder().decode(
                [DriverGroupMemberRow].self,
                from: data
            )
            
        } catch {
            print("fetchGroupMembers:", error)
        }
    }
    
    func saveGroupMembers(groupId: UUID, driverIds: Set<UUID>) async {
        guard let token = accessToken else { return }
        
        do {
            // delete old members
            var deleteURL = URLComponents(
                string: "\(SupabaseConfig.url)/rest/v1/driver_group_members"
            )!
            deleteURL.query = "group_id=eq.\(groupId.uuidString)"
            
            var deleteReq = URLRequest(url: deleteURL.url!)
            deleteReq.httpMethod = "DELETE"
            deleteReq.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            deleteReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            deleteReq.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            
            let (_, deleteHTTP) = try await dataWithAutoRefresh(for: deleteReq)
            
            guard (200...299).contains(deleteHTTP.statusCode) else {
                print("Delete group members failed")
                return
            }
            
            guard !driverIds.isEmpty else {
                self.groupMembers = []
                return
            }
            
            // insert new members
            let rows: [[String: Any]] = driverIds.map {
                [
                    "group_id": groupId.uuidString,
                    "driver_id": $0.uuidString
                ]
            }
            
            let url = URL(string: "\(SupabaseConfig.url)/rest/v1/driver_group_members")!
            
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("return=representation", forHTTPHeaderField: "Prefer")
            
            req.httpBody = try JSONSerialization.data(withJSONObject: rows)
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            
            guard (200...299).contains(http.statusCode) else {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            
            self.groupMembers = try JSONDecoder().decode(
                [DriverGroupMemberRow].self,
                from: data
            )
            
        } catch {
            print("saveGroupMembers:", error)
        }
    }
    
    private func authedRequest(url: URL, method: String) throws -> URLRequest {
        guard let token = accessToken else { throw NSError(domain: "Auth", code: 401) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
    
    @MainActor
    func refreshDriverStatuses() async {
        do {
            driverStatuses = try await fetchDriverStatuses()
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func updateMyDriverStatus(
        status: String,
        activePropertyId: UUID?,
        activeService: String?,
        startedAt: Date?,
        notes: String? = nil,
        lat: Double? = nil,
        lon: Double? = nil
    ) async {
        guard let userId, let driverId = UUID(uuidString: userId) else { return }
        guard let stormId = activeStorm?.id ?? activeStormId else { return }
        
        do {
            var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/driver_status")!
            c.queryItems = [URLQueryItem(name: "on_conflict", value: "driver_id")]
            
            var req = try authedRequest(url: c.url!, method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("return=minimal, resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            
            let iso = ISO8601DateFormatter()
            
            let body: [String: Any?] = [
                "driver_id": driverId.uuidString,
                "storm_id": stormId.uuidString,
                "status": status,
                "active_property_id": activePropertyId?.uuidString,
                "active_service": activeService,
                "started_at": startedAt.map { iso.string(from: $0) },
                "last_seen": iso.string(from: Date()),
                "notes": notes,
                "current_lat": lat,
                "current_lon": lon
            ]
            
            req.httpBody = try JSONSerialization.data(
                withJSONObject: body.compactMapValues { $0 },
                options: []
            )
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            
            if !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("❌ Driver status update failed:", http.statusCode, msg)
                lastError = msg
            } else {
                print("✅ Driver status updated:", status)
            }
            
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func sendDriverHeartbeat(
        status: String,
        activePropertyId: UUID?,
        activeService: String?,
        startedAt: Date?
    ) async {
        
        let location = LocationManager.shared.lastLocation
        
        await updateMyDriverStatus(
            status: status,
            activePropertyId: activePropertyId,
            activeService: activeService,
            startedAt: startedAt,
            lat: location?.coordinate.latitude,
            lon: location?.coordinate.longitude
        )
    }
    
    private func handleAuthFailure(_ http: HTTPURLResponse, bodyData: Data) {
        // NOTE:
        // We *don't* immediately sign out on JWT expired anymore.
        // Most calls will go through dataWithAutoRefresh(for:) which refreshes + retries once.
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        
        let looksExpired = body.localizedCaseInsensitiveContains("jwt expired")
        || body.localizedCaseInsensitiveContains("invalid jwt")
        || body.localizedCaseInsensitiveContains("pgrst303")
        
        if http.statusCode == 403 {
            signOut()
            lastError = "Not authorized. Please log in again."
            return
        }
        
        // If token is expired, let the caller refresh & retry.
        if http.statusCode == 401 && !looksExpired {
            // 401 for other reasons (or missing token)
            signOut()
            lastError = "Session expired. Please log in again."
        }
    }
    
    // MARK: - Refresh Token
    
    private func refreshAccessToken() async throws {
        guard let r = refreshToken, !r.isEmpty else {
            signOut()
            throw NSError(domain: "SupabaseRefresh", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Missing refresh token"])
        }
        
        let url = URL(string: "\(SupabaseConfig.url)/auth/v1/token?grant_type=refresh_token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        
        // Supabase expects JSON body with refresh_token
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": r], options: [])
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200...299).contains(http.statusCode) else {
            // refresh token invalid/expired
            signOut()
            let msg = String(data: data, encoding: .utf8) ?? "Refresh failed"
            throw NSError(domain: "SupabaseRefresh", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        persist(access: decoded.access_token, refresh: decoded.refresh_token, userId: userId)
    }
    
    /// Runs request; if JWT expired/401, refreshes once and retries.
    private func dataWithAutoRefresh(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data1, resp1) = try await URLSession.shared.data(for: req)
        let http1 = resp1 as! HTTPURLResponse
        if (200...299).contains(http1.statusCode) { return (data1, http1) }
        
        let body1 = String(data: data1, encoding: .utf8) ?? ""
        let looksExpired = http1.statusCode == 401
        && (body1.localizedCaseInsensitiveContains("jwt expired")
            || body1.localizedCaseInsensitiveContains("invalid jwt")
            || body1.localizedCaseInsensitiveContains("pgrst303"))
        
        guard looksExpired else { return (data1, http1) }
        
        // Refresh + retry once
        try await refreshAccessToken()
        
        var retry = req
        if let token = accessToken {
            retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data2, resp2) = try await URLSession.shared.data(for: retry)
        let http2 = resp2 as! HTTPURLResponse
        return (data2, http2)
    }
    
    func fetchDrivers() async throws -> [DriverRow] {
        // Admin can read all profiles (RLS allows admin)
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/profiles")!
        c.query = "select=id,name,role&order=name.asc"
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        let all = try JSONDecoder().decode([DriverRow].self, from: data)
        return all.filter {
            let role = ($0.role ?? "driver").lowercased()
            return role == "driver" || role == "admin" || role.isEmpty
        }
    }
    
    func fetchAllProperties() async throws -> [PropertyRow] {
        // Admin can read all properties (RLS allows admin)
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/properties")!
        c.query = "select=id,map_number,name,address,notes,active,priority,latitude,longitude&order=map_number.asc"
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        return try JSONDecoder().decode([PropertyRow].self, from: data)
    }
    
    // Driver: fetch ONLY the properties assigned to *me* for the current storm
    func fetchMyAssignedProperties(stormId: UUID) async throws -> [PropertyRow] {
        guard let uidStr = userId, let uid = UUID(uuidString: uidStr) else {
            throw NSError(domain: "Auth", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Missing/invalid userId"])
        }
        
        // IMPORTANT:
        // Query assignments, and embed the related property row.
        // This avoids direct read on properties when RLS blocks it.
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/assignments")!
        
        // This means: select property:properties(*)
        // and filter storm_id + driver_id
        c.query =
        "select=property:properties(id,map_number,name,address,notes,active,priority)" +
        "&storm_id=eq.\(stormId.uuidString)" +
        "&driver_id=eq.\(uid.uuidString)" +
        "&order=created_at.desc"
        
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        // If you’re using your auto-refresh wrapper, use it here:
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "fetchMyAssignedProperties", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        
        struct AssignmentWithProperty: Decodable {
            let property: PropertyRow?
        }
        
        let rows = try JSONDecoder().decode([AssignmentWithProperty].self, from: data)
        return rows.compactMap { $0.property }
    }
    
    func fetchOpenStorms() async throws -> [StormRow] {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/storms")!
        c.query = "select=id,name,is_closed&is_closed=eq.false&order=created_at.desc"
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        return try JSONDecoder().decode([StormRow].self, from: data)
    }
    
    func fetchActiveStorm() async throws -> StormRow? {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/storms")!
        c.query = "select=id,name,created_at,is_closed&is_closed=eq.false&order=created_at.desc&limit=1"
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "fetchActiveStorm", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        
        let rows = try JSONDecoder().decode([StormRow].self, from: data)
        let storm = rows.first
        
        if let id = storm?.id {
            setActiveStorm(id)   // 🔥 auto-sync
        }
        
        return storm
    }
    
    func fetchRecentLogs(limit: Int = 20) async throws -> [LogRow] {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/logs")!
        c.query = "select=id,created_at,driver_id,map_number,status,notes,seconds&order=created_at.desc&limit=\(limit)"
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "fetchRecentLogs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        
        return try JSONDecoder().decode([LogRow].self, from: data)
    }
    
    @MainActor
    func refreshAssignedProperties() async {
        guard let stormId = activeStorm?.id ?? activeStormId else {
            lastError = "No active storm id yet."
            return
        }
        
        do {
            assignedProperties = try await fetchAssignedProperties(stormId: stormId)
            assignments = try await fetchAssignments(stormId: stormId)
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    @MainActor
    func refreshDashboard() async {
        guard accessToken != nil else { return }
        
        do {
            // 1) Decide which storm is active
            if let stormId = self.activeStormId,
               let storm = try await fetchStormById(stormId),
               (storm.is_closed == false || storm.is_closed == nil) {
                
                self.activeStorm = storm
                self.activeStormId = storm.id
                
            } else {
                self.activeStorm = try await fetchActiveStorm()
            }
            
            // ✅ STEP 4 GOES RIGHT HERE (after activeStorm is chosen)
            if let id = self.activeStorm?.id {
                self.setActiveStorm(id)   // saves to UserDefaults + sets activeStormId
            }
            
            // 2) If still nil, clear dashboard
            guard let stormId = self.activeStorm?.id else {
                self.recentLogs = []
                self.dashboardTotals = .init()
                return
            }
            self.assignedProperties = try await fetchAssignedProperties(stormId: stormId)
            self.assignments = try await fetchAssignments(stormId: stormId)
            
            // 3) Load logs for that storm
            var logsURL = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/logs")!
            logsURL.query =
            "select=id,created_at,status,notes,seconds,service," +
            "profiles:driver_id(name)," +
            "properties:property_id(map_number,name,address)" +
            "&storm_id=eq.\(stormId.uuidString)" +
            "&order=created_at.desc&limit=50"
            
            var req2 = try authedRequest(url: logsURL.url!, method: "GET")
            req2.setValue("application/json", forHTTPHeaderField: "Accept")
            
            let (logData, logHTTP) = try await dataWithAutoRefresh(for: req2)
            guard (200...299).contains(logHTTP.statusCode) else {
                lastError = String(data: logData, encoding: .utf8)
                return
            }
            
            let logs = try JSONDecoder().decode([LogRow].self, from: logData)
            self.recentLogs = logs
            
            var t = DashboardTotals()
            for l in logs {
                let s = (l.status ?? "").lowercased()
                if s.contains("complete") { t.completed += 1 }
                else if s.contains("issue") { t.issues += 1 }
                else if s.contains("skip") { t.skipped += 1 }
                if let sec = l.seconds { t.totalHours += Double(sec) / 3600.0 }
            }
            self.dashboardTotals = t
            
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func createStorm(name: String) async throws -> StormRow {
        let url = URL(string: "\(SupabaseConfig.url)/rest/v1/storms")!
        var req = try authedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        
        let body: [String: Any] = ["name": name, "is_closed": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        let rows = try JSONDecoder().decode([StormRow].self, from: data)
        guard let first = rows.first else { throw NSError(domain: "createStorm", code: 0) }
        return first
    }
    
    // MARK: - Active storm helper (drivers need this)
    
    func ensureActiveStormSelected() async {
        // already set
        if activeStormId != nil { return }
        
        do {
            if let storm = try await fetchActiveStorm() {
                self.activeStorm = storm
                self.setActiveStorm(storm.id)
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }
    
    //Add Properties Admin
    func createProperty(_ body: NewPropertyBody) async throws {
        let url = URL(string: "\(SupabaseConfig.url)/rest/v1/properties")!
        var req = try authedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpBody = try JSONEncoder().encode(body)
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "createProperty", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
    }
    
    func updateProperty(_ id: UUID, body: NewPropertyBody) async throws {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/properties")!
        c.query = "id=eq.\(id.uuidString)"
        
        var req = try authedRequest(url: c.url!, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(body)
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "updateProperty",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8) ?? "Update failed"
                ]
            )
        }
    }
    
    func mapNumberExists(_ mapNumber: String) async throws -> Bool {
        let trimmed = mapNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/properties")!
        // Look up exact map_number
        c.query = "select=id&map_number=eq.\(trimmed)&limit=1"
        
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "mapNumberExists", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        
        // If any rows returned, it's a duplicate
        struct Row: Decodable { let id: UUID }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return !rows.isEmpty
    }
    
    func assignProperties(stormId: UUID, driverId: UUID, propertyIds: [UUID]) async throws {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/assignments")!
        c.queryItems = [
            URLQueryItem(name: "on_conflict", value: "storm_id,property_id,driver_id")
        ]
        
        var req = try authedRequest(url: c.url!, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // This is the key: merge on conflict instead of erroring
        req.setValue("return=minimal, resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        
        let rows: [[String: Any]] = propertyIds.map {
            [
                "storm_id": stormId.uuidString,
                "property_id": $0.uuidString,
                "driver_id": driverId.uuidString,
                "status": "pending",
                "confirmed_at": NSNull()
            ]
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: rows, options: [])
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
    }
    
    func confirmAssignment(
        assignmentId: UUID,
        accepted: Bool
    ) async throws {
        
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/assignments")!
        c.query = "id=eq.\(assignmentId.uuidString)"
        
        var req = try authedRequest(url: c.url!, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        
        let iso = ISO8601DateFormatter()
        
        let body: [String: String] = [
            "status": accepted ? "accepted" : "declined",
            "confirmed_at": iso.string(from: Date())
        ]
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "confirmAssignment",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8) ?? "Confirm failed"
                ]
            )
        }
    }
    
    @MainActor
    func unassignProperty(stormId: UUID, propertyId: UUID, driverId: UUID) async throws {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/assignments")!
        c.query = "storm_id=eq.\(stormId.uuidString)&property_id=eq.\(propertyId.uuidString)&driver_id=eq.\(driverId.uuidString)"
        
        var req = try authedRequest(url: c.url!, method: "DELETE")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "unassignProperty", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
    
    func loadProfile() async {
        guard let token = accessToken else { return }
        guard let uid = userId else { return }
        
        didLoadProfile = false
        
        do {
            let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/profiles?select=id,name,role&id=eq.\(uid)&limit=1"
            )!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            guard (200...299).contains(http.statusCode) else {
                lastError = String(data: data, encoding: .utf8)
                return
            }
            
            let rows = try JSONDecoder().decode([ProfileRow].self, from: data)
            guard let me = rows.first else {
                self.role = "driver"
                self.displayName = nil
                self.needsNameSetup = true
                self.didLoadProfile = true
                return
            }
            
            self.role = me.role ?? "driver"
            
            let name = (me.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayName = name.isEmpty ? nil : name
            self.needsNameSetup = name.isEmpty
            self.didLoadProfile = true
            
        } catch {
            lastError = error.localizedDescription
            didLoadProfile = true
        }
    }
    
    func saveDisplayName(_ name: String) async {
        guard let token = accessToken else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            guard let uid = userId, !uid.isEmpty else {
                lastError = "Missing userId (auth not loaded)"
                return
            }
            
            // UPSERT into profiles on conflict of id
            var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/profiles")!
            c.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
            
            var req = URLRequest(url: c.url!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            // This makes it "upsert" instead of erroring
            req.setValue("return=representation, resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            
            let body: [String: Any] = [
                "id": uid,
                "name": trimmed,
                "role": self.role ?? "driver"
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            
            let (data, http) = try await dataWithAutoRefresh(for: req)
            
            guard (200...299).contains(http.statusCode) else {
                lastError = String(data: data, encoding: .utf8) ?? "Save name failed"
                return
            }
            
            self.displayName = trimmed
            self.needsNameSetup = false
            
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    // UserDefaults keys
    private let kAccess = "sb_access"
    private let kRefresh = "sb_refresh"
    private let kUserId = "sb_userid"
    
    init() {
        restore()
        restoreActiveStorm()
        
        Task {
            await loadProfile()
            await ensureActiveStormSelected()
            await refreshDashboard()
        }
    }
    
    // MARK: - Restore / Save / Clear
    
    func restore() {
        let a = UserDefaults.standard.string(forKey: kAccess)
        let r = UserDefaults.standard.string(forKey: kRefresh)
        let u = UserDefaults.standard.string(forKey: kUserId)
        
        accessToken = a
        refreshToken = r
        userId = u
    }
    
    private func persist(access: String?, refresh: String?, userId: String?) {
        UserDefaults.standard.setValue(access, forKey: kAccess)
        UserDefaults.standard.setValue(refresh, forKey: kRefresh)
        UserDefaults.standard.setValue(userId, forKey: kUserId)
        
        self.accessToken = access
        self.refreshToken = refresh
        self.userId = userId
    }
    
    func signOut() {
        // Hard delete saved session
        UserDefaults.standard.removeObject(forKey: kAccess)
        UserDefaults.standard.removeObject(forKey: kRefresh)
        UserDefaults.standard.removeObject(forKey: kUserId)
        
        // Clear in-memory session
        accessToken = nil
        refreshToken = nil
        userId = nil
        
        // Clear profile state
        displayName = nil
        role = nil
        needsNameSetup = false
        
        // Clear UI state
        lastError = nil
        isLoading = false
    }
    
    var isSignedIn: Bool {
        guard let t = accessToken else { return false }
        return !t.isEmpty
    }
    
    // MARK: - Auth Calls (REST)
    
    func signIn(email: String, password: String) async {
        await authRequest(
            endpoint: "/auth/v1/token?grant_type=password",
            email: email,
            password: password,
            isSignup: false
        )
    }
    
    func signUp(email: String, password: String) async {
        await authRequest(
            endpoint: "/auth/v1/signup",
            email: email,
            password: password,
            isSignup: true
        )
    }
    
    
    func fetchAssignedProperties(stormId: UUID) async throws -> [PropertyRow] {
        guard let uidStr = userId, let uid = UUID(uuidString: uidStr) else {
            throw NSError(domain: "Auth", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Missing/invalid userId"])
        }
        
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/properties")!
        
        let query =
        "select=id,map_number,name,address,notes,active,priority,latitude,longitude,assignments!inner(storm_id,driver_id)" +
        "&assignments.storm_id=eq.\(stormId.uuidString)" +
        "&assignments.driver_id=eq.\(uid.uuidString)" +
        "&order=map_number.asc"
        
        c.percentEncodedQuery = query   // ✅ avoids the Swift type-check explosion
        
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "fetchAssignedProperties", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        
        struct Wrapped: Decodable {
            let id: UUID
            let map_number: String
            let name: String
            let address: String
            let notes: String
            let active: Bool
            let priority: String
            let assignments: [AssignmentMini]
            let latitude: Double?
            let longitude: Double?
            
            struct AssignmentMini: Decodable {
                let storm_id: UUID
                let driver_id: UUID
            }
            
            func toPropertyRow() -> PropertyRow {
                PropertyRow(
                    id: id,
                    map_number: map_number,
                    name: name,
                    address: address,
                    notes: notes,
                    active: active,
                    priority: priority,
                    latitude: latitude,
                    longitude: longitude
                )
            }
        }
        
        let wrapped = try JSONDecoder().decode([Wrapped].self, from: data)
        return wrapped.map { $0.toPropertyRow() }
    }
    
    func fetchStormById(_ id: UUID) async throws -> StormRow? {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/storms")!
        c.query = "select=id,name,created_at,is_closed&id=eq.\(id.uuidString)&limit=1"
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "fetchStormById", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        
        let rows = try JSONDecoder().decode([StormRow].self, from: data)
        return rows.first
    }
    
    func fetchAssignments(stormId: UUID) async throws -> [AssignmentRow] {
        var c = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/assignments")!
        c.query = "select=id,storm_id,property_id,driver_id,created_at,status,confirmed_at&storm_id=eq.\(stormId.uuidString)"
        
        var req = try authedRequest(url: c.url!, method: "GET")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        guard (200...299).contains(http.statusCode) else {
            handleAuthFailure(http, bodyData: data)
            throw NSError(domain: "API", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
        }
        return try JSONDecoder().decode([AssignmentRow].self, from: data)
    }
    
    private func authRequest(endpoint: String, email: String, password: String, isSignup: Bool) async {
        lastError = nil
        isLoading = true
        defer { isLoading = false }
        
        let url = URL(string: SupabaseConfig.url + endpoint)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        
        let body = ["email": email, "password": password]
        
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let (data, resp) = try await URLSession.shared.data(for: req)
            
            guard let http = resp as? HTTPURLResponse else {
                lastError = "No HTTP response"
                return
            }
            
            if !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = "Auth failed (\(http.statusCode)): \(msg)"
                return
            }
            
            if isSignup {
                let decoded = try JSONDecoder().decode(SignUpResponse.self, from: data)
                persist(access: decoded.access_token,
                        refresh: decoded.refresh_token,
                        userId: decoded.user?.id)
            } else {
                let decoded = try JSONDecoder().decode(SignInResponse.self, from: data)
                persist(access: decoded.access_token,
                        refresh: decoded.refresh_token,
                        userId: decoded.user.id)
            }
            
            await loadProfile()   // ✅ ALWAYS do this after persist
            
        } catch {
            lastError = error.localizedDescription
        }
    }
    @MainActor
    func createLogToSupabase(
        stormId: UUID,
        propertyId: UUID,
        driverId: UUID,
        service: String,
        seconds: Int,
        status: String,
        notes: String,
        
        startedAt: Date?,
        stoppedAt: Date?,
        
        startLat: Double? = nil,
        startLon: Double? = nil,
        
        stopLat: Double? = nil,
        stopLon: Double? = nil
    ) async throws {
        
        let url = URL(string: "\(SupabaseConfig.url)/rest/v1/logs")!
        
        var req = try authedRequest(url: url, method: "POST")
        
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        
        let iso = ISO8601DateFormatter()
        
        let body = NewLog(
            storm_id: stormId,
            property_id: propertyId,
            driver_id: driverId,
            
            service: service,
            seconds: seconds,
            status: status,
            notes: notes,
            
            started_at: startedAt.map { iso.string(from: $0) },
            stopped_at: stoppedAt.map { iso.string(from: $0) },
            
            start_lat: startLat,
            start_lon: startLon,
            
            stop_lat: stopLat,
            stop_lon: stopLon
        )
        
        req.httpBody = try JSONEncoder().encode(body)
        
        let (data, http) = try await dataWithAutoRefresh(for: req)
        
        guard (200...299).contains(http.statusCode) else {
            
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            
            handleAuthFailure(http, bodyData: data)
            
            throw NSError(
                domain: "createLogToSupabase",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }
}



