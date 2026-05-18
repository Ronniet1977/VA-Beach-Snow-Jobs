import SwiftUI

struct SignedInView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                
                Text("Signed In")
                    .font(.title2.weight(.semibold))
                
                Text("User ID:\n\(session.userId ?? "unknown")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(role: .destructive) {
                    session.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                Spacer()
            }
            .padding(20)
            .navigationTitle("SnowOps")
        }
    }
}

