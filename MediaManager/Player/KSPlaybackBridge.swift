import Foundation
import AVFoundation
import UIKit
import KSPlayer

// MARK: - KSPlayer 引擎桥接
//
// 只负责「播得了吗、播到哪、什么状态」，不含任何 UI。
// 与 PlayerEngine 平行：AVPlayer 播不了的容器（MKV/AVI/WMV）或编码（hev1/DTS/AC3）
// 走这里，其余继续走 PlayerEngine 的系统硬解。
//
// @MainActor：KSPlayerLayerDelegate 本身标注 @MainActor，delegate 回调天然在主线程。
// Swift 5.9 语言模式下跨隔离调用只是警告，不会编译失败。
@MainActor
final class KSPlaybackBridge: NSObject, KSPlayerLayerDelegate {

    // MARK: 对外状态（回吐给 PlayerEngine，转成它那套 @Published）
    var onReady: ((Double) -> Void)?          // duration
    var onTime: ((Double, Double) -> Void)?   // current, total
    var onPlaying: ((Bool) -> Void)?          // isPlaying
    var onBuffered: ((Double) -> Void)?       // 已缓冲秒数
    var onFailure: ((String) -> Void)?
    var onEnd: (() -> Void)?
    /// load 创建好画面 view 后触发，画面层据此把它挂进容器
    var onRenderViewReady: (() -> Void)?

    private var layer: KSPlayerLayer?
    private(set) var renderView: UIView?

    // MARK: 装载
    func load(url: URL, startAt: Double?, autoplay: Bool, loop: Bool, rate: Float) {
        teardown()
        isTearingDown = false

        let options = KSOptions()
        // 双内核：AVPlayer(KSAVPlayer) 优先，解不了自动切 FFmpeg(KSMEPlayer)。
        // firstPlayerType 只有静态版，必须设在 KSOptions 静态属性上。
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        options.isLoopPlay = loop
        options.startPlayRate = rate
        options.registerRemoteControll = false  // 不让 KSPlayer 接管系统控制中心
        if let s = startAt, s.isFinite, s > 0 {
            options.startPlayTime = s
        }

        // isAutoPlay 统一传 false，起播由下面手动 play() 控制，避免 init 里重复 prepareToPlay。
        let ksLayer = KSPlayerLayer(url: url, isAutoPlay: false, options: options, delegate: self)
        layer = ksLayer
        renderView = ksLayer.player.view
        onRenderViewReady?()

        if autoplay { ksLayer.play() }
    }

    /// 把 KSPlayer 的纯画面 view 铺满容器。
    /// ⚠️ 只在初次挂载时调用：内核从 KSAVPlayer 切 KSMEPlayer 时，KSPlayerLayer 会在
    ///    player 的 didSet 里自动把新 view 插进 oldView.superview 并撑满、移除旧 view，
    ///    无需也不能在这里重复挂（否则两套 view 打架）。
    func attachRenderView(into container: UIView) {
        guard let renderView, renderView.superview !== container else { return }
        renderView.removeFromSuperview()
        container.addSubview(renderView)
        renderView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: container.topAnchor),
            renderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: 控制（对齐 PlayerEngine 的公开方法）
    func play() { layer?.play() }
    func pause() { layer?.pause() }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        layer?.seek(time: seconds, autoPlay: true) { _ in }
    }

    func setRate(_ newRate: Float) { layer?.player.playbackRate = newRate }

    /// 真实内核类型名（KSAVPlayer / KSMEPlayer），诊断用
    var kernelName: String {
        guard let layer else { return "—" }
        return String(describing: type(of: layer.player))
    }

    var duration: Double { layer?.player.duration ?? 0 }

    private var isTearingDown = false
    func teardown() {
        isTearingDown = true
        layer?.stop()
        layer = nil
        renderView?.removeFromSuperview()
        renderView = nil
    }

    // MARK: - KSPlayerLayerDelegate
    func player(layer _: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay:
            onReady?(duration)
        case .buffering, .bufferFinished:
            onPlaying?(true)
        case .paused, .initialized, .preparing, .playedToTheEnd:
            onPlaying?(false)
        case .error:
            break
        }
    }

    func player(layer _: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        onTime?(currentTime, totalTime)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if isTearingDown { return }
        if let error {
            onFailure?(error.localizedDescription)
        } else if !layer.options.isLoopPlay {
            onPlaying?(false)
            onEnd?()
        }
    }

    func player(layer _: KSPlayerLayer, bufferedCount _: Int, consumeTime: TimeInterval) {
        onBuffered?(consumeTime)
    }
}
