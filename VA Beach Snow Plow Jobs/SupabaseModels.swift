import Foundation
import CoreLocation

// MARK: - Auth Decoding (Supabase Auth REST)

struct SignInResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let user: SBUser
}

struct SignUpResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let user: SBUser?
}

struct RefreshResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}

struct SBUser: Decodable {
    let id: String
    let email: String?
}

// MARK: - Database Row Models

struct PropertyRow: Decodable, Identifiable {
    let id: UUID
    let map_number: String
    let name: String
    let address: String
    let notes: String
    let active: Bool
    let priority: String
    let latitude: Double?
    let longitude: Double?
    
    let gps_verified: Bool?
    let gps_problem: Bool?
}

struct StormRow: Decodable, Identifiable {
    let id: UUID
    let name: String
    let is_closed: Bool?
    let created_at: String?
    let start_at: String?
    let end_at: String?
}

struct LogRow: Decodable, Identifiable {
    let id: UUID
    let created_at: String?
    let status: String?
    let notes: String?
    let seconds: Int?
    let service: String?
    
    let profiles: DriverMini?
    let properties: PropertyMini?
    
    struct DriverMini: Decodable {
        let name: String
    }
    
    struct PropertyMini: Decodable {
        let map_number: String
        let name: String
        let address: String
    }
}

struct AssignmentRow: Decodable, Identifiable {
    let id: UUID
    let storm_id: UUID
    let property_id: UUID
    let driver_id: UUID
    let created_at: String?
    let status: String?
    let confirmed_at: String?
}

struct DriverRow: Decodable, Identifiable {
    let id: UUID
    let name: String?
    let role: String?
}

struct DriverGroupRow: Decodable, Identifiable {
    let id: UUID
    let name: String
    let created_at: String?
}

struct DriverGroupMemberRow: Decodable, Identifiable {
    let id: UUID
    let group_id: UUID
    let driver_id: UUID
    let created_at: String?
}

struct ProfileRow: Decodable {
    let id: UUID
    let name: String?
    let role: String?
}

// MARK: - Request Bodies

struct NewPropertyBody: Encodable {
    let map_number: String
    let name: String
    let address: String
    let notes: String
    let active: Bool
    let priority: String
    let latitude: Double?
    let longitude: Double?
}

// What you POST into /rest/v1/logs
struct NewLog: Encodable {
    let storm_id: UUID
    let property_id: UUID
    let driver_id: UUID
    
    let service: String
    let seconds: Int
    let status: String
    let notes: String
    
    let started_at: String?
    let stopped_at: String?
    
    let start_lat: Double?
    let start_lon: Double?
    
    let stop_lat: Double?
    let stop_lon: Double?
}

struct DriverStatusRow: Decodable, Identifiable {
    let driver_id: UUID
    let storm_id: UUID?
    let status: String?
    let active_service: String?
    let started_at: String?
    let last_seen: String?
    let notes: String?
    let current_lat: Double?
    let current_lon: Double?
    
    let profiles: DriverMini?
    let properties: PropertyMini?
    
    var id: UUID { driver_id }
    
    struct DriverMini: Decodable {
        let name: String?
    }
    
    struct PropertyMini: Decodable {
        let map_number: String?
        let name: String?
    }
}

func closestAvailableDriver(
    to property: PropertyRow,
    from drivers: [DriverStatusRow]
) -> DriverStatusRow? {
    
    guard let pLat = property.latitude,
          let pLon = property.longitude else {
        return nil
    }
    
    let propertyLocation = CLLocation(
        latitude: pLat,
        longitude: pLon
    )
    
    let driversWithLocation = drivers.filter {
        $0.current_lat != nil &&
        $0.current_lon != nil
    }
    
    let idleDrivers = driversWithLocation.filter {
        ($0.status ?? "").lowercased() == "idle"
    }
    
    let candidateDrivers =
    idleDrivers.isEmpty
    ? driversWithLocation
    : idleDrivers
    
    return candidateDrivers.min { a, b in
        
        let aLocation = CLLocation(
            latitude: a.current_lat ?? 0,
            longitude: a.current_lon ?? 0
        )
        
        let bLocation = CLLocation(
            latitude: b.current_lat ?? 0,
            longitude: b.current_lon ?? 0
        )
        
        return aLocation.distance(from: propertyLocation)
        <
            bLocation.distance(from: propertyLocation)
    }
}
