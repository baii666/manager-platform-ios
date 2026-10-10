import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import UIKit

// MARK: - 播放目标
// ⚠️ 必须用 .fullScreenCover(item:) 而不是 isPresented + 另一个 @State URL。
// isPresented 版的内容闭包有时读到的是状态更新「之前」的值（nil），
// 表现成「封面弹出来了但没有地址」—— 白屏 / 空页面，且无从判断。
// 用 item: 则地址是参数直接传进闭包，不存在读写不同步的可能。
struct PlayerTarget: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 视频播放器
// 引擎仍是 AVPlayer（VideoToolbox 硬件解码，iPad 播放天花板），
// 但画面层与控制层全部自绘 —— 这是拿到 B 站式手势与倍速等交互的前提：
// AVPlayerViewController 的系统 UI 无法自定义。
//
// 放弃 AVPlayerViewController 后，三件系统能力必须自己接回来，否则等于丢能力：
//   1. 关闭按钮（原先 HomeView 入口依赖系统 Done 按钮）
//   2. 画中画 AVPictureInPictureController
//   3. AirPlay AVRoutePickerView
struct VideoPlayerView: View {
    let url: URL
    var startPosition: Double? = nil
    /// 时间轴基准偏移。HLS 走服务端 `-ss` 从断点切片时，AVPlayer 的时间轴是从 0 重新开始的，
    /// 上报进度必须加回这个偏移，否则 2 小时的电影从第 30 分钟续播，会被记成「看了 5 分钟」。
    var timeOffset: Double = 0
    /// 服务端已知的总时长。HLS 在 FFmpeg 跑完之前没有 `#EXT-X-ENDLIST`，
    /// AVPlayer 的 duration 是 indefinite（0），进度条和续播上报会一起失灵 —— 用它兜底。
    var knownDuration: Double? = nil
    var title: String? = nil
    /// 传了才会上报播放进度（对接统一行为层 POST /api/actions/progress）
    var assetType: String? = nil
    var assetID: Int? = nil

    @StateObject private var engine = PlayerEngine()
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    @State private var showRatePicker = false

    // 手势状态
    @State private var axis: DragAxis = .none
    @State private var startOnLeft = true
    @State private var seekBase: Double = 0
    @State private var brightnessBase: CGFloat = 0
    @State private var volumeBase: Float = 0
    @State private var pendingSeek: Double? = nil
    @State private var hud: String? = nil

    @State private var hideWork: DispatchWorkItem?
    @State private var reportTask: Task<Void, Never>?

    /// 横向滑满一屏对应的快进秒数
    private let seekSpan: Double = 120

    /// 进度条与上报用的总时长（绝对时间轴）
    private var displayDuration: Double {
        if engine.duration > 0 { return engine.duration + timeOffset }
        return knownDuration ?? 0
    }

    /// 进度条显示的当前位置（绝对时间轴）
    private var displayPosition: Double {
        pendingSeek ?? (engine.currentTime + timeOffset)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(engine: engine)

            // 必须真实存在于视图层级，MPVolumeView 才会创建内部 slider
            VolumeHijack()
                .frame(width: 1, height: 1)
                .opacity(0.01)

            gestureCapture

            if showControls {
                controls
                    .transition(.opacity)
            }

            if let hud {
                Text(hud)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
            }

            // 加载指示：没 ready 且没失败时给个转圈，别让人以为卡死
            if !engine.isReady, engine.failure == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            // 失败一定要看得见。之前没有任何错误状态，
            // URL 错 / 404 / 编解码不支持全都表现成「无声无画面」。
            if let failure = engine.failure {
                errorPanel(failure)
            }
        }
        .ignoresSafeArea()
        .navigationTitle(title ?? "播放")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    /// 失败面板：把原因和完整 URL 都摆出来，方便一眼判断是地址错、404 还是格式不支持
    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("无法播放")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Text(url.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button {
                engine.retry()
                scheduleHide()
            } label: {
                Text("重试")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 440)
    }

    // MARK: 手势层

