import SwiftUI
import UIKit
import KSPlayer

// MARK: - KSPlayer 内核最小验证 demo
// 目的：在完全不碰现有 AVPlayer 播放器的前提下，验证 KSPlayer 2.3.4（GPL 源码版）
// 能否在 iPhone 真机编译、能否播放 MKV/HEVC/DTS 等 AVPlayer 播不了的格式。
//
// ⚠️ 这是临时验证页，验证通过后才会决定要不要替换主播放器。
// ⚠️ 引入 KSPlayer 需要重新 `xcodegen generate`（project.yml 已加 SPM 依赖）。
//
// 版本选择很关键：
// - 5.6.2 / main 的 GPL 版是预编译二进制，只带模拟器/Mac/tvOS slice，没有 iOS 真机，
//   且 swift-tools 6.2（要 Xcode 26+）→ 真机编不过。
// - 2.3.4 是 GPL 源码版，swift-tools 5.9、iOS 13+，真机可编译，正是自用要的版本。

// MARK: - 诊断面板数据
// 播起来之后叠在画面左上角，用来判断「到底有没有切到 FFmpeg 内核」——
// 光看能不能出画没用：MP4/H264 系统 AVPlayer 自己就能播，播通了也证明不了 FFmpeg 生效。
private final class PlayerDiag: ObservableObject {
    @Published var state = "初始化"
    @Published var kernel = "—"
    @Published var format = "—"
    @Published var error = ""
    @Published var buffered = 0
}

struct KSPlayerDemoView: View {
    /// 默认给一个公开 H.264 测试片，先验证链路通；再填自己的 MKV/HEVC 片源验证格式兼容。
    @State private var urlText = "http://baobab.wdjcdn.com/14525705791193.mp4"
    @State private var activeURL: URL?
    @StateObject private var diag = PlayerDiag()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("视频 URL（可填 MKV / HEVC / DTS）", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.subheadline)
                Button("播放") {
                    activeURL = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal)

            if let url = activeURL {
                ZStack(alignment: .topLeading) {
                    // .id(url) 保证换 URL 时重建内核视图（updateUIView 不负责换源）
                    KSPlayerContainer(url: url, diag: diag)
                        .id(url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    // 诊断叠层：半透明黑底等宽字，不挡播放控制栏
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内核: \(diag.kernel)")
                        Text("格式: \(diag.format)")
                        Text("状态: \(diag.state)")
                        Text("缓冲: \(diag.buffered)")
                        if !diag.error.isEmpty {
                            Text("错误: \(diag.error)")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("输入视频 URL 开始测试")
                        .font(.subheadline.weight(.medium))
                    Text("先用公开 MP4 验证链路，再填一个 MKV/HEVC 片源\n看 AVPlayer 播不了的格式 KSPlayer 能否播")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
        }
        .navigationTitle("KSPlayer 内核测试")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - UIKit 桥接
// IOSVideoPlayerView 是 UIKit 的 UIView，自带播放 UI（进度条、全屏、音量/亮度手势），
// 这里只做最小包装，不改它的任何行为，只额外挂一个 delegate 收集诊断信息。
private struct KSPlayerContainer: UIViewRepresentable {
    let url: URL
    let diag: PlayerDiag

    func makeCoordinator() -> Coordinator {
        Coordinator(diag: diag)
    }

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        // 让 KSPlayer 在 AVPlayer 解不了时自动切到 FFmpeg 内核（KSMEPlayer）——
        // 这正是能播 MKV/HEVC/DTS 的关键。默认值已是 KSMEPlayer.self，这里显式设一次更稳。
        KSOptions.secondPlayerType = KSMEPlayer.self
        let view = IOSVideoPlayerView()
        // delegate 是 weak，Coordinator 由 SwiftUI 通过 makeCoordinator 强持有
        view.delegate = context.coordinator
        context.coordinator.view = view
        // ⚠️ 2.3.4 真实签名是 set(url:options:)（README 的单参数写法已过时）；
        // options 必填，传默认 KSOptions() 即可。
        view.set(url: url, options: KSOptions())
        return view
    }

    func updateUIView(_ uiView: IOSVideoPlayerView, context: Context) {
        // 换源靠外层 .id(url) 重建，这里不做任何事
    }

    // MARK: 诊断收集
    // 实现 KSPlayer 的 PlayerControllerDelegate，把内核切换 / 错误 / 缓冲状态写回面板。
    // 用 String(describing: type(of: player)) 拿内核名（KSAVPlayer / KSMEPlayer），
    // 不依赖具体枚举 case，降低编译风险。
    final class Coordinator: NSObject, PlayerControllerDelegate {
        let diag: PlayerDiag
        weak var view: IOSVideoPlayerView?

        init(diag: PlayerDiag) {
            self.diag = diag
        }

        /// 读当前 playerLayer 的真实内核与封装格式。
        private func refreshKernel() {
            guard let layer = view?.playerLayer else { return }
            // 先在调用线程取值，避免把非 Sendable 的 layer 带进 main 闭包
            let kernelName = String(describing: type(of: layer.player))
            let formatName = layer.options.formatName
            DispatchQueue.main.async {
                self.diag.kernel = kernelName
                self.diag.format = formatName.isEmpty ? "—" : formatName
            }
        }

        func playerController(state: KSPlayerState) {
            let s = "\(state)"
            DispatchQueue.main.async { self.diag.state = s }
            refreshKernel()
        }

        func playerController(currentTime: TimeInterval, totalTime: TimeInterval) {
            // 进度不做展示，避免刷屏
        }

        func playerController(finish error: Error?) {
            let msg = error.map { "\($0)" } ?? ""
            DispatchQueue.main.async {
                self.diag.state = "结束"
                self.diag.error = msg
            }
            // 内核切换发生在 finish 回调之后（AVPlayer 失败 → 切 KSMEPlayer），
            // 这里立刻读可能还是旧内核，延迟 0.5s 再读一次抓切换结果。
            refreshKernel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshKernel()
            }
        }

        func playerController(maskShow _: Bool) {}

        func playerController(action _: PlayerButtonType) {}

        func playerController(bufferedCount: Int, consumeTime _: TimeInterval) {
            DispatchQueue.main.async { self.diag.buffered = bufferedCount }
        }

        func playerController(seek _: TimeInterval) {}
    }
}
