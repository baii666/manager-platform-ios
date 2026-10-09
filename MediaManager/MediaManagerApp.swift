import SwiftUI

@main
struct MediaManagerApp: App {
    @ObservedObject private var session = AppSession.shared

    init() {
        AppSession.shared.restoreBaseURL()
    }

    var body: some Scene {
        WindowGroup {
            if session.isLoggedIn {
                RootView()
            } else {
                LoginView(session: session)
            }
        }
    }
}