    private var gestureCapture: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture)
            // 双击优先于单击，故先声明
            .onTapGesture(count: 2) { engine.togglePlay() }
            .onTapGesture { toggleControls() }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if axis == .none {
                    axis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal : .vertical
                    startOnLeft = value.startLocation.x < UIScreen.main.bounds.width / 2
                    seekBase = engine.currentTime + timeOffset
                    brightnessBase = UIScreen.main.brightness
                    volumeBase = SystemVolume.shared.value
                }
                engine.isScrubbing = true
                handleDrag(value.translation)
            }
            .onEnded { _ in
                if axis == .horizontal, let target = pendingSeek {
                    engine.seek(to: max(0, target - timeOffset))
                }
                engine.isScrubbing = false
                axis = .none
                pendingSeek = nil
                hud = nil
            }
    }

    private func handleDrag(_ t: CGSize) {
        let bounds = UIScreen.main.bounds
        switch axis {
        case .none:
            break
        case .horizontal:
            let width = Double(max(bounds.width, 1))
            let delta = Double(t.width) / width * seekSpan
            let target = min(max(seekBase + delta, 0), max(displayDuration, 0))
            pendingSeek = target
            hud = PlayerTimeFormatter.string(target) + " / " + PlayerTimeFormatter.string(displayDuration)
        case .vertical:
            let height = max(bounds.height, 1)
            if startOnLeft {
                let ratio = CGFloat(-t.height) / height
                let b = min(max(brightnessBase + ratio, 0), 1)
                UIScreen.main.brightness = b
                hud = "亮度 " + String(Int(b * 100)) + "%"
            } else {
                let ratio = Float(-t.height) / Float(height)
                let v = min(max(volumeBase + ratio, 0), 1)
                SystemVolume.shared.set(v)
                hud = "音量 " + String(Int(v * 100)) + "%"
            }
        }
    }

    // MARK: 控制层

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(controlScrim)
    }

    /// 上下压一层半透明黑，保证任何画面上文字都可读
    private var controlScrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(0.55), Color.clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
            Spacer()
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            playerButton("xmark") { dismiss() }
            Text(title ?? "")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if engine.isPiPSupported {
                playerButton(engine.isPiPActive ? "pip.exit" : "pip.enter") { engine.togglePiP() }
            }
            AirPlayButton()
                .frame(width: 30, height: 30)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            let display = displayPosition
            ScrubberView(
                duration: displayDuration,
                current: display,
                loaded: engine.loadedRange,
                onStart: { engine.isScrubbing = true },
                onChange: { value in
                    pendingSeek = value
                    hud = PlayerTimeFormatter.string(value) + " / " + PlayerTimeFormatter.string(displayDuration)
                },
                onEnd: { value in
                    engine.isScrubbing = false
                    pendingSeek = nil
                    hud = nil
                    engine.seek(to: max(0, value - timeOffset))
                    scheduleHide()
                }
            )

            HStack(spacing: 18) {
                playerButton(engine.isPlaying ? "pause.fill" : "play.fill") {
                    engine.togglePlay()
                    scheduleHide()
                }
                Text(PlayerTimeFormatter.string(display))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Text("/ " + PlayerTimeFormatter.string(displayDuration))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
                Spacer()
                playerButton("gobackward.10") { engine.seek(by: -10) }
                playerButton("goforward.10") { engine.seek(by: 10) }
                rateMenu
            }
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach(PlayerEngine.rates, id: \.self) { r in
                Button {
                    engine.setRate(r)
                    scheduleHide()
                } label: {
                    if abs(engine.rate - r) < 0.01 {
                        Label(rateText(r), systemImage: "checkmark")
                    } else {
                        Text(rateText(r))
                    }
                }
            }
        } label: {
            Text(rateText(engine.rate))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.2)))
        }
    }

    private func rateText(_ r: Float) -> String {
        if abs(r - 1.0) < 0.01 { return "倍速" }
        return String(format: "%gx", Double(r))
    }

    private func playerButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
    }

    // MARK: 生命周期

    private func setup() {
        configureAudioSession()
        engine.load(url: url, startAt: startPosition)
        scheduleHide()
        startProgressReporting()
    }

    private func teardown() {
        hideWork?.cancel()
        hideWork = nil
        reportTask?.cancel()
        reportTask = nil
        let pos = engine.currentTime + timeOffset
        // HLS 没跑完时 engine.duration 是 0，退回服务端已知的时长，否则这次观看根本不会记录
        let dur = engine.duration > 0 ? engine.duration + timeOffset : (knownDuration ?? 0)
        let type = assetType
        let id = assetID
        if let type, let id, dur > 0 {
            Task {
                if let client = AppSession.shared.client {
                    try? await client.reportProgress(type: type, id: id, position: pos, duration: dur)
                }
            }
        }
        engine.teardown()
    }

    /// 每 15 秒上报一次播放位置，关闭时再补一次
    private func startProgressReporting() {
        guard let type = assetType, let id = assetID else { return }
        // 用局部常量进 capture list：capture list 里直接写 self 的属性不稳妥
        let engineRef = engine
        let offset = timeOffset
        let fallback = knownDuration
        reportTask = Task { [weak engineRef] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                guard let engine = engineRef else { continue }
                let dur = engine.duration > 0 ? engine.duration + offset : (fallback ?? 0)
                guard dur > 0 else { continue }
                let pos = engine.currentTime + offset
                if let client = AppSession.shared.client {
                    try? await client.reportProgress(type: type, id: id, position: pos, duration: dur)
                }
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) { showControls = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

// MARK: - 手势方向

private enum DragAxis {
    case none
    case horizontal
    case vertical
}

// MARK: - AVPlayerLayer 承载
// 用 UIViewRepresentable 而非 AVPlayerViewController：后者自带系统 UI，挡不住自定义层。
private struct PlayerLayerView: UIViewRepresentable {
    let engine: PlayerEngine

    final class VideoView: UIView {
        var playerLayer: AVPlayerLayer { layer as? AVPlayerLayer ?? AVPlayerLayer() }
        override static var layerClass: AnyClass { AVPlayerLayer.self }
    }

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        let layer = view.playerLayer
        layer.player = engine.player
        layer.videoGravity = .resizeAspect
        // PiP 必须在 layer 绑好 player 之后创建
        DispatchQueue.main.async {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
            let controller = AVPictureInPictureController(playerLayer: layer)
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            engine.pipController = controller
        }
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.playerLayer.player = engine.player
    }
}

// MARK: - AirPlay
// AVRoutePickerView 是 UIKit 视图，包一层才能在 SwiftUI 里用。
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 隐藏音量视图
// MPVolumeView 只有真正进入视图层级才会创建内部 UISlider，
// 这里放一个 1x1、几乎全透明的点，供 SystemVolume 写入系统音量。
private struct VolumeHijack: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        // ⚠️ 别设 showsRouteButton：iOS 13 起已废弃（改用 AVRoutePickerView，本项目
        // 已用 AVRoutePickerView 做投屏入口）。这个 view 是 1x1 隐藏的，不需要路由按钮。
        SystemVolume.shared.attach(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        SystemVolume.shared.attach(uiView)
    }
}

// MARK: - 进度条
// 自绘而非 Slider：需要同时呈现「已缓冲」与「已播放」两段，且要跟手势层联动。
private struct ScrubberView: View {
    let duration: Double
    let current: Double
    let loaded: Double
    var onStart: () -> Void
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let played = CGFloat(ratio(of: current))
            let buffered = CGFloat(ratio(of: loaded))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.white.opacity(0.4)).frame(width: width * buffered, height: 4)
                Capsule().fill(Color.white).frame(width: width * played, height: 4)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .offset(x: max(0, width * played - 7))
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onStart()
                        }
                        onChange(seconds(at: value.location.x, width: width))
                    }
                    .onEnded { value in
                        dragging = false
                        onEnd(seconds(at: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 26)
    }

    private func ratio(of value: Double) -> Double {
        guard duration > 0, value.isFinite else { return 0 }
        return min(max(value / duration, 0), 1)
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        let r = min(max(Double(x / width), 0), 1)
        return r * max(duration, 0)
    }
}
