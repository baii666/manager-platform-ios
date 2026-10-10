import SwiftUI
import UIKit

@main
struct MediaManagerApp: App {
    @ObservedObject private var session = AppSession.shared

    init() {
        // 封面图走 AsyncImage（底层 URLSession.shared + URLCache.shared）。
        // 系统默认 URLCache 磁盘容量极小（几十 MB），几张高清封面就把它挤爆，
        // 于是每次进「首页/电影/相册/拍摄集」都要把几十张封面重新下一遍 —— 这就是加载慢的主因。
        // 服务端缩略图响应带 immutable，扩到 1GB 磁盘后能常驻，二次进入直接走本地磁盘。
        let memory = 128 * 1024 * 1024        // 128 MB 内存
        let disk = 1024 * 1024 * 1024         // 1 GB 磁盘
        URLCache.shared = URLCache(memoryCapacity: memory, diskCapacity: disk, diskPath: "imgcache")
    }

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
