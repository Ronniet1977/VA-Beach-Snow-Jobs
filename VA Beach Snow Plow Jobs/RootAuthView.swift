import SwiftUI

struct RootAuthView: View {
    @EnvironmentObject var session: SupabaseSessionStore
    @EnvironmentObject var store: AppStore
    
    var body: some View {
        if !session.isSignedIn {
            LoginView()
        } else if (session.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SetNameView()
        } else {
            RootView()
        }
    }
}
