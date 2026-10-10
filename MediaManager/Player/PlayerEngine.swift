import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import UIKit

// MARK: - 播放引擎
// 只负责 AVPlayer 的状态与控制，不含任何 UI。
// 刻意不自己写解码：AVPlayer 底层走 VideoToolbox 硬件解码，
// 是 iPad 上 H.264/HEVC/HDR/杜比视界的天花板；自绘内核只会丢能力、增功耗。
final class PlayerEngine: ObservableObject {

    // MARK: 对外状态（全部在主线程更新）

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loadedRange: Double = 0
    @Published private(set) var isReady = false
    @Published private(set) var rate: Float = 1.0
    /// 播放失败原因。之前播放器没有任何错误状态，任何失败都是「静默白屏」，无法定位
    @Published private(set) var failure: String? = nil
    /// 视频轨存在但被 AVPlayer 禁用 —— 画面解不出来，声音照常。
    ///
    /// ⚠️ 这种情况 `item.status` 依然是 `.readyToPlay`，**不会**走 `.failed`，
    /// 所以不会触发上面的 failure，界面表现就是「只有声音没有画面」的黑屏。
    /// 最典型的触发源不是编码本身，而是**封装 tag**：MP4 里装 HEVC 有两种 sample entry，
    /// AVFoundation 只认 `hvc1`，ffmpeg 及多数封装工具写出来的是 `hev1`，
    /// 碰上就直接禁用视频轨 —— iPad Air M4 解 10-bit HEVC 毫无压力，不是能力问题。
    @Published private(set) var videoTrackDisabled = false

    /// 用户正在拖动进度条 / 快进手势中。为 true 时屏蔽时间回调，避免进度条回跳。
    var isScrubbing = false

    let player = AVPlayer()

    /// 倍速档位。上限 2.0：再高 AVPlayer 会静音，且部分格式 seek 不稳。
    static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var timeObserver: Any?
    private var playStateObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?

    /// 续播位置。需要等 item ready 才能 seek，故先存起来。
    private var pendingStart: Double?
    /// 当前装载的 URL，供 retry 使用
    private var currentURL: URL?
    /// 视频轨复查（延迟执行）
    private var trackCheckWork: DispatchWorkItem?

    // MARK: 画中画
    // 放弃 AVPlayerViewController 后系统 PiP 按钮也没了，必须自己接回来，
    // 否则等于丢能力。由承载 AVPlayerLayer 的视图创建后回填。
    /// 必须强引用：AVPictureInPictureController 创建后若无强持有会立即释放，PiP 直接失效
    var pipController: AVPictureInPictureController?

    var isPiPSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    var isPiPActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    deinit { teardown() }

    // MARK: 装载

    func load(url: URL, startAt: Double?) {
        teardown()
        currentURL = url
        failure = nil
        videoTrackDisabled = false
        trackCheckWork?.cancel()
        isReady = false
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        pendingStart = (startAt ?? 0) > 0 ? startAt : nil
        bindItem(item)
        bindPlayer()
        startTicking()
        player.play()
    }

    /// 失败后重试：默认从断点续播
    func retry() {
        guard let url = currentURL else { return }
        load(url: url, startAt: currentTime > 1 ? currentTime : nil)
    }

    /// tracks 不一定在 readyToPlay 那一刻就填充好，所以要复查一次 ——
    /// 但**不该无脑等 2 秒**：hev1 那种情况 tracks 通常是齐的，
    /// 第一次 checkVideoTracks 就已经判出来了，立刻降级能省掉整段空等。
    /// 只有 tracks 还是空的时候才说明「还没解析出来」，那时早点复查（0.6s）；
    /// 已经判过一次正常的，1.5 秒后再兜一次底就够了。
    private func scheduleTrackRecheck(_ item: AVPlayerItem) {
        trackCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item else { return }
            self.checkVideoTracks(item)
        }
        trackCheckWork = work
        let delay = item.tracks.isEmpty ? 0.6 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 视频轨是否被本机解得出。
    /// - 一条视频轨都没有：不是视频文件（或还没解析出来），不报
    /// - 有视频轨但全被禁用：解不出画面 → 只有声音
    private func checkVideoTracks(_ item: AVPlayerItem) {
        let video = item.tracks.filter { $0.assetTrack?.mediaType == .video }
        guard !video.isEmpty else { return }
        if video.allSatisfy({ !$0.isEnabled }) {
            videoTrackDisabled = true
        }
    }

    func teardown() {
        trackCheckWork?.cancel()
        trackCheckWork = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate(); statusObservation = nil
        durationObservation?.invalidate(); durationObservation = nil
        bufferObservation?.invalidate(); bufferObservation = nil
        playStateObservation?.invalidate(); playStateObservation = nil
        player.pause()
    }

    // MARK: KVO

    private func bindItem(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReady = item.status == .readyToPlay
                if item.status == .readyToPlay {
                    self.applyDuration(item.duration)
                    self.checkVideoTracks(item)
                    // 轨道启用状态不一定在 ready 的那一刻就定下来，稍后再确认一次
                    self.scheduleTrackRecheck(item)
                    if let start = self.pendingStart {
                        self.pendingStart = nil
                        self.seek(to: start)
                    }
                } else if item.status == .failed {
                    let desc = item.error?.localizedDescription ?? "未知错误"
                    self.failure = desc
                }
            }
        }

        durationObservation = item.observe(\.duration) { [weak self] item, _ in
            DispatchQueue.main.async { self?.applyDuration(item.duration) }
        }

        bufferObservation = item.observe(\.loadedTimeRanges) { [weak self] item, _ in
            guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return }
            let end = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
            DispatchQueue.main.async { self?.loadedRange = end.isFinite ? end : 0 }
        }
    }

    private func bindPlayer() {
        playStateObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
    }

    /// CMTime 在流未就绪时是 indefinite（seconds 为 NaN），必须过滤后再赋给 @Published
    private func applyDuration(_ time: CMTime) {
        let secs = CMTimeGetSeconds(time)
        duration = secs.isFinite && secs > 0 ? secs : 0
    }

    private func startTicking() {
        let half = CMTime(value: 1, timescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: half, queue: .main) { [weak self] time in
            guard let self else { return }
            if self.isScrubbing { return }
            let secs = CMTimeGetSeconds(time)
            guard secs.isFinite else { return }
            DispatchQueue.main.async { self.currentTime = secs }
        }
    }

    // MARK: 控制

    func play() {
        player.rate = rate
    }

    func pause() {
        player.pause()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    /// 切换倍速。暂停状态下只记录，等 play() 时生效（AVPlayer.rate > 0 才代表播放）。
    func setRate(_ newRate: Float) {
        rate = newRate
        guard isPlaying else { return }
        player.rate = newRate
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let target = duration > 0 ? min(seconds, duration) : seconds
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.currentTime = target }
        }
    }

    /// 相对快进 / 快退（秒），用于手势
    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }
}

// MARK: - 系统音量
// iOS 没有公开的「写音量」API。常规做法是把一个隐藏的 MPVolumeView 放进视图层级，
// 取出它内部的 UISlider 来写值；读值仍走 AVAudioSession（准确反映系统当前音量）。
final class SystemVolume {

    static let shared = SystemVolume()

    private weak var container: MPVolumeView?

    private init() {}

    func attach(_ view: MPVolumeView) {
        container = view
    }

    var value: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func set(_ value: Float) {
        guard let container else { return }
        // 每次都重新查找：MPVolumeView 加入 window 后才会创建内部 slider
        findSlider(in: container)?.value = min(max(value, 0), 1)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - 时间格式化

enum PlayerTimeFormatter {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
