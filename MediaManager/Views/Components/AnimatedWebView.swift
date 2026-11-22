import SwiftUI
import UIKit
import ImageIO

// MARK: - 动态封面（animated WebP）
// 后端 album_video_cover 任务生成的 motion_path 是 animated WebP
// （480w / 10fps / 4s / libwebp_anim）。iOS 17 的 UIImage(data:) 只能拿第一帧，
// 所以这里用 ImageIO 逐帧解码 + Task 按帧延迟轮播，纯原生、无第三方依赖。
//
// 用法：静态 RemoteImage 打底，本视图叠在上面；动图解不出来（非动图/解码失败）
// 时 frames 为空 → 整个视图空渲染，底下的静态封面自然露出来。
struct AnimatedWebView: View {
    let url: URL?

    @State private var frames: [UIImage] = []
    @State private var delays: [TimeInterval] = []
    @State private var index = 0
    /// 解码 / 轮播任务，URL 变化或视图消失时取消，避免旧图覆盖新图
    @State private var loadTask: Task<DecodedFrames?, Never>?
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        Group {
            if frames.count > 1 {
                Image(uiImage: frames[index])
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url?.absoluteString) { await load() }
        .onDisappear { stopAnimating() }
    }

    /// ImageIO 解码放后台：animated WebP 逐帧解码是 CPU 密集，别卡主线程。
    @MainActor
    private func load() async {
        loadTask?.cancel()
        playTask?.cancel()
        loadTask = nil
        playTask = nil
        guard let url else {
            frames = []; delays = []; return
        }
        let task = Task.detached(priority: .utility) { () -> DecodedFrames? in
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            guard count > 1 else { return nil } // 单帧 = 静态 WebP，交给底层 RemoteImage
            var imgs: [UIImage] = []
            var ds: [TimeInterval] = []
            for i in 0..<count {
                guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                imgs.append(UIImage(cgImage: cg))
                ds.append(animatedWebPDelay(at: i, in: source))
            }
            guard !imgs.isEmpty else { return nil }
            return DecodedFrames(imgs, ds)
        }
        loadTask = task
        let result = await task.value
        guard !Task.isCancelled else { return }
        frames = result?.images ?? []
        delays = result?.delays ?? []
        index = 0
        startAnimating()
    }

    // MARK: - 轮播
    // Task + sleep 在主 actor 上直接改 @State，无 weak struct / Sendable 坑。
    @MainActor
    private func startAnimating() {
        playTask?.cancel()
        guard frames.count > 1, !delays.isEmpty else { return }
        playTask = Task { @MainActor in
            while !Task.isCancelled {
                let d = delays[index % delays.count]
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, d) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                index = (index + 1) % frames.count
            }
        }
    }

    @MainActor
    private func stopAnimating() {
        playTask?.cancel()
        playTask = nil
        loadTask?.cancel()
        loadTask = nil
    }
}

/// WebP 每帧延迟（秒）。属性在 kCGImagePropertyWebPDictionary 里，
/// 缺省 0.1s（10fps，与后端生成口径一致）。放顶层才能在 detached @Sendable 闭包里调。
private func animatedWebPDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any],
          let raw = webp[kCGImagePropertyWebPDelayTime] as? NSNumber else { return 0.1 }
    let d = raw.doubleValue
    return d > 0 && d.isFinite ? d : 0.1
}

/// 解码结果的盒装：UIImage 数组跨 detached 闭包需显式声明 Sendable。
private final class DecodedFrames: @unchecked Sendable {
    let images: [UIImage]
    let delays: [TimeInterval]
    init(_ images: [UIImage], _ delays: [TimeInterval]) {
        self.images = images
        self.delays = delays
    }
}
