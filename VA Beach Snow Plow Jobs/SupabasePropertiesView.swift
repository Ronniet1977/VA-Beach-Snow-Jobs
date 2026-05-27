import SwiftUI
import CoreLocation
import UIKit
import UniformTypeIdentifiers

struct SupabasePropertiesView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @State private var showAddProperty = false
    
    @State private var rows: [PropertyRow] = []
    @State private var searchText = ""
    @State private var showActiveOnly = true
    
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var editingProperty: PropertyRow?
    
    @State private var showImporter = false
    
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
                                    
                                    HStack {
                                        Button {
                                            Task {
                                                do {
                                                    let coordinate = try await GeocoderService.coordinates(for: p.address)
                                                    
                                                    guard let coordinate else {
                                                        errorText = "No coordinates found for \(p.name)"
                                                        return
                                                    }
                                                    
                                                    print("✅ Found GPS:", coordinate.latitude, coordinate.longitude, "for", p.name)
                                                    
                                                    try await session.updatePropertyCoordinates(
                                                        propertyId: p.id,
                                                        latitude: coordinate.latitude,
                                                        longitude: coordinate.longitude
                                                    )
                                                    
                                                    try await session.updatePropertyGPSStatus(
                                                        propertyId: p.id,
                                                        verified: true,
                                                        problem: false
                                                    )
                                                    
                                                    await load()
                                                    
                                                } catch {
                                                    errorText = error.localizedDescription
                                                    print("GPS Good failed:", error)
                                                }
                                            }
                                        } label: {
                                            Label("GPS Good", systemImage: "checkmark.circle.fill")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        Button {
                                            Task {
                                                do {
                                                    try await session.updatePropertyGPSStatus(
                                                        propertyId: p.id,
                                                        verified: false,
                                                        problem: true
                                                    )
                                                    
                                                    await load()
                                                    
                                                } catch {
                                                    errorText = error.localizedDescription
                                                }
                                            }
                                        } label: {
                                            Label("Bad GPS", systemImage: "exclamationmark.triangle.fill")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    
                                    if p.gps_verified == true {
                                        StatusPill(
                                            systemImage: "checkmark.circle.fill",
                                            text: "GPS Verified"
                                        )
                                    }
                                    
                                    if p.gps_problem == true {
                                        StatusPill(
                                            systemImage: "exclamationmark.triangle.fill",
                                            text: "Bad GPS"
                                        )
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
                ToolbarItem(placement: .topBarLeading) {
                    if session.isAdmin {
                        Button {
                            Task {
                                await bulkGeocodeMissing()
                            }
                        } label: {
                            Label("GPS", systemImage: "location.magnifyingglass")
                        }
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    if session.isAdmin {
                        
                        Menu {
                            
                            Button {
                                showImporter = true
                            } label: {
                                Label("Import CSV", systemImage: "square.and.arrow.down")
                            }
                            
                            Button {
                                showAddProperty = true
                            } label: {
                                Label("Add Property", systemImage: "plus")
                            }
                            
                        } label: {
                            Image(systemName: "plus")
                        }
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
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText]
            ) { result in
                
                switch result {
                    
                case .success(let url):
                    
                    Task {
                        await importCSV(from: url)
                    }
                    
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
            .searchable(text: $searchText, prompt: "Search map #, name, address")
            .task(id: session.activeStorm?.id ?? session.activeStormId) { await load() }
            .refreshable { await load() }
        }
    }
    
    private func importCSV(from url: URL) async {
        var groupCounters: [String: Int] = [:]
        
        func groupCode(from notes: String, address: String) -> String {
            let text = "\(notes) \(address)".lowercased()
            
            if text.contains("virginia beach") { return "VB" }
            if text.contains("norfolk") { return "NFK" }
            if text.contains("chesapeake") { return "CHK" }
            if text.contains("portsmouth") { return "POR" }
            if text.contains("suffolk") { return "SUF" }
            if text.contains("hampton") { return "HAM" }
            if text.contains("newport news") { return "NN" }
            if text.contains("williamsburg") { return "WMB" }
            if text.contains("richmond") { return "RIC" }
            
            return "GEN"
        }
        
        do {
            guard url.startAccessingSecurityScopedResource() else {
                errorText = "Could not access file."
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            let data = try Data(contentsOf: url)
            
            guard let csv = String(data: data, encoding: .utf8) else {
                errorText = "Could not read CSV."
                return
            }
            
            let lines = csv.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            guard lines.count > 1 else {
                errorText = "CSV empty."
                return
            }
            
            for line in lines.dropFirst() {
                do {
                    let cols = line.components(separatedBy: ",")
                    
                    guard cols.count >= 2 else { continue }
                    
                    let name = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let address = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    guard !name.isEmpty, !address.isEmpty else { continue }
                    
                    let notes = cols.count > 2
                    ? cols[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                    
                    let code = groupCode(from: notes, address: address)
                    let nextNumber = (groupCounters[code] ?? 0) + 1
                    groupCounters[code] = nextNumber
                    
                    let mapNumber = "\(code)-\(String(format: "%03d", nextNumber))"
                    
                    let exists = try await session.mapNumberExists(mapNumber)
                    if exists { continue }
                    
                    let coordinate: CLLocationCoordinate2D?
                    do {
                        coordinate = try await GeocoderService.coordinates(for: address)
                    } catch {
                        print("Skipping bad geocode:", name, address, error)
                        coordinate = nil
                    }
                    
                    let body = NewPropertyBody(
                        map_number: mapNumber,
                        name: name,
                        address: address,
                        notes: notes,
                        active: true,
                        priority: "normal",
                        latitude: coordinate?.latitude,
                        longitude: coordinate?.longitude
                    )
                    
                    try await session.createProperty(body)
                    try await Task.sleep(nanoseconds: 250_000_000)
                    
                } catch {
                    print("Skipping bad row:", line, error)
                    continue
                }
            }
            
            await load()
            
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    private func bulkGeocodeMissing() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        let missing = rows.filter {
            $0.latitude == nil || $0.longitude == nil
        }
        
        for property in missing {
            do {
                guard let coordinate = try await GeocoderService.coordinates(for: property.address) else {
                    continue
                }
                
                try await session.updatePropertyCoordinates(
                    propertyId: property.id,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                
                try await Task.sleep(nanoseconds: 300_000_000)
                
            } catch {
                print("Bulk geocode failed for \(property.name):", error)
            }
        }
        
        await load()
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
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }
}

