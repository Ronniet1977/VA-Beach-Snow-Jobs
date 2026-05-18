import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    
    @State private var username = ""
    @State private var rememberMe = true
    @State private var password = ""
    @State private var mode: Mode = .signIn
    
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case signUp = "Sign Up"
        var id: String { rawValue }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                
                VStack(spacing: 6) {
                    Text("SnowOps")
                        .font(.largeTitle.weight(.semibold))
                    Text("Driver Login")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                
                VStack(spacing: 10) {
                    TextField("Driver Name", text: $username)
                        .textInputAutocapitalization(.words)
                        .textFieldStyle(.roundedBorder)
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    
                    Toggle("Remember Me", isOn: $rememberMe)
                }
                
                if let err = session.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                Button {
                    Task {
                        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
                        let p = password
                        
                        guard !name.isEmpty, !p.isEmpty else { return }
                        
                        let hiddenEmail = session.emailFromUsername(name)
                        
                        switch mode {
                        case .signIn:
                            await session.signIn(email: hiddenEmail, password: p)
                            
                        case .signUp:
                            await session.signUp(email: hiddenEmail, password: p)
                            
                            session.displayName = nil
                            session.needsNameSetup = true
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if session.isLoading {
                            ProgressView()
                        } else {
                            Text(mode.rawValue)
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isLoading)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }
}
