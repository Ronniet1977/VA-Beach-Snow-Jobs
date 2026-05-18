import SwiftUI

struct SetNameView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    
    @State private var firstName = ""
    @State private var lastName = ""
    
    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !session.isLoading
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Set your name")
                    .font(.title2.weight(.semibold))
                
                Text("Enter your first and last name. This is what shows on logs, assignments, and reports.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                TextField("First name", text: $firstName)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Last name", text: $lastName)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder)
                
                Button {
                    let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fullName = "\(first) \(last)"
                    
                    Task {
                        await session.saveDisplayName(fullName)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if session.isLoading {
                            ProgressView()
                        } else {
                            Text("Continue")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                
                if let err = session.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("SnowOps")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Log Out") {
                        session.signOut()
                    }
                }
            }
            .onAppear {
                if session.accessToken == nil {
                    session.signOut()
                }
            }
        }
    }
}
