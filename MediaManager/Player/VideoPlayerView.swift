import SwiftUI
import AVKit
import AVFoundation

// MARK: - 视频播放器
// 封装 AVPlayerViewController 以获得系统级播放体验：
// HLS 播放、画中画(PiP)、AirPlay 投屏、锁屏/灵动岛控制、后台播放、续播定位。
// 这是整个 App「极致体验」的核心：AVKit 就是 iPad 视频播放的天花板。
struct VideoPlayerView: View {
    let url: URL
    var startPosition: Double? = nil   // 秒，继续观看续播
    var title: String? = nil

    @State private var player: AVPlayer?

    var body: some View {
        PlayerControllerRepresentable(player: player)
            .ignoresSafeArea()
            .navigationTitle(title ?? "播放")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { setupPlayer() }
            .onDisappear { teardownPlayer() }
    }

    // MARK: 播放器生命周期

    private func setupPlayer() {
        guard player == nil else { return }
        configureAudioSession()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)

        // 续播：seek 到上次观看位置
        if let startPosition, startPosition > 0 {
            let time = CMTime(seconds: startPosition, preferredTimescale: 600)
            newPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        player = newPlayer
        newPlayer.play()
    }

    private func teardownPlayer() {
        player?.pause()
    }

    /// 配置音频会话：后台播放 + 视频模式（锁屏控制、AirPlay 依赖它）
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

// MARK: - AVPlayerViewController 桥接
// SwiftUI 无法直接承载 AVPlayerViewController，用 representable 包一层。
private struct PlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
    }
}
