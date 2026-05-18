import SwiftUI
import MapKit
import CoreLocation

struct DriverRouteView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    
    @State private var orderedStops: [PropertyRow] = []
    
    var body: some View {
        NavigationStack {
            List {
                Section("Suggested Route") {
                    if orderedStops.isEmpty {
                        Text("No assigned properties with coordinates yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(orderedStops.enumerated()), id: \.element.id) { index, property in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(index + 1). Map #\(property.map_number) • \(property.name)")
                                    .font(.headline)
                                
                                Text(property.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                Button {
                                    openInMaps(property)
                                } label: {
                                    Label("Open in Maps", systemImage: "map")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("My Route")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        buildRoute()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                LocationManager.shared.requestPermission()
                LocationManager.shared.start()
                await session.refreshAssignedProperties()
                buildRoute()
            }
            .refreshable {
                await session.refreshAssignedProperties()
                buildRoute()
            }
        }
    }
    
    private var routeEligibleProperties: [PropertyRow] {
        
        guard let userId = session.userId,
              let driverId = UUID(uuidString: userId) else {
            return []
        }
        
        return session.assignedProperties.filter { property in
            
            guard property.latitude != nil,
                  property.longitude != nil else {
                return false
            }
            
            let assignment = session.assignments.first {
                $0.property_id == property.id &&
                $0.driver_id == driverId
            }
            
            let status =
            assignment?.status?
                .lowercased() ?? "accepted"
            
            return status != "finished" &&
            status != "declined"
        }
    }
    
    private var nextProperty: PropertyRow? {
        orderedStops.first
    }
    
    private func buildRoute() {
        guard let current = LocationManager.shared.lastLocation else {
            orderedStops = routeEligibleProperties
            return
        }
        
        var remaining = routeEligibleProperties
        
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
        
        orderedStops = route
    }
    
    private func distance(from location: CLLocation, to property: PropertyRow) -> CLLocationDistance {
        guard let lat = property.latitude,
              let lon = property.longitude else {
            return .greatestFiniteMagnitude
        }
        
        return location.distance(
            from: CLLocation(latitude: lat, longitude: lon)
        )
    }
    
    private func openInMaps(_ property: PropertyRow) {
        let query = "\(property.name), \(property.address)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}

