import SwiftUI

// MARK: - 全局背景层
// 有自定义背景图 → 铺满 + 压暗；没有 → 退回系统底色。
//
// ⚠️ 为什么需要它：window 的默认底色（和各页面自己写的
// .background(Color(uiColor: .systemBackground))）都是**不透明**的，
// 光在根视图后面垫一张图根本透不出来。所以凡是原来写 systemBackground 的地方
// 都要换成 .appBackground()，背景图才能真正被看见。
struct AppBackgroundView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        ZStack {
            if let image = appearance.backgroundImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // 磨砂：整个背景做成磨砂玻璃质感，不与前景内容抢清晰度。
                    // ⚠️ blur 必须在 clipped 之前：scaledToFill 的绘制本来就超出 frame，
                    // 模糊采样用的就是这些溢出像素，先裁后糊会在四边留出软边/黑边。
                    .blur(radius: appearance.blur)
                    // ⚠️ 先 clipped 再 overlay：不裁的话压暗层只盖住 frame，
                    // 四周溢出部分就是没压暗的亮图
                    .clipped()
                    // 压暗：不盖一层的话卡片文字压在亮图上根本看不清
                    .overlay(Color.black.opacity(appearance.dim))
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        // 顶到安全区外：状态栏 / home indicator 区域也要跟着变
        .ignoresSafeArea()
    }
}

extension View {
    /// 用全局背景填充（背景图 / 系统底色二选一，由 AppearanceSettings 决定）。
    /// 取代页面里原来那句 `.background(Color(uiColor: .systemBackground))`。
    ///
    /// ⚠️⚠️ 只能用在**主内容层**（页面根 / App 根）。绝对不要放进
    /// `safeAreaInset(edge:)` 的内容里（比如底栏）：safeAreaInset 层是合成在
    /// 主内容**之上**的，它内部的视图一 ignoresSafeArea 就会被提案成全屏，
    /// 整个背景/材质会盖到所有页面内容上面（真实踩坑：底栏背景把海报拦腰糊住）。
    /// 底栏这类悬浮层想要毛玻璃，直接 `.background(.ultraThinMaterial)` 就够了。
    func appBackground() -> some View {
        background { AppBackgroundView() }
    }
}

// MARK: - 毛玻璃面板
// 对齐网页版「图片背景主题」的效果：背景图全程透出，
// 卡片 / 搜索框 / 设置分组等面板全部换成半透明毛玻璃压在图上，
// 而不是把图压得很暗再叠不透明卡片。
//
// ⚠️ 没设背景图时仍回退原来的 secondarySystemBackground，
// 所以把页面里原来的 background(Color, in: 形状) 换成 appSurface(in: 形状)
// 不改变纯色主题下的任何观感。
struct AppSurfaceShape<S: Shape>: View {
    var shape: S
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Group {
            if appearance.hasBackground {
                // ultraThinMaterial：最透的毛玻璃，图能透出来又有足够对比度托住文字
                shape.fill(.ultraThinMaterial)
            } else {
                shape.fill(Color(uiColor: .secondarySystemBackground))
            }
        }
    }
}

extension View {
    /// 面板底：设了背景图 → 毛玻璃；没设 → secondarySystemBackground。
    /// 用法与 `.background(Color(...), in: 形状)` 一一对应，直接替换。
    func appSurface<S: Shape>(in shape: S) -> some View {
        background { AppSurfaceShape(shape: shape) }
    }
}
