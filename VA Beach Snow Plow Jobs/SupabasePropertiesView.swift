import SwiftUI
import CoreLocation
import UIKit

struct SupabasePropertiesView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @State private var showAddProperty = false
    
    @State private var rows: [PropertyRow] = []
    @State private var searchText = ""
    @State private var showActiveOnly = true
    
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var editingProperty: PropertyRow?
    
    private var filtered: [PropertyRow] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        return rows
            .filter { !showActiveOnly || $0.active }
            .filter { p in
                guard !q.isEmpty else { return true }
                return p.map_number.lowercased().contains(q)
                || p.name.lowercased().contains(q)
                || p.address.lowercased().contains(q)
            }
            .sorted { ($0.priority == "high" && $1.priority != "high") }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    
                    Card {
                        HStack {
                            Text("Active only")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle("", isOn: $showActiveOnly).labelsHidden()
                        }
                    }
                    
                    if isLoading {
                        Card {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading properties…")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    
                    if let errorText {
                        Card {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { p in
                            Card {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Map #\(p.map_number)")
                                            .font(.headline)
                                        Spacer()
                                        if p.priority == "high" {
                                            StatusPill(systemImage: "star.fill", text: "High")
                                        }
                                    }
                                    
                                    HStack(spacing: 10) {
                                        Button {
                                            openInMaps(name: p.name, address: p.address)
                                        } label: {
                                            Label("Maps", systemImage: "map")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        if session.isAdmin {
                                            Button {
                                                editingProperty = p
                                            } label: {
                                                Label("Edit", systemImage: "pencil")
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    .padding(.top, 4)
                                    
                                    if session.isAdmin,
                                       let closest = closestAvailableDriver(
                                        to: p,
                                        from: session.driverStatuses
                                       ) {
                                        Button {
                                            Task {
                                                guard let stormId = session.activeStorm?.id ?? session.activeStormId else { return }
                                                
                                                try? await session.assignProperties(
                                                    stormId: stormId,
                                                    driverId: closest.driver_id,
                                                    propertyIds: [p.id]
                                                )
                                                
                                                await load()
                                            }
                                        } label: {
                                            Label("Assign Closest: \(closest.profiles?.name ?? "Unknown")",
                                                  systemImage: "location.fill")
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    
                                    Text(p.name)
                                        .font(.title3.weight(.semibold))
                                    
                                    Text(p.address)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if p.latitude == nil || p.longitude == nil {
                                        
                                        Button {
                                            Task {
                                                await geocodeProperty(p)
                                            }
                                        } label: {
                                            StatusPill(
                                                systemImage: "location.slash",
                                                text: "Needs GPS"
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    
                                    if !p.notes.isEmpty {
                                        Text(p.notes)
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Properties")
            .toolbar {
                if session.isAdmin {
                    Button {
                        showAddProperty = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddProperty) {
                AddPropertySheet {
                    Task { await load() } // refresh after save
                }
                .environmentObject(session)
            }
            .sheet(item: $editingProperty) { property in
                AddPropertySheet(editingProperty: property) {
                    Task { await load() }
                }
                .environmentObject(session)
            }
            .searchable(text: $searchText, prompt: "Search map #, name, address")
            .task(id: session.activeStorm?.id ?? session.activeStormId) { await load() }
            .refreshable { await load() }
        }
    }
    
    private func geocodeProperty(_ property: PropertyRow) async {
        
        let geocoder = CLGeocoder()
        
        do {
            
            let placemarks = try await geocoder.geocodeAddressString(
                property.address
            )
            
            guard let location = placemarks.first?.location else {
                return
            }
            
            try await session.updatePropertyCoordinates(
                propertyId: property.id,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            
            await load()
            
        } catch {
            print("Geocode failed:", error)
        }
    }
    
    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            if session.isAdmin {
                // ✅ Admin: show ALL properties (not storm-specific)
                rows = try await session.fetchAllProperties()
            } else {
                // ✅ Driver: show only properties assigned to THIS storm
                guard let stormId = session.activeStorm?.id ?? session.activeStormId else {
                    rows = []
                    errorText = "No active storm"
                    return
                }
                rows = try await session.fetchAssignedProperties(stormId: stormId)
            }
        } catch {
            rows = []
            errorText = error.localizedDescription
        }
    }
    
    private func openInMaps(name: String, address: String) {
        let query = "\(name), \(address)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}

