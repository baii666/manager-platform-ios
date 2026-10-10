import SwiftUI
import UIKit

// MARK: - 远程图片（带渐变占位降级 + 内存/磁盘缓存）
// 有 URL 走 ImageCache（内存 + 磁盘两层缓存，跨会话命中）；
// 没有 URL 或加载失败时，退回到「渐变 + 图标」占位。
struct RemoteImage: View {
    let url: URL?
    var fallbackIcon: String
    var fallbackColors: [Color]

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, fallbackIcon: String = "photo", fallbackColors: [Color] = [Color.gray.opacity(0.35), Color.gray.opacity(0.12)]) {
        self.url = url
        self.fallbackIcon = fallbackIcon
        self.fallbackColors = fallbackColors
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
        // ⚠️ 用 task(id: url) 而非 onAppear：url 变化（竖版海报 → 横版 fanart）时
        // task 会取消旧任务并重新加载。之前用 onAppear + `guard image == nil`，
        // url 变了但 image 已非 nil，永远不加载新封面 —— 这就是「横版封面没生效」的根因。
        .task(id: url) {
            await load(url)
        }
    }

    @MainActor
    private func load(_ url: URL?) async {
        guard let url else {
            image = nil
            failed = false
            return
        }
        // 切源时先清掉旧图，避免旧海报在新比例框里被裁着显示一瞬
        if image != nil { image = nil }
        failed = false
        if let img = await ImageCache.shared.load(from: url) {
            image = img
        } else {
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
