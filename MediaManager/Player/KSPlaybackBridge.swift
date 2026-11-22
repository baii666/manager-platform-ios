import Foundation
import AVFoundation
import UIKit
// @preconcurrency：KSPlayer 模块里 KSPlayerLayer 遵循了 @MainActor 的
// MediaPlayerDelegate，整个类被推断为 @MainActor。跨模块调用它的 init/play/seek
// 在未启用严格并发时是警告；加 @preconcurrency 明确把这类跨模块隔离检查降级，
// 避免某些 Xcode 配置下升级为 error。
@preconcurrency import KSPlayer

// MARK: - 音轨信息（值类型）
/// KSPlayer 的音轨协议对象生命周期跟着 player 实例走，内核切换后会失效，
/// 不适合直接丢给 SwiftUI。这里拍成纯值。
/// detail 是 KSPlayer 的 description（含 codec / 采样率 / 声道 / 语言），
/// UI 上据此区分「人声轨」和「纯音乐轨」。
struct KSAudioTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    let detail: String
    let isEnabled: Bool
}

// MARK: - KSPlayer 引擎桥接
//
// 只负责「播得了吗、播到哪、什么状态」，不含任何 UI。
// 与 PlayerEngine 平行：AVPlayer 播不了的容器（MKV/AVI/WMV）或编码（hev1/DTS/AC3）
// 走这里，其余继续走 PlayerEngine 的系统硬解。
//
// 🔴 关键：本类**故意不遵循** KSPlayerLayerDelegate。
//    该协议标注了 @MainActor，按 SE-0316，遵循它的类型（含 init）会被整体推断为
//    @MainActor；而 PlayerEngine 是非隔离类，在它的属性初始化器里 `KSPlaybackBridge()`
//    就会报「call to main actor-isolated initializer from a nonisolated context」硬错误。
//    @preconcurrency import 只作用于导入模块，改不了本模块类型的推断，无效。
//    KSPlayerLayer 的 delegate 是可选的，传 nil 合法；内核自动切换在 layer 内部完成
//    （layer 自己把 player.delegate = self），不依赖外部 delegate。
//    因此这里用定时轮询 player 的同步属性来回吐状态，彻底避开 @MainActor 协议。
final class KSPlaybackBridge: NSObject {

    // MARK: 对外状态（回吐给 PlayerEngine，转成它那套 @Published）
    var onReady: ((Double) -> Void)?          // duration
    var onTime: ((Double, Double) -> Void)?   // current, total
    var onPlaying: ((Bool) -> Void)?          // isPlaying
    var onBuffered: ((Double) -> Void)?       // 已缓冲秒数
    var onFailure: ((String) -> Void)?
    var onEnd: (() -> Void)?
    /// 真实内核名（KSAVPlayer / KSMEPlayer）变化时回吐，供状态栏角标显示。
    var onKernel: ((String) -> Void)?
    /// load 创建好画面 view 后触发，画面层据此把它挂进容器
    var onRenderViewReady: (() -> Void)?
    /// 音轨列表（ready 后及切换内核后回吐，供 UI 显示/手动切换）
    var onAudioTracks: (([KSAudioTrack]) -> Void)?

    private var layer: KSPlayerLayer?
    private(set) var renderView: UIView?

    private var pollTimer: Timer?
    private var loop = false
    private var isTearingDown = false
    private var readySent = false
    private var lastPlaying: Bool?
    private var wasFinished = false
    private var lastKernelName = ""
    /// 是否已经处理过音轨（每次内核切换后重置，只处理一次）
    private var audioTracksHandled = false

    // MARK: 装载
    func load(url: URL, startAt: Double?, autoplay: Bool, loop: Bool, rate: Float) {
        teardown()
        isTearingDown = false
        self.loop = loop
        readySent = false
        lastPlaying = nil
        wasFinished = false
        lastKernelName = ""
        audioTracksHandled = false

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

        // delegate 传 nil：避开 @MainActor 协议推断；状态改由下面的轮询读取。
        // isAutoPlay 统一传 false，起播由下面手动 play() 控制，避免 init 里重复 prepareToPlay。
        let ksLayer = KSPlayerLayer(url: url, isAutoPlay: false, options: options, delegate: nil)
        layer = ksLayer
        renderView = ksLayer.player.view
        onRenderViewReady?()

        if autoplay { ksLayer.play() }
        startPolling()
    }

