import SwiftUI
import UIKit
import CoreLocation
import Combine

@main
struct VABeachJobber: App {
    @StateObject private var session = SupabaseSessionStore()
    @StateObject private var store = AppStore()
    
    var body: some Scene {
        WindowGroup {
            RootAuthView()
                .environmentObject(session)
                .environmentObject(store)
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    
    var body: some View {
        Group {
            
            if session.isSignedIn && !session.didLoadProfile {
                
                ProgressView("Loading...")
                
            } else if session.needsNameSetup {
                
                SetNameView()
                
            } else {
                
                mainTabs
            }
        }
    }
    
    private var mainTabs: some View {
        TabView {
            if session.isAdmin {
                AdminStatusView()
                    .tabItem { Label("Status", systemImage: "dot.radiowaves.left.and.right") }
                
                AdminMapView()
                    .tabItem { Label("Map", systemImage: "map") }
                
                AdminAssignmentsView()
                    .tabItem { Label("Assign", systemImage: "person.3") }
            }
            
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "rectangle.3.group") }
            
            DriverRouteView()
                .tabItem {
                    Label("Route", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
            
            SupabasePropertiesView()
                .tabItem { Label("Properties", systemImage: "house") }
            
            LogView()
                .tabItem { Label("Log", systemImage: "clock") }
            
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar") }
        }
    }
}

// MARK: - Store (local logs for now)

@MainActor
final class AppStore: ObservableObject {
    @Published var logs: [StormLog] = []
    
    @Published var activePropertyId: UUID?
    @Published var activePropertyName: String = ""
    @Published var activeStartedAt: Date?
    @Published var activeStoppedAt: Date?
    @Published var activeService: ServiceType = .plow
    @Published var activeSeconds: Int = 0
    @Published var activeIsRunning: Bool = false
    
    @Published var currentStormName: String = ""
    @Published var stormDate: Date = .now
    @Published var rates = RateConfig()
    
    private let kActivePropertyId = "activePropertyId"
    private let kActivePropertyName = "activePropertyName"
    private let kActiveStartedAt = "activeStartedAt"
    private let kActiveStoppedAt = "activeStoppedAt"
    private let kActiveService = "activeService"
    private let kActiveIsRunning = "activeIsRunning"
    
    init() {
        restoreClockState()
    }
    
    func saveClockState() {
        UserDefaults.standard.set(activePropertyId?.uuidString, forKey: kActivePropertyId)
        UserDefaults.standard.set(activePropertyName, forKey: kActivePropertyName)
        UserDefaults.standard.set(activeStartedAt, forKey: kActiveStartedAt)
        UserDefaults.standard.set(activeStoppedAt, forKey: kActiveStoppedAt)
        UserDefaults.standard.set(activeService.rawValue, forKey: kActiveService)
        UserDefaults.standard.set(activeIsRunning, forKey: kActiveIsRunning)
    }
    
    func restoreClockState() {
        if let idString = UserDefaults.standard.string(forKey: kActivePropertyId) {
            activePropertyId = UUID(uuidString: idString)
        }
        
        activePropertyName = UserDefaults.standard.string(forKey: kActivePropertyName) ?? ""
        activeStartedAt = UserDefaults.standard.object(forKey: kActiveStartedAt) as? Date
        activeStoppedAt = UserDefaults.standard.object(forKey: kActiveStoppedAt) as? Date
        
        if let raw = UserDefaults.standard.string(forKey: kActiveService),
           let service = ServiceType(rawValue: raw) {
            activeService = service
        }
        
        activeIsRunning = UserDefaults.standard.bool(forKey: kActiveIsRunning)
        
        if activeIsRunning, let started = activeStartedAt {
            activeSeconds = max(0, Int(Date().timeIntervalSince(started)))
        }
    }
    
    func clearClockState() {
        UserDefaults.standard.removeObject(forKey: kActivePropertyId)
        UserDefaults.standard.removeObject(forKey: kActivePropertyName)
        UserDefaults.standard.removeObject(forKey: kActiveStartedAt)
        UserDefaults.standard.removeObject(forKey: kActiveStoppedAt)
        UserDefaults.standard.removeObject(forKey: kActiveService)
        UserDefaults.standard.removeObject(forKey: kActiveIsRunning)
    }
    
    struct DriverTotals: Identifiable, Hashable {
        var id: String { driver }
        let driver: String
        var openUpHours: Double
        var plowHours: Double
        var saltHours: Double
        var standbyHours: Double
        var completedJobs: Int
        
        var totalHours: Double {
            openUpHours + plowHours + saltHours + standbyHours
        }
    }
    
    func totalsByDriver() -> [DriverTotals] {
        var dict: [String: DriverTotals] = [:]
        
        for log in logs {
            let name = log.driver.isEmpty ? "Unknown" : log.driver
            
            var t = dict[name] ?? DriverTotals(
                driver: name,
                openUpHours: 0,
                plowHours: 0,
                saltHours: 0,
                standbyHours: 0,
                completedJobs: 0
            )
            
            t.openUpHours += billableHours(log.openUpHours)
            t.plowHours += billableHours(log.plowHours)
            t.saltHours += billableHours(log.saltHours)
            t.standbyHours += billableHours(log.standbyHours)
            
            if log.status == .completed { t.completedJobs += 1 }
            dict[name] = t
        }
        
        return dict.values.sorted {
            $0.driver.localizedCaseInsensitiveCompare($1.driver) == .orderedAscending
        }
    }
    
    func billableHours(_ hours: Double) -> Double {
        guard hours > 0 else { return 0 }
        return max(hours, rates.minimumHoursPerLog)
    }
    
    func money(for totals: DriverTotals) -> Double {
        let hourly =
        totals.openUpHours * rates.openUpPerHour +
        totals.plowHours * rates.plowPerHour +
        totals.saltHours * rates.saltPerHour +
        totals.standbyHours * rates.standbyPerHour
        
        let trips = Double(totals.completedJobs) * rates.tripFee
        return hourly + trips
    }
    
    var grandTotalMoney: Double {
        totalsByDriver().reduce(0) { $0 + money(for: $1) }
    }
    
    var completedCount: Int { logs.filter { $0.status == .completed }.count }
    var skippedCount: Int { logs.filter { $0.status == .skipped }.count }
    var issueCount: Int { logs.filter { $0.status == .issue }.count }
    var totalHours: Double {
        logs.reduce(0) { $0 + $1.plowHours + $1.saltHours + $1.standbyHours }
    }
    
    func addLog(_ log: StormLog) {
        logs.insert(log, at: 0)
    }
    
    func generateCSV() -> String {
        var rows: [String] = []
        rows.append("Date,Driver,MapNumber,PlowHours,SaltHours,StandbyHours,Status,Notes")
        
        for log in logs {
            let dateString = log.date.formatted(date: .numeric, time: .shortened)
            let row = [
                dateString,
                log.driver,
                log.mapNumber,
                String(format: "%.2f", log.plowHours),
                String(format: "%.2f", log.saltHours),
                String(format: "%.2f", log.standbyHours),
                log.status.rawValue,
                log.notes.replacingOccurrences(of: ",", with: " ")
            ].joined(separator: ",")
            rows.append(row)
        }
        
        return rows.joined(separator: "\n")
    }
}

struct RateConfig: Codable, Hashable {
    var openUpPerHour: Double = 150
    var plowPerHour: Double = 150
    var saltPerHour: Double = 140
    var standbyPerHour: Double = 85
    var minimumHoursPerLog: Double = 1.0
    var tripFee: Double = 0
}

struct StormLog: Identifiable, Hashable {
    let id = UUID()
    var date: Date
    var driver: String
    var mapNumber: String
    var openUpHours: Double
    var plowHours: Double
    var saltHours: Double
    var standbyHours: Double
    var status: Status
    var notes: String
    
    enum Status: String, CaseIterable, Identifiable {
        case inProgress = "In Progress"
        case completed = "Completed"
        case skipped = "Skipped"
        case issue = "Issue"
        var id: String { rawValue }
    }
}

enum ServiceType: String, CaseIterable, Identifiable {
    case openUp = "Open Up"
    case plow = "Plow"
    case salt = "Salt"
    case standby = "Standby"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .openUp:
            return "road.lanes"
            
        case .plow:
            return "snowflake"
            
        case .salt:
            return "drop.fill"
            
        case .standby:
            return "pause.circle"
        }
    }
}

