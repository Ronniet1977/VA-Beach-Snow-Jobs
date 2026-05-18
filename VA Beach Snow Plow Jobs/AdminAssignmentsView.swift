import SwiftUI
import CoreLocation
import Combine

enum AdminTab: String, CaseIterable, Identifiable {
    case assign = "Assign"
    case drivers = "Drivers"
    case groups = "Groups"
    
    var id: String { rawValue }
}

struct AdminAssignmentsView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    
    @State private var tab: AdminTab = .assign
    @State private var driverTabSelectedDriverId: UUID? = nil
    
    @State private var storms: [StormRow] = []
    @State private var drivers: [DriverRow] = []
    @State private var properties: [PropertyRow] = []
    
    @State private var selectedStormId: UUID?
    @State private var selectedDriverId: UUID?
    
    @State private var search = ""
    @State private var selectedPropertyIds = Set<UUID>()
    
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var newStormName = ""
    
    @State private var assignments: [AssignmentRow] = []
    
    @State private var editingProperty: PropertyRow?
    
    @State private var selectedDriverIds = Set<UUID>()
    @State private var newGroupName = ""
    @State private var renameGroupName = ""
    
    @State private var selectedGroupId: UUID?
    @State private var closestCountText = "5"
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    
                    // Segmented tabs
                    Card {
                        Picker("Tab", selection: $tab) {
                            ForEach(AdminTab.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    switch tab {
                    case .assign:
                        assignTabContent
                        
                    case .drivers:
                        driversTabContent
                        
                    case .groups:
                        groupsTabContent
                    }
                    
                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Assignments")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isLoading { ProgressView() }
                }
            }
            .sheet(item: $editingProperty) { property in
                AddPropertySheet(editingProperty: property) {
                    Task { await reloadAll() }
                }
                .environmentObject(session)
            }
            .task {
                session.restoreActiveStorm()
                selectedStormId = session.activeStormId
                
                await reloadAll()
                await session.fetchDriverGroups()
            }
            .refreshable {
                await reloadAll()
            }
        }
    }
    
    private var groupsTabContent: some View {
        VStack(spacing: 14) {
            
            // GROUP PICKER
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    
                    Text("Saved Groups")
                        .font(.headline)
                    
                    Picker("Group", selection: $selectedGroupId) {
                        
                        Text("Select…")
                            .tag(UUID?.none)
                        
                        ForEach(session.driverGroups) { g in
                            Text(g.name)
                                .tag(Optional(g.id))
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if let groupId = selectedGroupId {
                        
                        HStack {
                            TextField("Rename group", text: $renameGroupName)
                                .textFieldStyle(.roundedBorder)
                            
                            Button("Rename") {
                                Task {
                                    await session.updateDriverGroupName(
                                        groupId: groupId,
                                        name: renameGroupName
                                    )
                                    
                                    renameGroupName = ""
                                    await session.fetchDriverGroups()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        
                        Button(role: .destructive) {
                            Task {
                                await session.deleteDriverGroup(groupId: groupId)
                                selectedGroupId = nil
                                selectedDriverIds = []
                                await session.fetchDriverGroups()
                            }
                        } label: {
                            Label("Delete Group", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    HStack {
                        
                        TextField(
                            "New group name",
                            text: $newGroupName
                        )
                        .textFieldStyle(.roundedBorder)
                        
                        Button("Create") {
                            Task {
                                let groupName = newGroupName
                                
                                await session.createDriverGroup(name: groupName)
                                await session.fetchDriverGroups()
                                
                                selectedGroupId = session.driverGroups.first {
                                    $0.name == groupName
                                }?.id
                                
                                newGroupName = ""
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .onChange(of: selectedGroupId) { _, newValue in
                
                guard let groupId = newValue else {
                    selectedDriverIds = []
                    return
                }
                
                Task {
                    
                    await session.fetchGroupMembers(
                        groupId: groupId
                    )
                    
                    selectedDriverIds = Set(
                        session.groupMembers.map(\.driver_id)
                    )
                }
            }
            
            // DRIVERS
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    
                    Text("Drivers")
                        .font(.headline)
                    
                    ForEach(drivers) { d in
                        
                        Button {
                            toggleDriver(d.id)
                        } label: {
                            
                            HStack {
                                
                                Image(systemName:
                                        selectedDriverIds.contains(d.id)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                
                                Text(
                                    d.name?.isEmpty == false
                                    ? d.name!
                                    : d.id.uuidString
                                )
                                
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button {
                        
                        guard let groupId = selectedGroupId else {
                            return
                        }
                        
                        Task {
                            await session.saveGroupMembers(
                                groupId: groupId,
                                driverIds: selectedDriverIds
                            )
                        }
                        
                    } label: {
                        
                        Label(
                            "Save Drivers To Group",
                            systemImage: "square.and.arrow.down"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedGroupId == nil)
                }
            }
            
            //Auto Select Closest
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Auto Select Closest")
                        .font(.headline)
                    
                    TextField("How many properties?", text: $closestCountText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    
                    Button {
                        selectClosestPropertiesForGroup()
                    } label: {
                        Label("Pick Closest Properties", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            // Properties
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    
                    Text("Properties")
                        .font(.headline)
                    
                    propertySelectionList
                }
            }
            
            // Assign
            Card {
                Button {
                    Task {
                        await assignGroupTapped()
                    }
                } label: {
                    Label(
                        "Assign Properties to Group",
                        systemImage: "person.3.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedStormId == nil ||
                    selectedDriverIds.isEmpty ||
                    selectedPropertyIds.isEmpty
                )
            }
            .onAppear {
                Task {
                    await session.fetchDriverGroups()
                }
            }
        }
    }
    
    private var propertySelectionList: some View {
        VStack(spacing: 10) {
            let seedProperty = filteredProperties.first {
                selectedPropertyIds.contains($0.id)
            }
            ForEach(filteredProperties) { p in
                Button {
                    toggle(p.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedPropertyIds.contains(p.id)
                              ? "checkmark.circle.fill"
                              : "circle")
                        .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Map #\(p.map_number) • \(p.name)")
                                .font(.subheadline.weight(.semibold))
                            
                            Text(p.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let seed = seedProperty,
                           seed.id != p.id,
                           let miles = propertyDistanceMiles(from: seed, to: p) {
                            
                            Text("\(miles, specifier: "%.1f") mi")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        
                        Spacer()
                        
                        if let name = assignedLabel(for: p.id) {
                            StatusPill(systemImage: "person.fill", text: "Assigned: \(name)")
                        }
                        
                        if p.priority == "high" {
                            StatusPill(systemImage: "star.fill", text: "High")
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Divider().opacity(0.5)
            }
        }
    }
    
    // MARK: - Tabs
    private var assignTabContent: some View {
        VStack(spacing: 14) {
            
            // Storm card
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Active Storm").font(.headline)
                    
                    Picker("Storm", selection: Binding(
                        get: { selectedStormId },
                        set: { id in
                            selectedStormId = id
                            session.setActiveStorm(id)
                            Task { await reloadAll() }
                        }
                    )) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(storms) { s in
                            Text(s.name).tag(Optional(s.id))
                        }
                    }
                    .pickerStyle(.menu)
                    
                    HStack(spacing: 10) {
                        TextField("New storm name", text: $newStormName)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Create") { Task { await createStormTapped() } }
                            .buttonStyle(.bordered)
                            .disabled(newStormName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            
            // Driver picker
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Driver").font(.headline)
                    
                    Picker("Driver", selection: $selectedDriverId) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(drivers) { d in
                            Text(d.name?.isEmpty == false ? d.name! : d.id.uuidString)
                                .tag(Optional(d.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            // Properties list
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Properties").font(.headline)
                        Spacer()
                        Text("\(selectedPropertyIds.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    TextField("Search map #, name, address", text: $search)
                        .textFieldStyle(.roundedBorder)
                    
                    VStack(spacing: 10) {
                        ForEach(groupAvailableProperties) { p in
                            Button { toggle(p.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedPropertyIds.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.secondary)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Map #\(p.map_number) • \(p.name)")
                                            .font(.subheadline.weight(.semibold))
                                        Text(p.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if let name = assignedLabel(for: p.id) {
                                        StatusPill(systemImage: "person.fill", text: "Assigned: \(name)")
                                    }
                                    
                                    if p.priority == "high" {
                                        StatusPill(systemImage: "star.fill", text: "High")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editingProperty = p
                                } label: {
                                    Label("Edit Property", systemImage: "pencil")
                                }
                            }
                            
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
            
            // Assign actions
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Assign").font(.headline)
                    
                    Button { Task { await assignTapped() } } label: {
                        Label("Assign Selected to Driver", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAssign)
                    
                    Button { selectedPropertyIds.removeAll() } label: {
                        Label("Clear Selection", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedPropertyIds.isEmpty)
                }
            }
        }
    }
    
    private var driversTabContent: some View {
        VStack(spacing: 14) {
            
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Driver").font(.headline)
                    
                    Picker("Driver", selection: $driverTabSelectedDriverId) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(drivers) { d in
                            Text(d.name?.isEmpty == false ? d.name! : d.id.uuidString)
                                .tag(Optional(d.id))
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if let dId = driverTabSelectedDriverId {
                        HStack {
                            Button {
                                Task {
                                    await updateRoleTapped(driverId: dId, role: "admin")
                                }
                            } label: {
                                Label("Promote Admin", systemImage: "person.badge.key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button(role: .destructive) {
                                Task {
                                    await updateRoleTapped(driverId: dId, role: "driver")
                                }
                            } label: {
                                Label("Make Driver", systemImage: "steeringwheel")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Text("Assigned: \(assignedPropertyIdsForSelectedDriver.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        
                        Button {
                            // quick jump: preselect same driver in Assign tab if you want
                            selectedDriverId = dId
                            tab = .assign
                        } label: {
                            Label("Assign more to this driver", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        
                    }
                }
            }
            
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Assigned Properties").font(.headline)
                    
                    if driverTabSelectedDriverId == nil {
                        Text("Pick a driver above.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                    } else if driverTabProperties.isEmpty {
                        Text("No properties assigned.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                    } else {
                        VStack(spacing: 10) {
                            ForEach(driverTabProperties) { p in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Map #\(p.map_number) • \(p.name)")
                                            .font(.subheadline.weight(.semibold))
                                        Text(p.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button(role: .destructive) {
                                        Task { await unassignTapped(propertyId: p.id) }
                                    } label: {
                                        Label("Unassign", systemImage: "person.fill.xmark")
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
    }
    
    private func assignGroupTapped() async {
        guard let stormId = selectedStormId else { return }
        
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            for driverId in selectedDriverIds {
                try await session.assignProperties(
                    stormId: stormId,
                    driverId: driverId,
                    propertyIds: Array(selectedPropertyIds)
                )
            }
            
            await reloadAll()
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    private func unassignTapped(propertyId: UUID) async {
        guard let stormId = selectedStormId else { return }
        guard let driverId = driverTabSelectedDriverId else { return }
        
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            try await session.unassignProperty(
                stormId: stormId,
                propertyId: propertyId,
                driverId: driverId
            )
            await reloadAll()
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    // MARK: - Helpers
    
    private func toggleDriver(_ id: UUID) {
        if selectedDriverIds.contains(id) {
            selectedDriverIds.remove(id)
        } else {
            selectedDriverIds.insert(id)
        }
    }
    
    private var canAssignGroup: Bool {
        selectedStormId != nil &&
        !selectedDriverIds.isEmpty &&
        !selectedPropertyIds.isEmpty
    }
    
    private var canAssign: Bool {
        selectedStormId != nil && selectedDriverId != nil && !selectedPropertyIds.isEmpty
    }
    
    private func propertyDistanceMiles(
        from a: PropertyRow,
        to b: PropertyRow
    ) -> Double? {
        
        guard let aLat = a.latitude,
              let aLon = a.longitude,
              let bLat = b.latitude,
              let bLon = b.longitude else {
            return nil
        }
        
        let locA = CLLocation(latitude: aLat, longitude: aLon)
        let locB = CLLocation(latitude: bLat, longitude: bLon)
        
        return locA.distance(from: locB) / 1609.34
    }
    
    private func selectClosestPropertiesForGroup() {
        let count = Int(closestCountText) ?? 5
        
        let candidates = groupAvailableProperties
        
        guard !candidates.isEmpty else { return }
        
        // Use first manually selected property as the "seed"
        guard let seedId = selectedPropertyIds.first,
              let seed = candidates.first(where: { $0.id == seedId }),
              let seedLat = seed.latitude,
              let seedLon = seed.longitude else {
            print("Select one starting property first.")
            return
        }
        
        let seedLocation = CLLocation(latitude: seedLat, longitude: seedLon)
        
        let closest = candidates
            .sorted {
                distance(from: seedLocation, to: $0) <
                    distance(from: seedLocation, to: $1)
            }
            .prefix(count)
        
        selectedPropertyIds = Set(closest.map { $0.id })
    }
    
    private func distance(
        from location: CLLocation,
        to property: PropertyRow
    ) -> CLLocationDistance {
        
        guard let lat = property.latitude,
              let lon = property.longitude else {
            return .greatestFiniteMagnitude
        }
        
        return location.distance(
            from: CLLocation(latitude: lat, longitude: lon)
        )
    }
    
    private var groupAvailableProperties: [PropertyRow] {
        filteredProperties.filter { p in
            guard p.latitude != nil,
                  p.longitude != nil else {
                return false
            }
            
            let alreadyAssigned = session.assignments.contains {
                $0.property_id == p.id &&
                $0.status != "finished" &&
                $0.status != "declined"
            }
            
            return !alreadyAssigned
        }
    }
    
    private var filteredProperties: [PropertyRow] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return properties
            .filter { $0.active }
            .filter { p in
                guard !q.isEmpty else { return true }
                return p.map_number.lowercased().contains(q)
                || p.name.lowercased().contains(q)
                || p.address.lowercased().contains(q)
            }
    }
    
    private var assignedPropertyIdsForSelectedDriver: Set<UUID> {
        guard let dId = driverTabSelectedDriverId else { return [] }
        return Set(assignments.filter { $0.driver_id == dId }.map { $0.property_id })
    }
    
    private var driverTabProperties: [PropertyRow] {
        let ids = assignedPropertyIdsForSelectedDriver
        return properties
            .filter { ids.contains($0.id) }
            .sorted { $0.map_number.localizedStandardCompare($1.map_number) == .orderedAscending }
    }
    
    private var driverNameById: [UUID: String] {
        Dictionary(uniqueKeysWithValues: drivers.map {
            ($0.id, ($0.name?.isEmpty == false ? $0.name! : "Unknown"))
        })
    }
    
    private var assignedDriverIdsByPropertyId: [UUID: [UUID]] {
        Dictionary(grouping: assignments, by: { $0.property_id })
            .mapValues { rows in
                rows.map { $0.driver_id }
            }
    }
    
    private func assignedLabel(for propertyId: UUID) -> String? {
        guard let driverIds = assignedDriverIdsByPropertyId[propertyId],
              !driverIds.isEmpty else {
            return nil
        }
        
        let names = driverIds.compactMap { driverNameById[$0] }
        
        if names.count == 1 {
            return names[0]
        } else {
            return "\(names.count) drivers"
        }
    }
    
    private func toggle(_ id: UUID) {
        if selectedPropertyIds.contains(id) {
            selectedPropertyIds.remove(id)
        } else {
            selectedPropertyIds.insert(id)
        }
    }
    
    private func reloadAll() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            async let s = session.fetchOpenStorms()
            async let d = session.fetchDrivers()
            async let p = session.fetchAllProperties()
            
            storms = try await s
            drivers = try await d
            properties = try await p
            
            if selectedStormId == nil, let first = storms.first {
                selectedStormId = first.id
                session.setActiveStorm(first.id)
            }
            
            if let stormId = selectedStormId {
                assignments = try await session.fetchAssignments(stormId: stormId)
            } else {
                assignments = []
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    private func updateRoleTapped(driverId: UUID, role: String) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            try await session.updateUserRole(
                userId: driverId,
                role: role
            )
            
            await reloadAll()
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    private func createStormTapped() async {
        let name = newStormName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            let created = try await session.createStorm(name: name)
            newStormName = ""
            selectedStormId = created.id
            session.setActiveStorm(created.id)
            await reloadAll()
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    private func assignTapped() async {
        guard let stormId = selectedStormId, let driverId = selectedDriverId else { return }
        
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        
        do {
            try await session.assignProperties(
                stormId: stormId,
                driverId: driverId,
                propertyIds: Array(selectedPropertyIds)
            )
            await reloadAll()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct AdminStatusView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @State private var search = ""
    @State private var selectedDriver: DriverStatusRow?
    
    private var filtered: [DriverStatusRow] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        return session.driverStatuses
            .sorted { sortRank($0) < sortRank($1) }
            .filter { row in
                guard !q.isEmpty else { return true }
                
                let driver = row.profiles?.name?.lowercased() ?? ""
                let prop = row.properties?.name?.lowercased() ?? ""
                let map = row.properties?.map_number?.lowercased() ?? ""
                let status = row.status?.lowercased() ?? ""
                
                return driver.contains(q)
                || prop.contains(q)
                || map.contains(q)
                || status.contains(q)
            }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard
                    
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { row in
                            Button {
                                selectedDriver = row
                            } label: {
                                driverStatusCard(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Driver Status")
            .searchable(text: $search, prompt: "Search driver, map, property")
            .task {
                await session.refreshDriverStatuses()
            }
            .refreshable {
                await session.refreshDriverStatuses()
            }
            .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
                Task {
                    await session.refreshDriverStatuses()
                }
            }
            .sheet(item: $selectedDriver) { row in
                DriverStatusDetailSheet(row: row)
            }
        }
    }
    
    private var summaryCard: some View {
        let working = session.driverStatuses.filter { $0.status == "working" }.count
        let idle = session.driverStatuses.filter { $0.status == "idle" }.count
        let issue = session.driverStatuses.filter { $0.status == "issue" }.count
        let stopped = session.driverStatuses.filter { $0.status == "stopped" }.count
        let offline = session.driverStatuses.filter { isStale($0) }.count
        
        return Card {
            HStack {
                stat("Working", working)
                Spacer()
                stat("Idle", idle)
                Spacer()
                stat("Issues", issue)
                Spacer()
                stat("Stopped", stopped)
                Spacer()
                stat("Offline", offline)
            }
        }
    }
    
    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    private func driverStatusCard(_ row: DriverStatusRow) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                statusDot(row)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(row.profiles?.name ?? "Unknown Driver")
                            .font(.headline)
                        
                        Spacer()
                        
                        StatusPill(
                            systemImage: icon(for: row),
                            text: label(for: row)
                        )
                    }
                    
                    if let map = row.properties?.map_number,
                       let name = row.properties?.name {
                        Text("Map #\(map) • \(name)")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text("No active property")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let service = row.active_service {
                        Text("Service: \(service)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if row.status == "working",
                       let started = row.started_at {
                        Text("Elapsed: \(elapsedText(from: started))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    
                    if let started = row.started_at {
                        Text("Started: \(formatDate(started))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let lastSeen = row.last_seen {
                        Text("Last seen: \(formatDate(lastSeen))")
                            .font(.caption)
                            .foregroundStyle(isStale(row) ? .red : .secondary)
                    }
                    
                    if let notes = row.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
    
    private func statusDot(_ row: DriverStatusRow) -> some View {
        Circle()
            .fill(color(for: row))
            .frame(width: 12, height: 12)
            .padding(.top, 5)
    }
    
    private func color(for row: DriverStatusRow) -> Color {
        if isStale(row) { return .gray }
        
        switch row.status {
        case "working": return .green
        case "issue": return .red
        case "stopped": return .orange
        case "idle": return .secondary
        default: return .gray
        }
    }
    
    private func icon(for row: DriverStatusRow) -> String {
        if isStale(row) { return "wifi.slash" }
        
        switch row.status {
        case "working": return "bolt.fill"
        case "issue": return "exclamationmark.triangle.fill"
        case "stopped": return "pause.circle"
        case "idle": return "circle"
        default: return "questionmark.circle"
        }
    }
    
    private func label(for row: DriverStatusRow) -> String {
        if isStale(row) { return "Offline" }
        
        switch row.status {
        case "working": return "Working"
        case "issue": return "Issue"
        case "stopped": return "Stopped"
        case "idle": return "Idle"
        default: return "Unknown"
        }
    }
    
    private func sortRank(_ row: DriverStatusRow) -> Int {
        if isStale(row) { return 4 }
        
        switch row.status {
        case "issue": return 0
        case "working": return 1
        case "stopped": return 2
        case "idle": return 3
        default: return 5
        }
    }
    
    private func isStale(_ row: DriverStatusRow) -> Bool {
        guard let iso = row.last_seen else { return false }
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return false }
        
        return Date().timeIntervalSince(date) > 15 * 60
    }
    
    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(date: .omitted, time: .shortened)
    }
    
    private func elapsedText(from iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return "--:--:--" }
        
        let seconds = max(0, Int(Date().timeIntervalSince(d)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

struct DriverStatusDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let row: DriverStatusRow
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(row.profiles?.name ?? "Unknown Driver")
                                .font(.title2.weight(.semibold))
                            
                            StatusPill(
                                systemImage: "person.fill",
                                text: row.status ?? "Unknown"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Current Property")
                                .font(.headline)
                            
                            if let map = row.properties?.map_number,
                               let name = row.properties?.name {
                                Text("Map #\(map)")
                                    .font(.subheadline.weight(.semibold))
                                
                                Text(name)
                                    .font(.title3.weight(.semibold))
                            } else {
                                Text("No active property")
                                    .foregroundStyle(.secondary)
                            }
                            
                            if let service = row.active_service {
                                Text("Service: \(service)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Timing")
                                .font(.headline)
                            
                            if let started = row.started_at {
                                Text("Started: \(formatDate(started))")
                            }
                            
                            if let lastSeen = row.last_seen {
                                Text("Last Seen: \(formatDate(lastSeen))")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if let notes = row.notes, !notes.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Notes / Issue")
                                    .font(.headline)
                                
                                Text(notes)
                                    .foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Driver Detail")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
