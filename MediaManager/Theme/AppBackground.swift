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
                    // ⚠️ 先 clipped 再 overlay：scaledToFill 的绘制会超出自己的 frame，
                    // 不裁的话压暗层只盖住 frame，四周溢出部分就是没压暗的亮图
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
    func appBackground() -> some View {
        background { AppBackgroundView() }
    }
}