// MARK: - UI Kit

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    
    var body: some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            )
    }
}

struct StatusPill: View {
    let systemImage: String
    let text: String
    
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @EnvironmentObject var store: AppStore
    
    @State private var showLogSheet = false
    @State private var showStormSettings = false
    @State private var dashboardService: ServiceType = .openUp
    
    
    private let columns: [GridItem] = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    private var recent5: [LogRow] { Array(session.recentLogs.prefix(5)) }
    private var recentLastId: UUID? { recent5.last?.id }
    
    private func formatStormDate(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) {
            return d.formatted(date: .abbreviated, time: .omitted)
        }
        return "—"
    }
    
    private var dashboardRoute: [PropertyRow] {
        buildOptimizedRoute()
    }
    
    private var dashboardProperties: [PropertyRow] {
        dashboardRoute
    }
    
    private var routeForSelectedService: [PropertyRow] {
        dashboardRoute.filter { property in
            let s = assignmentStatus(for: property)
            
            switch dashboardService {
            case .openUp:
                return s == "accepted" || s == "pending"
                
            case .plow:
                return s == "opened_up"
                
            case .salt:
                return s == "plowed"
                
            case .standby:
                return s != "finished" && s != "declined"
            }
        }
    }
    
    private func servicePill(for property: PropertyRow) -> some View {
        let s = assignmentStatus(for: property)
        
        switch s {
        case "opened_up":
            return StatusPill(systemImage: "road.lanes", text: "Opened Up")
            
        case "plowed":
            return StatusPill(systemImage: "snowflake", text: "Plowed")
            
        case "salted":
            return StatusPill(systemImage: "drop.fill", text: "Salted")
            
        case "finished":
            return StatusPill(systemImage: "checkmark.circle", text: "Finished")
            
        default:
            return StatusPill(systemImage: "clock", text: "Assigned")
        }
    }
    
    private func latestAssignment(for property: PropertyRow) -> AssignmentRow? {
        
        guard let userId = session.userId,
              let driverId = UUID(uuidString: userId) else {
            return nil
        }
        
        return session.assignments
            .filter {
                $0.property_id == property.id &&
                $0.driver_id == driverId
            }
            .sorted {
                ($0.created_at ?? "") > ($1.created_at ?? "")
            }
            .first
    }
    
    private func assignmentStatus(for property: PropertyRow) -> String {
        guard let userId = session.userId,
              let driverId = UUID(uuidString: userId) else {
            return "accepted"
        }
        
        let matches = session.assignments.filter {
            $0.property_id == property.id &&
            $0.driver_id == driverId
        }
        
        func rank(_ status: String?) -> Int {
            switch (status ?? "accepted").lowercased() {
            case "finished": return 5
            case "salted": return 4
            case "plowed": return 3
            case "opened_up": return 2
            case "accepted": return 1
            case "pending": return 0
            case "declined": return -1
            default: return 1
            }
        }
        
        return matches
            .max { rank($0.status) < rank($1.status) }?
            .status?
            .lowercased() ?? "accepted"
    }
    
    private var nextProperty: PropertyRow? {
        routeForSelectedService.first
    }
    
    private func distanceMiles(to property: PropertyRow) -> Double? {
        guard let current = LocationManager.shared.lastLocation,
              let lat = property.latitude,
              let lon = property.longitude else {
            return nil
        }
        
        let propertyLocation = CLLocation(latitude: lat, longitude: lon)
        let meters = current.distance(from: propertyLocation)
        
        return meters / 1609.344
    }
    
    private func buildOptimizedRoute() -> [PropertyRow] {
        
        let activeAssigned = session.assignedProperties.filter { p in
            guard p.latitude != nil,
                  p.longitude != nil else {
                return false
            }
            
            let s = assignmentStatus(for: p)
            
            return s != "finished" &&
            s != "declined"
        }
        
        guard let current = LocationManager.shared.lastLocation else {
            return activeAssigned
        }
        
        var remaining = activeAssigned
        var route: [PropertyRow] = []
        var currentLocation = current
        
        while !remaining.isEmpty {
            guard let nearest = remaining.min(by: { a, b in
                distance(from: currentLocation, to: a) <
                    distance(from: currentLocation, to: b)
            }) else { break }
            
            route.append(nearest)
            remaining.removeAll { $0.id == nearest.id }
            
            if let lat = nearest.latitude,
               let lon = nearest.longitude {
                currentLocation = CLLocation(latitude: lat, longitude: lon)
            }
        }
        
        return route
    }
    
    private func distance(from location: CLLocation, to property: PropertyRow) -> CLLocationDistance {
        guard let lat = property.latitude,
              let lon = property.longitude else {
            return .greatestFiniteMagnitude
        }
        
        return location.distance(from: CLLocation(latitude: lat, longitude: lon))
    }
    
    private func formatTime(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    
    private func openInMaps(name: String, address: String) {
        let query = "\(name), \(address)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if store.activeIsRunning || store.activeStartedAt != nil {
                        
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                
                                HStack {
                                    Label("ACTIVE JOB", systemImage: "bolt.fill")
                                        .font(.headline)
                                        .foregroundStyle(.green)
                                    
                                    Spacer()
                                    
                                    StatusPill(
                                        systemImage: store.activeIsRunning ? "play.fill" : "pause.fill",
                                        text: store.activeIsRunning ? "Running" : "Stopped"
                                    )
                                }
                                
                                Text(store.activePropertyName)
                                    .font(.title3.bold())
                                
                                Text(store.activeService.rawValue)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                
                                Text(formatTime(store.activeSeconds))
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                
                                if let started = store.activeStartedAt {
                                    Text("Started \(started.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                NavigationLink {
                                    LogJobSheet(
                                        initialService: store.activeService,
                                        initialProperty: session.assignedProperties.first {
                                            $0.id == store.activePropertyId
                                        }
                                    )
                                } label: {
                                    Label("Open Active Job", systemImage: "arrow.right.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    
                    if session.role == "driver" {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Next Stop")
                                    .font(.headline)
                                
                                Picker("Route Mode", selection: $dashboardService) {
                                    ForEach(ServiceType.allCases) { service in
                                        Text(service.rawValue).tag(service)
                                    }
                                }
                                .pickerStyle(.segmented)
                                
                                if let next = nextProperty {
                                    Text("Map #\(next.map_number) • \(next.name)")
                                        .font(.title2.weight(.semibold))
                                    
                                    Text(next.address)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    
                                    Button {
                                        openInMaps(name: next.name, address: next.address)
                                    } label: {
                                        Label("Start Navigation", systemImage: "map")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Text("No \(dashboardService.rawValue) stops left.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(dashboardService.rawValue) Route")
                                    .font(.headline)
                                
                                if routeForSelectedService.isEmpty {
                                    Text("No \(dashboardService.rawValue) stops left.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(Array(routeForSelectedService.prefix(6).enumerated()), id: \.element.id) { index, p in
                                        HStack {
                                            Text("\(index + 1).")
                                                .font(.caption.weight(.bold))
                                            
                                            VStack(alignment: .leading) {
                                                Text("Map #\(p.map_number) • \(p.name)")
                                                    .font(.subheadline.weight(.semibold))
                                                Text(p.address)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            
                                            Spacer()
                                            
                                            Button {
                                                openInMaps(name: p.name, address: p.address)
                                            } label: {
                                                Image(systemName: "map")
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                        
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                        }
                    }
                    
                    stormCard
                    assignedCard
                    
                    LazyVGrid(columns: columns, spacing: 14) {
                        StatTile(title: "Completed", value: "\(session.dashboardTotals.completed)", systemImage: "checkmark.circle")
                        StatTile(title: "Issues", value: "\(session.dashboardTotals.issues)", systemImage: "exclamationmark.triangle")
                        StatTile(title: "Skipped", value: "\(session.dashboardTotals.skipped)", systemImage: "minus.circle")
                        StatTile(title: "Total Hours", value: String(format: "%.1f", session.dashboardTotals.totalHours), systemImage: "clock")
                    }
                    
                    recentCard
                }
                .padding(16)
            }
            .navigationTitle("Snow")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { session.signOut() } label: {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
            .task {
                LocationManager.shared.requestPermission()
                LocationManager.shared.start()
                
                if store.activeIsRunning {
                    
                    await session.updateMyDriverStatus(
                        status: "working",
                        activePropertyId: store.activePropertyId,
                        activeService: store.activeService.rawValue,
                        startedAt: store.activeStartedAt
                    )
                }
                
                await session.refreshDashboard()
                await session.refreshAssignedProperties()
            }
            .sheet(isPresented: $showLogSheet, onDismiss: {
                Task {
                    await session.refreshDashboard()
                    await session.refreshAssignedProperties()
                }
            }) {
                LogJobSheet(
                    initialService: dashboardService,
                    initialProperty: nextProperty
                )
            }
            .sheet(isPresented: $showStormSettings) {
                StormSettingsSheet()
                    .environmentObject(session)
            }
            .refreshable {
                await session.refreshDashboard()
                await session.refreshAssignedProperties()
            }
        }
    }
    
    private var stormCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Current Storm", systemImage: "cloud.snow")
                        .font(.headline)
                    Spacer()
                    StatusPill(systemImage: "bolt.fill", text: "Active")
                    
                    Text("Role: \(session.role ?? "nil")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(session.activeStorm?.name ?? "No active storm")
                    .font(.title2.weight(.semibold))
                
                Text(formatStormDate(session.activeStorm?.created_at))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 10) {
                    Button {
                        showStormSettings = true
                    } label: {
                        Label("Storm Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    
                    Button { showLogSheet = true } label: {
                        Label("Log Job", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var assignedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Assigned Properties")
                    .font(.headline)
                
                
                if session.activeStorm?.is_closed == true {
                    
                    Text("Storm ended. No active jobs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                } else if session.assignedProperties.isEmpty {
                    
                    Text("None assigned yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                } else {
                    
                    let activeProperties = Array(dashboardProperties.prefix(6))
                    
                    let finishedProperties = session.assignedProperties.filter { p in
                        guard let userId = session.userId,
                              let driverId = UUID(uuidString: userId) else {
                            return false
                        }
                        
                        return session.assignments.contains {
                            $0.property_id == p.id &&
                            $0.driver_id == driverId &&
                            $0.status == "finished"
                        }
                    }
                    
                    ForEach(activeProperties) { p in
                        Text("Map #\(p.map_number) • \(p.name)")
                            .font(.subheadline.weight(.semibold))
                        Text(p.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        servicePill(for: p)
                        
                        if let userId = session.userId,
                           let myDriverId = UUID(uuidString: userId),
                           let assignment = session.assignments.first(where: {
                               $0.property_id == p.id &&
                               $0.driver_id == myDriverId &&
                               $0.status == "pending"
                           }) {
                            
                            HStack {
                                Button {
                                    Task {
                                        try? await session.confirmAssignment(
                                            assignmentId: assignment.id,
                                            accepted: true
                                        )
                                        
                                        await session.refreshDashboard()
                                        await session.refreshAssignedProperties()
                                    }
                                } label: {
                                    Label("Accept", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                
                                Button(role: .destructive) {
                                    Task {
                                        try? await session.confirmAssignment(
                                            assignmentId: assignment.id,
                                            accepted: false
                                        )
                                        
                                        await session.refreshDashboard()
                                        await session.refreshAssignedProperties()
                                    }
                                } label: {
                                    Label("Decline", systemImage: "xmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        
                        HStack {
                            if let miles = distanceMiles(to: p) {
                                Text("\(miles, specifier: "%.1f") mi")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                openInMaps(name: p.name, address: p.address)
                            } label: {
                                Label("Navigate", systemImage: "map")
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        if p.id != dashboardProperties.prefix(6).last?.id {
                            Divider().opacity(0.6)
                        }
                    }
                    if !finishedProperties.isEmpty {
                        
                        Divider()
                            .padding(.vertical, 6)
                        
                        Text("Finished This Pass")
                            .font(.headline)
                        
                        ForEach(finishedProperties) { p in
                            
                            HStack {
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    
                                    Text("Map #\(p.map_number) • \(p.name)")
                                        .font(.subheadline.weight(.semibold))
                                    
                                    Text(p.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Button {
                                    Task {
                                        
                                        guard let stormId = session.activeStorm?.id,
                                              let userId = session.userId,
                                              let driverId = UUID(uuidString: userId)
                                        else { return }
                                        
                                        try? await session.updateAssignmentStatus(
                                            stormId: stormId,
                                            propertyId: p.id,
                                            driverId: driverId,
                                            status: "accepted"
                                        )
                                        
                                        await session.refreshDashboard()
                                        await session.refreshAssignedProperties()
                                    }
                                } label: {
                                    
                                    Label("Log Again", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }
    
    private var recentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Activity")
                    .font(.headline)
                
                ForEach(recent5) { log in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            
                            let driverLabel = log.profiles?.name ?? "—"
                            
                            Text("Map #\(log.properties?.map_number ?? "—") • \(driverLabel)")
                                .font(.subheadline.weight(.semibold))
                            
                            Text((log.notes ?? "").isEmpty ? "—" : (log.notes ?? "—"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        let serviceLabel = log.service ?? "Job"
                        let statusLabel = log.status ?? "—"
                        
                        StatusPill(
                            systemImage: "clock",
                            text: "\(serviceLabel) • \(statusLabel)"
                        )
                    }
                    
                    if log.id != recentLastId {
                        Divider().opacity(0.6)
                    }
                }
            }
        }
    }
}

struct StormSettingsSheet: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showEndConfirm = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            
                            Text("Current Storm")
                                .font(.headline)
                            
                            Text(session.activeStorm?.name ?? "No active storm")
                                .font(.title2.weight(.semibold))
                            
                            Text("End storm keeps logs and reports, but clears live driver statuses.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Card {
                        Button(role: .destructive) {
                            showEndConfirm = true
                        } label: {
                            Label("End Storm / Close Out", systemImage: "xmark.octagon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button {
                            Task {
                                await session.reopenActiveStorm()
                                dismiss()
                            }
                        } label: {
                            Label("Reopen Storm", systemImage: "arrow.uturn.backward.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Storm Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("End this storm?", isPresented: $showEndConfirm) {
                
                Button("Cancel", role: .cancel) { }
                
                Button("End Storm", role: .destructive) {
                    Task {
                        await session.endActiveStorm()
                        dismiss()
                    }
                }
                
            } message: {
                Text("This will close the storm and clear live driver statuses.")
            }
        }
    }
}

// MARK: - Log Placeholder

struct LogView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Logging Screen")
                    .font(.title3.weight(.semibold))
                Text("Use Dashboard → Log Job for now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Log")
        }
    }
}

// MARK: - Reports

struct ReportsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var session: SupabaseSessionStore
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var showRates = false
    
    @State private var showPDFPreview = false
    @State private var previewId = UUID()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    
                    InvoiceSummaryCard(showRates: $showRates)
                    
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Driver Totals")
                                .font(.headline)
                            
                            ForEach(store.totalsByDriver()) { t in
                                VStack(spacing: 10) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(t.driver)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(currency(store.money(for: t)))
                                            .font(.subheadline.weight(.semibold))
                                            .monospacedDigit()
                                    }
                                    
                                    HStack {
                                        metric("Open Up", t.openUpHours)
                                        metric("Plow", t.plowHours)
                                        metric("Salt", t.saltHours)
                                        metric("Standby", t.standbyHours)
                                        Spacer()
                                        Text("\(t.completedJobs) jobs")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                if t.id != store.totalsByDriver().last?.id {
                                    Divider().opacity(0.6)
                                }
                            }
                        }
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Export")
                                .font(.headline)
                            
                            Button {
                                exportPDF()
                            } label: {
                                Label("Export Current Storm PDF", systemImage: "doc.richtext")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Reports")
            .sheet(isPresented: $showShare) {
                if let url = exportURL { ActivityView(activityItems: [url]) }
            }
            .sheet(isPresented: $showPDFPreview) {
                if let url = exportURL {
                    PDFPreview(url: url)
                        .id(previewId)
                } else {
                    Text("No PDF found")
                }
            }
            .sheet(isPresented: $showRates) { RatesSheet() }
        }
    }
    
    private var supabaseInvoiceTotal: Double {
        session.recentLogs.reduce(0) { total, log in
            let hours = Double(log.seconds ?? 0) / 3600.0
            let billable = hours > 0 ? max(hours, store.rates.minimumHoursPerLog) : 0
            let service = (log.service ?? "").lowercased()
            
            if service == "open up" {
                return total + billable * store.rates.openUpPerHour
            } else if service == "plow" {
                return total + billable * store.rates.plowPerHour
            } else if service == "salt" {
                return total + billable * store.rates.saltPerHour
            } else if service == "standby" {
                return total + billable * store.rates.standbyPerHour
            } else {
                return total
            }
        }
    }
    
    private func exportPDF() {
        
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 612, height: 792)
        )
        
        let data = renderer.pdfData { ctx in
            
            ctx.beginPage()
            
            let title = "Snow Storm Report"
            let storm = session.activeStorm?.name ?? "Unknown Storm"
            
            let text = """
        \(title)
        
        Storm:
        \(storm)
        
        Total Logs:
        \(session.recentLogs.count)
        
        Completed:
        \(session.dashboardTotals.completed)
        
        Issues:
        \(session.dashboardTotals.issues)
        
        Skipped:
        \(session.dashboardTotals.skipped)
        
        Total Hours:
        \(String(format: "%.1f", session.dashboardTotals.totalHours))
        
        Total Invoice:
        \(currency(supabaseInvoiceTotal))
        """
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20)
            ]
            
            text.draw(
                in: CGRect(x: 40, y: 40, width: 520, height: 700),
                withAttributes: attrs
            )
        }
        
        let filename = "StormReport.pdf"
        
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(filename)
        
        do {
            try data.write(to: url)
            
            exportURL = url
            previewId = UUID()
            showPDFPreview = true
            
        } catch {
            print("PDF export failed:", error)
        }
    }
    
    private func metric(_ label: String, _ hours: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f h", hours))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
    
    private func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSNumber(value: value)) ?? "$0.00"
    }
    
    private func exportCSV() {
        let csv = store.generateCSV()
        let filename = "\(store.currentStormName.replacingOccurrences(of: " ", with: "_")).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        do {
            try csv.write(to: tempURL, atomically: true, encoding: .utf8)
            exportURL = tempURL
            showShare = true
        } catch {
            print("Export failed:", error)
        }
    }
}

struct InvoiceSummaryCard: View {
    @EnvironmentObject var store: AppStore
    @Binding var showRates: Bool
    
    private var totalHoursFormatted: String { String(format: "%.1f", store.totalHours) }
    
    private var moneyFormatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSNumber(value: store.grandTotalMoney)) ?? "$0.00"
    }
    
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Invoice Summary").font(.headline)
                
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Total Logs: \(store.logs.count)")
                        Text("Total Hours: \(totalHoursFormatted)")
                        Text("Completed: \(store.completedCount)")
                        Text("Issues: \(store.issueCount)")
                        Text("Skipped: \(store.skippedCount)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text(moneyFormatted)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }
                
                Button { showRates = true } label: {
                    Label("Rates", systemImage: "dollarsign.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Log Job Sheet (Supabase PropertyRow)

struct LogJobSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var session: SupabaseSessionStore
    
    let initialService: ServiceType
    let initialProperty: PropertyRow?
    
    @State private var selectedProperty: PropertyRow?
    @State private var service: ServiceType
    
    @State private var driverName: String = ""
    @State private var notes: String = ""
    
    @State private var status: StormLog.Status = .completed
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var showSaveError = false
    @State private var lastGPSUpload = Date.distantPast
    
    init(
        initialService: ServiceType = .openUp,
        initialProperty: PropertyRow? = nil
    ) {
        self.initialService = initialService
        self.initialProperty = initialProperty
        
        _service = State(initialValue: initialService)
        _selectedProperty = State(initialValue: initialProperty)
    }
    
    private var selectedPropertyId: UUID? {
        store.activePropertyId ?? selectedProperty?.id
    }
    
    private var currentSeconds: Int {
        store.activeSeconds
    }
    
    private var startedAt: Date? {
        store.activeStartedAt
    }
    
    private var stoppedAt: Date? {
        store.activeStoppedAt
    }
    
    private var isRunning: Bool {
        store.activeIsRunning
    }
    
    private var hours: Double { Double(currentSeconds) / 3600.0 }
    private var billable: Double { store.billableHours(hours) }
    
    private var canSave: Bool {
        guard selectedProperty != nil else { return false }
        
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch status {
        case .completed:
            return currentSeconds > 0
        case .issue:
            return !trimmedNotes.isEmpty
        case .skipped:
            return true
        default:
            return currentSeconds > 0
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Property").font(.headline)
                            AssignedPropertyPicker(selected: $selectedProperty)
                        }
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Job").font(.headline)
                            
                            Picker("Service", selection: $service) {
                                ForEach(ServiceType.allCases) { s in
                                    Label(s.rawValue, systemImage: s.icon).tag(s)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            TextField("Driver", text: $driverName)
                                .textInputAutocapitalization(.words)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Status").font(.headline)
                            
                            Picker("Status", selection: $status) {
                                Text("Completed").tag(StormLog.Status.completed)
                                Text("Issue").tag(StormLog.Status.issue)
                                Text("Skipped").tag(StormLog.Status.skipped)
                            }
                            .pickerStyle(.segmented)
                            
                            Button(role: .destructive) {
                                status = .issue
                                
                                Task {
                                    await session.updateMyDriverStatus(
                                        status: "issue",
                                        activePropertyId: store.activePropertyId,
                                        activeService: store.activeService.rawValue,
                                        startedAt: store.activeStartedAt,
                                        notes: notes.isEmpty ? "Driver reported an issue" : notes
                                    )
                                }
                            } label: {
                                Label("Report Issue to Admin", systemImage: "exclamationmark.triangle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.activePropertyId == nil)
                            
                            if status == .issue {
                                Text("Add a note explaining the issue (required).")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if status == .skipped {
                                Text("Skipped logs save with 0 time.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if status == .completed && currentSeconds == 0 {
                                Text("Start the timer to save as Completed.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            
                            HStack {
                                Text(formatTime(currentSeconds))
                                    .font(.title2.weight(.semibold))
                                    .monospacedDigit()
                                
                                Spacer()
                                
                                StatusPill(
                                    systemImage: store.activeIsRunning ? "bolt.fill" : "pause",
                                    text: store.activeIsRunning ? "Running" : "Stopped"
                                )
                            }
                            
                            if !store.activePropertyName.isEmpty {
                                Text("Property: \(store.activePropertyName)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            
                            Text("Service: \(store.activeService.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if let startedAt {
                                Text("Started: \(startedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if let stoppedAt {
                                Text("Stopped: \(stoppedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            HStack(spacing: 10) {
                                Button {
                                    if isRunning { stopTimer() } else { startTimer() }
                                } label: {
                                    Label(isRunning ? "Stop" : "Start", systemImage: isRunning ? "stop.fill" : "play.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(selectedProperty == nil && !isRunning)
                                
                                Button { resetTimer() } label: {
                                    Label("Reset", systemImage: "arrow.counterclockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(isRunning || currentSeconds == 0)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(format: "Raw: %.2f h", hours))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                
                                Text(String(format: "Billable (min %.0f h): %.2f h",
                                            store.rates.minimumHoursPerLog, billable))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            }
                        }
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notes").font(.headline)
                            TextField("Gate code, issues, special instructions…", text: $notes, axis: .vertical)
                                .lineLimit(3...6)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Log Job")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        store.activeIsRunning
                        ? "Stop Clock First"
                        : (isSaving ? "Saving…" : "Save")
                    ) {
                        Task { await saveTapped() }
                    }
                    .disabled(
                        !canSave ||
                        isSaving ||
                        store.activeIsRunning
                    )
                }
            }
            .alert("Save failed", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveError ?? "Unknown error")
            }
        }
        .task {
            // ensures picker has data even if user opened sheet fast
            await session.refreshAssignedProperties()
        }
        .onAppear {
            if driverName.isEmpty { driverName = session.displayName ?? "" }
            LocationManager.shared.requestPermission()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard store.activeIsRunning else { return }
            guard let started = store.activeStartedAt else { return }
            
            store.activeSeconds = max(0, Int(Date().timeIntervalSince(started)))
            
            guard Date().timeIntervalSince(lastGPSUpload) >= 15 else { return }
            lastGPSUpload = Date()
            
            if let loc = LocationManager.shared.lastLocation {
                Task {
                    await session.updateMyDriverStatus(
                        status: "working",
                        activePropertyId: store.activePropertyId,
                        activeService: store.activeService.rawValue,
                        startedAt: store.activeStartedAt,
                        notes: notes,
                        lat: loc.coordinate.latitude,
                        lon: loc.coordinate.longitude
                    )
                }
            }
        }
    }
    
    private func startTimer() {
        
        guard let property = selectedProperty else { return }
        guard !store.activeIsRunning else { return }
        
        store.activePropertyId = property.id
        store.activePropertyName = property.name
        store.activeService = service
        
        if store.activeStartedAt == nil {
            store.activeStartedAt = Date()
        }
        
        store.activeStoppedAt = nil
        store.activeIsRunning = true
        store.saveClockState()
        
        LocationManager.shared.start()
        
        print("👤 Current session userId:", session.userId ?? "nil")
        print("👤 Current displayName:", session.displayName ?? "nil")
        
        Task {
            await session.updateMyDriverStatus(
                status: "working",
                activePropertyId: store.activePropertyId,
                activeService: store.activeService.rawValue,
                startedAt: store.activeStartedAt
            )
        }
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func stopTimer() {
        
        guard store.activeIsRunning else { return }
        
        store.activeStoppedAt = Date()
        
        if let started = store.activeStartedAt {
            store.activeSeconds = max(
                0,
                Int(Date().timeIntervalSince(started))
            )
        }
        
        store.activeIsRunning = false
        store.saveClockState()
        
        LocationManager.shared.stop()
        
        Task {
            await session.updateMyDriverStatus(
                status: "stopped",
                activePropertyId: store.activePropertyId,
                activeService: store.activeService.rawValue,
                startedAt: store.activeStartedAt
            )
        }
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func resetTimer() {
        store.activePropertyId = nil
        store.activePropertyName = ""
        store.activeSeconds = 0
        store.activeStartedAt = nil
        store.activeStoppedAt = nil
        store.activeIsRunning = false
        store.activeService = .plow
        store.clearClockState()
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    @MainActor
    private func saveTapped() async {
        let activeId = store.activePropertyId ?? selectedProperty?.id
        
        guard let p = session.assignedProperties.first(where: { $0.id == activeId }) ?? selectedProperty else {
            saveError = "No active property found."
            showSaveError = true
            return
        }
        guard let stormId = session.activeStorm?.id else {
            saveError = "No active storm."
            showSaveError = true
            return
        }
        
        // ✅ driver id — this is the #1 reason it “does nothing”
        guard let driverId = uuidFromString(session.userId) else {
            saveError = "Missing/invalid driver id (session.userId)."
            showSaveError = true
            return
        }
        
        let driverNameToSave =
        driverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? (session.displayName ?? "Unknown")
        : driverName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let notesToSave = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let effectiveSeconds = (status == .skipped) ? 0 : currentSeconds
        let rawHours = Double(currentSeconds) / 3600.0
        let effectiveHours = (status == .skipped) ? 0 : rawHours
        
        isSaving = true
        defer { isSaving = false }
        
        do {
            if isRunning {
                stopTimer()
            }
            
            if status == .completed && store.activeStoppedAt == nil {
                store.activeStoppedAt = Date()
            }
            
            try await session.createLogToSupabase(
                stormId: stormId,
                propertyId: p.id,
                driverId: driverId,
                service: service.rawValue,
                seconds: effectiveSeconds,
                status: status.rawValue,
                notes: notesToSave,
                startedAt: store.activeStartedAt,
                stoppedAt: store.activeStoppedAt
            )
            
            if status == .completed {
                
                let nextAssignmentStatus: String
                
                switch service {
                case .openUp:
                    nextAssignmentStatus = "opened_up"
                    
                case .plow:
                    nextAssignmentStatus = "plowed"
                    
                case .salt:
                    nextAssignmentStatus = "salted"
                    
                case .standby:
                    nextAssignmentStatus = "accepted"
                }
                
                try? await session.updateAssignmentStatus(
                    stormId: stormId,
                    propertyId: p.id,
                    driverId: driverId,
                    status: nextAssignmentStatus
                )
                
            } else {
                
                try? await session.updateAssignmentStatus(
                    stormId: stormId,
                    propertyId: p.id,
                    driverId: driverId,
                    status: "accepted"
                )
            }
            
            // refresh supabase-driven dashboard tiles
            await session.refreshAssignedProperties()
            await session.refreshDashboard()
            
            if let stormId = session.activeStorm?.id ?? session.activeStormId {
                do {
                    session.assignments = try await session.fetchAssignments(stormId: stormId)
                } catch {
                    print("Refresh assignments failed:", error)
                }
            }
            
            // optional local log
            let openUp = (service == .openUp) ? effectiveHours : 0
            let plow = (service == .plow) ? effectiveHours : 0
            let salt = (service == .salt) ? effectiveHours : 0
            let standby = (service == .standby) ? effectiveHours : 0
            
            store.addLog(
                StormLog(
                    date: .now,
                    driver: driverNameToSave,
                    mapNumber: p.map_number,
                    openUpHours: openUp,
                    plowHours: plow,
                    saltHours: salt,
                    standbyHours: standby,
                    status: status,
                    notes: notesToSave
                )
            )
            
            Task {
                await session.updateMyDriverStatus(
                    status: "idle",
                    activePropertyId: nil,
                    activeService: nil,
                    startedAt: nil
                )
            }
            
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            store.activePropertyId = nil
            store.activePropertyName = ""
            store.activeStartedAt = nil
            store.activeStoppedAt = nil
            store.activeSeconds = 0
            store.activeIsRunning = false
            store.activeService = .plow
            store.clearClockState()
            dismiss()
            
        } catch {
            saveError = error.localizedDescription
            showSaveError = true
        }
    }
    
    private func formatTime(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    private func uuidFromString(_ s: String?) -> UUID? {
        guard let s = s, !s.isEmpty else { return nil }
        if let u = UUID(uuidString: s) { return u }
        
        // handle 32-char UUID without hyphens
        let clean = s.replacingOccurrences(of: "-", with: "")
        guard clean.count == 32 else { return nil }
        
        let parts = [
            clean.prefix(8),
            clean.dropFirst(8).prefix(4),
            clean.dropFirst(12).prefix(4),
            clean.dropFirst(16).prefix(4),
            clean.dropFirst(20).prefix(12)
        ]
        let hyphenated = parts.map(String.init).joined(separator: "-")
        return UUID(uuidString: hyphenated)
    }
}

// MARK: - Picker (assigned only)

struct AssignedPropertyPicker: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @Binding var selected: PropertyRow?
    @State private var search = ""
    
    private var filtered: [PropertyRow] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return session.assignedProperties
            .filter { $0.active }
            .filter { p in
                guard !q.isEmpty else { return true }
                return p.map_number.lowercased().contains(q)
                || p.name.lowercased().contains(q)
                || p.address.lowercased().contains(q)
            }
            .sorted { ($0.priority == "high" && $1.priority != "high") }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            TextField("Search map #, name, address", text: $search)
                .textFieldStyle(.roundedBorder)
            
            Menu {
                ForEach(filtered) { p in
                    Button { selected = p } label: {
                        Text("Map #\(p.map_number) • \(p.name)")
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedLabel)
                            .font(.subheadline.weight(.semibold))
                        Text(selectedSub)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                )
            }
        }
    }
    
    private var selectedLabel: String {
        if let s = selected { return "Map #\(s.map_number) • \(s.name)" }
        return "Choose a property"
    }
    
    private var selectedSub: String {
        if let s = selected { return s.address }
        return "Assigned properties only"
    }
}

// MARK: - Share Sheet

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

import QuickLook

struct PDFPreview: UIViewControllerRepresentable {
    
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        
        return controller
    }
    
    func updateUIViewController(
        _ uiViewController: QLPreviewController,
        context: Context
    ) { }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }
    
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        
        let url: URL
        
        init(url: URL) {
            self.url = url
        }
        
        func numberOfPreviewItems(
            in controller: QLPreviewController
        ) -> Int {
            1
        }
        
        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            
            url as NSURL
        }
    }
}

// MARK: - Rates

struct RatesSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Hourly Rates").font(.headline)
                            rateField("Minimum per log (hours)", value: $store.rates.minimumHoursPerLog)
                            rateField("Open Up / hr", value: $store.rates.openUpPerHour)
                            rateField("Plow / hr", value: $store.rates.plowPerHour)
                            rateField("Salt / hr", value: $store.rates.saltPerHour)
                            rateField("Standby / hr", value: $store.rates.standbyPerHour)
                        }
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Optional Trip Fee").font(.headline)
                            Text("Adds a fixed charge per completed job log.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            rateField("Trip Fee", value: $store.rates.tripFee)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Rates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func rateField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
        }
    }
}