    // MARK: 状态轮询（替代 delegate 回调）
    /// 每 0.1s 读一次 player 的同步属性。这些属性在 MediaPlayerProtocol 里都是
    /// 非隔离可读的，且 layer 内部完成内核切换后 player 实例会被替换——轮询拿到的
    /// 始终是切换后的真实 player。
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isTearingDown, let layer else { return }
        let player = layer.player

        // 内核名变化就回吐：初次是 KSAVPlayer，解不了切到 KSMEPlayer 时这里能捕获到。
        let name = String(describing: type(of: player))
        if name != lastKernelName {
            lastKernelName = name
            onKernel?(name)
            // 内核切换会换掉 player 实例，音轨也跟着变 → 重新采集
            audioTracksHandled = false
        }

        let total = player.duration
        if total.isFinite, total > 0, !readySent {
            readySent = true
            onReady?(total)
        }

        // 就绪后采集一次音轨：回吐给 UI，并自动避开纯音乐轨。
        // 必须等 duration 有效（≈tracks 已就绪）再做，太早 tracks 还是空的。
        if !audioTracksHandled, total.isFinite, total > 0 {
            audioTracksHandled = true
            collectAudioTracks(player)
        }
        let current = player.currentPlaybackTime
        onTime?(current.isFinite ? current : 0, total.isFinite ? total : 0)

        let playing = player.isPlaying
        if playing != lastPlaying {
            lastPlaying = playing
            onPlaying?(playing)
        }

        // 播完：loop 交给 KSPlayer 的 isLoopPlay 自己处理，这里只在非循环时通知外层。
        let finished = player.playbackState == .finished
        if finished && !wasFinished {
            wasFinished = true
            if !loop {
                onPlaying?(false)
                onEnd?()
            }
        } else if !finished {
            wasFinished = false
        }
    }

    // MARK: 音轨
    /// 采集音轨并回吐；多音轨时自动避开明显的纯音乐轨。
    /// KSPlayer 的 FFmpeg 内核默认用 av_find_best_stream 选轨，番号/多语言片源
    /// 常同时有「人声轨 + 纯音乐轨」，它会挑错 → 只有音乐没有人声。
    private func collectAudioTracks(_ player: any MediaPlayerProtocol) {
        let tracks = player.tracks(mediaType: .audio)
        var snap = tracks.map { t in
            KSAudioTrack(id: t.trackID, name: t.name,
                         detail: t.description, isEnabled: t.isEnabled)
        }
        guard snap.count > 1 else {
            onAudioTracks?(snap)
            return
        }
        // 已经有启用轨且它不是"明显音乐轨"时，尊重 KSPlayer/片源的选择，不乱动。
        // 只有当前启用轨明显是音乐轨、且存在另一条更像人声的轨时才切。
        let currentIsMusic = snap.first(where: { $0.isEnabled }).map(Self.looksLikeMusic) ?? false
        if currentIsMusic, let vocal = snap.first(where: { !$0.isEnabled && !Self.looksLikeMusic($0) }) {
            if let real = tracks.first(where: { $0.trackID == vocal.id }) {
                player.select(track: real)
                snap = tracks.map { t in
                    KSAudioTrack(id: t.trackID, name: t.name,
                                 detail: t.description, isEnabled: t.isEnabled)
                }
            }
        }
        onAudioTracks?(snap)
    }

    /// 名字/描述/语言里出现这些词，基本可判定是纯音乐、伴奏、M&E 轨。
    private static func looksLikeMusic(_ t: KSAudioTrack) -> Bool {
        let text = (t.name + " " + t.detail).lowercased()
        let markers = ["music", "bgm", "伴奏", "inst", "instrumental", "m&e", "score", "soundtrack", "ost"]
        return markers.contains { text.contains($0) }
    }

    /// 手动切音轨：UI 菜单选中某条后调用。
    func selectAudioTrack(id: Int32) {
        guard let player = layer?.player else { return }
        guard let track = player.tracks(mediaType: .audio).first(where: { $0.trackID == id }) else { return }
        player.select(track: track)
        let snap = player.tracks(mediaType: .audio).map { t in
            KSAudioTrack(id: t.trackID, name: t.name,
                         detail: t.description, isEnabled: t.isEnabled)
        }
        onAudioTracks?(snap)
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

    func teardown() {
        isTearingDown = true
        pollTimer?.invalidate()
        pollTimer = nil
        layer?.stop()
        layer = nil
        renderView?.removeFromSuperview()
        renderView = nil
    }
}
