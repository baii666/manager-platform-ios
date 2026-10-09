import SwiftUI
import UIKit

// MARK: - 登录 / 连接服务器
// iPad App 不像 Web 同源，启动后先输入服务器地址 + 账号密码连上后端。
struct LoginView: View {
    @ObservedObject var session: AppSession

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

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
                field(systemImage: "network", placeholder: "http://192.168.1.100:19876", text: $server)
                field(systemImage: "person", placeholder: "用户名", text: $username)
                field(systemImage: "lock", placeholder: "密码", text: $password, secure: true)
            }
            .frame(maxWidth: 420)

            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            Button {
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
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            if server.isEmpty { server = session.baseURL?.absoluteString ?? "" }
        }
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
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
