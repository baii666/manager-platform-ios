import SwiftUI
import UIKit

// MARK: - 登录 / 连接服务器
// iPad App 不像 Web 同源，启动后先输入服务器地址 + 账号密码连上后端。
struct LoginView: View {
    @ObservedObject var session: AppSession

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    /// 「保存当前地址」之后的轻量反馈（成功才显示，不弹窗）
    @State private var savedHint: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(Theme.brand)
                Text("媒体库")
                    .font(.largeTitle.weight(.bold))
                Text("连接到你的 Emby Manager 服务器")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        field(systemImage: "network",
                              placeholder: "https://your.domain 或 http://192.168.1.100:19876",
                              text: $server)
                        // 记住过的服务器：选一条回填 / 删一条 / 清空
                        serverMenu
                        // 只保存地址，不登录 —— 先把「家里 IP」和「外网域名」都存好
                        Button {
                            saveCurrentServer()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Theme.brand)
                                .frame(width: 32, height: 32)
                                .appSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(AppSession.normalizeBaseURL(server) == nil)
                    }
                    Text("外网请用 https 域名（服务端需配好证书或反向代理）；局域网可直接填 IP。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                field(systemImage: "person", placeholder: "用户名", text: $username)
                field(systemImage: "lock", placeholder: "密码", text: $password, secure: true)
            }
            .frame(maxWidth: 420)

            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 420, alignment: .leading)
                    .textSelection(.enabled)
            } else if let hint = savedHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            Button {
                savedHint = nil
                Task { await session.connect(server: server, username: username, password: password) }
            } label: {
                Group {
                    if session.isConnecting {
                        ProgressView()
                    } else {
                        Text("连接")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 420)
            .disabled(session.isConnecting || server.isEmpty || username.isEmpty || password.isEmpty)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
        .onAppear {
            if server.isEmpty {
                server = session.baseURL?.absoluteString ?? session.servers.first ?? ""
            }
            // 只预填用户名，密码永远不存
            if username.isEmpty { username = session.lastUsername ?? "" }
        }
    }

    /// 历史服务器菜单：每条可「使用」或「删除」，另有清空全部。
    /// 即使一条记录都没有也显示（菜单里给一句说明），保证入口位置稳定。
    private var serverMenu: some View {
        Menu {
            if !session.servers.isEmpty {
                Section("已保存的服务器") {
                    ForEach(session.servers, id: \.self) { address in
                        Menu {
                            Button {
                                server = address
                                savedHint = nil
                            } label: {
                                Label("使用此地址", systemImage: "arrow.right.circle")
                            }
                            Button(role: .destructive) {
                                session.removeServer(address)
                            } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        } label: {
                            HStack {
                                Text(address).font(.caption)
                                if address == AppSession.normalizeBaseURL(server)?.absoluteString {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        let snapshot = session.servers
                        snapshot.forEach { session.removeServer($0) }
                    } label: {
                        Label("清空所有记录", systemImage: "trash.slash")
                    }
                }
            } else {
                Text("还没有保存过服务器地址")
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.brand)
                .frame(width: 32, height: 32)
                .appSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 只把当前输入记进列表、规范化回填，不发起登录。
    /// 这样「外网 https 域名」可以先存好，等服务端证书配好再连。
    private func saveCurrentServer() {
        guard let url = AppSession.normalizeBaseURL(server) else {
            savedHint = nil
            session.errorMessage = "服务器地址无效"
            return
        }
        server = url.absoluteString
        session.rememberServer(url)
        session.errorMessage = nil
        savedHint = "已保存：\(url.absoluteString)"
    }

    private func field(
        systemImage: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(12)
        .appSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
