import SwiftUI
import UIKit

@main
struct MediaManagerApp: App {
    @ObservedObject private var session = AppSession.shared

    var body: some Scene {
        WindowGroup {
            Group {
                // 恢复期间先转圈，避免每次冷启动都闪一下登录页
                if session.isRestoring {
                    ProgressView("正在恢复登录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                } else if session.isLoggedIn {
                    RootView()
                } else {
                    LoginView(session: session)
                }
            }
            .task { await AppSession.shared.restoreSession() }
        }
    }
}
