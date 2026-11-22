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
struct KSPlayerDemoView: View {
    /// 默认给一个公开 H.264 测试片，先验证链路通；再填自己的 MKV/HEVC 片源验证格式兼容。
    @State private var urlText = "http://baobab.wdjcdn.com/14525705791193.mp4"
    @State private var activeURL: URL?

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
                // .id(url) 保证换 URL 时重建内核视图（updateUIView 不负责换源）
                KSPlayerContainer(url: url)
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
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
// 这里只做最小包装，不改它的任何行为。
private struct KSPlayerContainer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        // 让 KSPlayer 在 AVPlayer 解不了时自动切到 FFmpeg 内核（KSMEPlayer）——
        // 这正是能播 MKV/HEVC/DTS 的关键。默认值已是 KSMEPlayer.self，这里显式设一次更稳。
        KSOptions.secondPlayerType = KSMEPlayer.self
        let view = IOSVideoPlayerView()
        // ⚠️ 2.3.4 真实签名是 set(url:options:)（README 的单参数写法已过时）；
        // options 必填，传默认 KSOptions() 即可。
        view.set(url: url, options: KSOptions())
        return view
    }

    func updateUIView(_ uiView: IOSVideoPlayerView, context: Context) {
        // 换源靠外层 .id(url) 重建，这里不做任何事
    }
}
