import SwiftUI

// MARK: - 播放请求
// 点一下卡片就能构造出来，**不需要任何网络往返** —— 这是「点了立刻有反应」的前提。
//
// 之前的写法是：点击 → await resolvePlayback（问服务端编码 + 开 HLS 会话，1~10 秒）
// → 拿到 URL → 才弹全屏。中间那段用户在列表页只看到一个小转圈，
// 然后突然被扔进一个纯黑的播放器，既没有片名也没有任何说明，
// 观感上跟「点了没反应 / 卡死」没区别。
//
// 改成：点击 → 立刻全屏，把等待过程摆开给人看（片名 + 阶段文案 + 已等待秒数 + 可取消），
// 拿到地址后再把舞台交给 VideoPlayerView。
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let path: String
    let title: String
    let assetType: String?
    let assetID: Int?
    let startAt: Double?
    let knownDuration: Double?
}

// MARK: - 播放宿主
// 只负责「拿到播放地址之前」这一段。拿到之后 VideoPlayerView 接管，
// 它自己还有一段首帧缓冲，那部分的反馈在 PlayerLoadingOverlay 里。
struct PlayerHostView: View {
    let request: PlaybackRequest

    @Environment(\.dismiss) private var dismiss

    @State private var target: PlaybackTarget?
    @State private var error: String?
    /// 重试计数。改它会让 .task(id:) 重跑
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let target {
                    VideoPlayerView(url: target.url,
                                    startPosition: target.startAt,
                                    timeOffset: target.timeOffset,
                                    sourcePath: target.sourcePath,
                                    knownDuration: target.knownDuration ?? request.knownDuration,
                                    title: target.title,
                                    assetType: target.assetType ?? request.assetType,
                                    assetID: target.assetID ?? request.assetID)
                } else {
                    PreparingOverlay(title: request.title,
                                     error: error,
                                     onCancel: { dismiss() },
                                     onRetry: { attempt += 1 })
                }
            }
        }
        .task(id: attempt) { await resolve() }
    }

    @MainActor
    private func resolve() async {
        guard let client = AppSession.shared.client else {
            error = "还没连接到服务器，请重新登录"
            return
        }
        error = nil
        do {
            target = try await client.resolvePlayback(
                path: request.path,
                startAt: request.startAt,
                title: request.title,
                assetType: request.assetType,
                assetID: request.assetID,
                knownDuration: request.knownDuration)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 准备界面
// 关键是把「在等什么」和「等了多久」写出来。
// 干转圈最大的问题不是慢，是**不知道还要等多久** —— 人会把未知的等待读成卡死。
private struct PreparingOverlay: View {
    let title: String
    let error: String?
    var onCancel: () -> Void
    var onRetry: () -> Void

    @State private var elapsed = 0

    var body: some View {
        VStack(spacing: 16) {
            if error == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                Button { onRetry() } label: {
                    Text("重试")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            Button("取消") { onCancel() }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 420)
        // 视图消失时 task 自动取消，不会漏计时器
        .task { await tick() }
    }

    private var message: String {
        guard error == nil else { return "准备失败" }
        switch elapsed {
        case 0..<3:  return "正在准备…"
        case 3..<8:  return "正在询问服务器这个文件怎么播"
        default:     return "还在准备（已 \(elapsed) 秒），第一次放这个文件会慢一些"
        }
    }

    @MainActor
    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
            elapsed += 1
        }
    }
}
