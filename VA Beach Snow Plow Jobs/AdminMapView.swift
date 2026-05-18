import SwiftUI
import MapKit
import Combine

struct AdminMapView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @State private var selectedProperty: PropertyRow?
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.8529, longitude: -75.9780),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    )
    
    private var driversWithLocation: [DriverStatusRow] {
        session.driverStatuses.filter {
            $0.current_lat != nil && $0.current_lon != nil
        }
    }
    
    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition) {
                ForEach(driversWithLocation) { row in
                    if let lat = row.current_lat,
                       let lon = row.current_lon {
                        
                        Annotation(
                            row.profiles?.name ?? "Driver",
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        ) {
                            VStack(spacing: 4) {
                                Image(systemName: icon(for: row.status))
                                    .font(.headline)
                                    .padding(8)
                                    .background(color(for: row.status))
                                    .foregroundStyle(.white)
                                    .clipShape(Circle())
                                
                                Text(row.profiles?.name ?? "Driver")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.regularMaterial)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                ForEach(session.assignedProperties) { property in
                    if let lat = property.latitude,
                       let lon = property.longitude {
                        
                        Annotation(
                            property.name,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        ) {
                            Button {
                                selectedProperty = property
                            } label: {
                                PropertyMapPin(
                                    mapNumber: property.map_number,
                                    color: propertyPinColor(property)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Live Map")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await session.refreshDriverStatuses() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await session.refreshDriverStatuses()
                centerOnFirstDriver()
            }
            .sheet(item: $selectedProperty) { property in
                PropertyDetailSheet(property: property)
                    .environmentObject(session)
            }
            .onChange(of: session.driverStatuses.count) { _, _ in
                centerOnFirstDriver()
            }
            .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
                Task { await session.refreshDriverStatuses() }
            }
        }
    }
    
    private func propertyPinColor(_ property: PropertyRow) -> Color {
        let hasIssue = session.driverStatuses.contains {
            $0.properties?.map_number == property.map_number &&
            $0.status == "issue"
        }
        
        let isWorking = session.driverStatuses.contains {
            $0.properties?.map_number == property.map_number &&
            $0.status == "working"
        }
        
        if hasIssue { return .red }
        if isWorking { return .orange }
        return .green
    }
    
    private func centerOnFirstDriver() {
        guard let first = driversWithLocation.first,
              let lat = first.current_lat,
              let lon = first.current_lon else { return }
        
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
            )
        )
    }
    
    private func icon(for status: String?) -> String {
        switch status {
        case "working": return "snowflake"
        case "issue": return "exclamationmark.triangle.fill"
        case "stopped": return "pause.fill"
        case "idle": return "circle.fill"
        default: return "questionmark"
        }
    }
    
    private func color(for status: String?) -> Color {
        switch status {
        case "working": return .green
        case "issue": return .red
        case "stopped": return .orange
        case "idle": return .gray
        default: return .gray
        }
    }
}

struct PropertyMapPin: View {
    let mapNumber: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(.white, lineWidth: 2)
                )
            
            Text(mapNumber)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial)
                .clipShape(Capsule())
        }
    }
}

struct PropertyDetailSheet: View {
    @EnvironmentObject var session: SupabaseSessionStore
    let property: PropertyRow
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            
                            Text("Map #\(property.map_number)")
                                .font(.headline)
                            
                            Text(property.name)
                                .font(.title2.weight(.semibold))
                            
                            Text(property.address)
                                .foregroundStyle(.secondary)
                            
                            if property.latitude == nil || property.longitude == nil {
                                
                                StatusPill(
                                    systemImage: "location.slash",
                                    text: "Needs GPS"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if let assigned = session.driverStatuses.first(where: {
                        $0.properties?.map_number == property.map_number
                    }) {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Assigned Driver")
                                    .font(.headline)
                                
                                Text(assigned.profiles?.name ?? "Unknown")
                                    .font(.title3.weight(.semibold))
                                
                                Text("Status: \(assigned.status ?? "Unknown")")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    
                    if let closest = closestAvailableDriver(
                        to: property,
                        from: session.driverStatuses
                    ) {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Closest Available Driver")
                                    .font(.headline)
                                
                                Text(closest.profiles?.name ?? "Unknown")
                                    .font(.title3.weight(.semibold))
                                
                                Text("Status: \(closest.status ?? "Unknown")")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        if let closest = closestAvailableDriver(
                            to: property,
                            from: session.driverStatuses
                        ) {
                            Button {
                                Task {
                                    await assignClosestDriver(closest)
                                }
                            } label: {
                                Label(
                                    "Assign Closest Driver: \(closest.profiles?.name ?? "Unknown")",
                                    systemImage: "location.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    
                    Button {
                        openInMaps()
                    } label: {
                        Label("Open in Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .navigationTitle("Property")
        }
    }
    
    private func assignClosestDriver(_ driver: DriverStatusRow) async {
        guard let stormId = session.activeStorm?.id ?? session.activeStormId else {
            return
        }
        
        do {
            try await session.assignProperties(
                stormId: stormId,
                driverId: driver.driver_id,
                propertyIds: [property.id]
            )
            
            await session.refreshDriverStatuses()
            await session.refreshAssignedProperties()
            
        } catch {
            session.lastError = error.localizedDescription
        }
    }
    
    private func openInMaps() {
        let query = "\(property.name), \(property.address)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}
