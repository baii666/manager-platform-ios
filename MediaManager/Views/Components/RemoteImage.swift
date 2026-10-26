import SwiftUI
import UIKit

// MARK: - 远程图片（带渐变占位降级 + 内存/磁盘缓存）
// 有 URL 走 ImageCache（内存 + 磁盘两层缓存，跨会话命中）；
// 没有 URL 或加载失败时，退回到「渐变 + 图标」占位。
struct RemoteImage: View {
    let url: URL?
    var fallbackIcon: String
    var fallbackColors: [Color]
    /// 每次出现都回源一次（给详情页主海报用：那儿没有下拉刷新，
    /// 不回源的话换了海报要等下次清缓存才看得到）。一张图的代价，可控。
    var reloadOnAppear: Bool = false

    @State private var image: UIImage?
    @State private var failed = false
    /// 上一次加载的 URL（区分「换图」和「同一个 URL 重新回源」）
    @State private var lastURL: URL? = nil
    /// 封面回源中心：下拉刷新后代数 +1，本组件的加载任务随之重跑一次
    @ObservedObject private var refresh = ImageRefreshCenter.shared

    init(url: URL?, fallbackIcon: String = "photo",
         fallbackColors: [Color] = [Color.gray.opacity(0.35), Color.gray.opacity(0.12)],
         reloadOnAppear: Bool = false) {
        self.url = url
        self.fallbackIcon = fallbackIcon
        self.fallbackColors = fallbackColors
        self.reloadOnAppear = reloadOnAppear
    }

    /// 加载任务的身份：URL + 刷新代数。
    /// 只写 URL 的话，下拉刷新（列表数据变了但封面 URL 一字不差）不会重跑，
    /// 于是服务端换了海报、App 这边永远停在旧图。
    private var taskKey: String {
        "\(url?.absoluteString ?? "")#\(refresh.generation)"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if url != nil, !failed {
                placeholder
            } else {
                placeholder
            }
        }
        // ⚠️ 用 task(id:) 而非 onAppear：
        //   · url 变化（竖版海报 → 横版 fanart）时重跑 —— 之前用 onAppear +
        //     `guard image == nil`，url 变了但 image 已非 nil，永远不加载新封面，
        //     这就是「横版封面没生效」的根因；
        //   · 刷新代数变化时重跑 —— 封面 URL 是稳定的，不带上代数的话
        //     下拉刷新也叫不动图片加载，服务端换了海报 App 这边永远停在旧图。
        .task(id: taskKey) {
            await load(url)
        }
    }

    @MainActor
    private func load(_ url: URL?) async {
        guard let url else {
            image = nil
            failed = false
            lastURL = nil
            return
        }
        // 只有「换了一张图」才清旧图：避免旧海报在新比例框里被裁着显示一瞬。
        // 同一个 URL 的回源刷新不清 —— 下载失败时旧图还顶着，不会开天窗。
        if lastURL != url {
            image = nil
            failed = false
            lastURL = url
        }
        // 刚下拉刷新过 → 让这张图回源一次（绕开 immutable + 本地两层缓存）
        let force = reloadOnAppear || refresh.shouldReloadFromSource
        if let img = await ImageCache.shared.load(from: url, forceReload: force) {
            image = img
            failed = false
        } else if image == nil {
            failed = true
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: fallbackColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: fallbackIcon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

extension View {
    /// 把内容压进「父级实际给到的尺寸」里渲染。
    ///
    /// `Image.resizable().scaledToFill()` 在拿不到确定尺寸时，会按
    /// **原图像素**当 ideal size 使用（3000×4000 / 1920×1080 / 1080×1920 …）。
    /// 短视频封面是 FFmpeg 直接抽帧，横竖分辨率完全没有统一标准，于是一旦父级约束
    /// 不是硬性的，封面就会按各自的原始尺寸渲染、互相压住。
    ///
    /// ⚠️ 用法：尺寸 frame 必须写在**外面** —— `RemoteImage(...).imageFilled().frame(height: h)`
    /// 反了的话 GeometryReader 拿不到确定尺寸，反而会塌缩。
    func imageFilled() -> some View {
        GeometryReader { geo in
            self.frame(width: geo.size.width, height: geo.size.height).clipped()
        }
    }
}
