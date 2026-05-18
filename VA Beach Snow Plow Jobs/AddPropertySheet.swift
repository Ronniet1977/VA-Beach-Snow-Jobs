import SwiftUI
import Combine
import CoreLocation

struct AddPropertySheet: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @Environment(\.dismiss) private var dismiss
    
    let editingProperty: PropertyRow?
    var onSaved: (() -> Void)? = nil
    
    @State private var mapNumber = ""
    @State private var name = ""
    @State private var address = ""
    @State private var notes = ""
    @State private var isActive = true
    @State private var priority: String = "normal" // or "high"
    @State private var showDupAlert = false
    @State private var dupMessage = ""
    
    init(editingProperty: PropertyRow? = nil, onSaved: (() -> Void)? = nil) {
        self.editingProperty = editingProperty
        self.onSaved = onSaved
    }
    
    private var canSave: Bool {
        !mapNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Property") {
                    TextField("Map #", text: $mapNumber)
                        .keyboardType(.numbersAndPunctuation)
                    
                    TextField("Name", text: $name)
                    TextField("Address", text: $address)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                
                Section("Status") {
                    Toggle("Active", isOn: $isActive)
                    Picker("Priority", selection: $priority) {
                        Text("Normal").tag("normal")
                        Text("High").tag("high")
                    }
                }
                
                if let err = session.lastError {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(editingProperty == nil ? "Add Property" : "Edit Property")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave || session.isLoading)
                }
            }
            .onAppear {
                guard let p = editingProperty else { return }
                
                mapNumber = p.map_number
                name = p.name
                address = p.address
                notes = p.notes
                isActive = p.active
                priority = p.priority
            }
            .alert("Duplicate Map #", isPresented: $showDupAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(dupMessage)
            }
        }
    }
    
    private func save() {
        let mapTrim = mapNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameTrim = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressTrim = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesTrim = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        
        Task {
            do {
                session.lastError = nil
                session.isLoading = true
                defer { session.isLoading = false }
                
                // Only check duplicate map # when ADDING,
                // or when EDITING and map number changed.
                if editingProperty == nil || editingProperty?.map_number != mapTrim {
                    let exists = try await session.mapNumberExists(mapTrim)
                    if exists {
                        dupMessage = "Map #\(mapTrim) already exists. Pick a different map number."
                        showDupAlert = true
                        return
                    }
                }
                
                let coordinate = try await GeocoderService.coordinates(for: addressTrim)

                guard let coordinate else {
                    session.lastError = "Could not find coordinates for this address."
                    return
                }

                let body = NewPropertyBody(
                    map_number: mapTrim,
                    name: nameTrim,
                    address: addressTrim,
                    notes: notesTrim,
                    active: isActive,
                    priority: priority,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                
                if let editingProperty {
                    try await session.updateProperty(editingProperty.id, body: body)
                } else {
                    try await session.createProperty(body)
                }
                
                onSaved?()
                dismiss()
                
            } catch {
                session.lastError = error.localizedDescription
            }
        }
    }
}

