import SwiftUI

// MARK: - 列表页顶部状态栏组件
// 之前「搜索 / 排序 / 库筛选」都塞在 navigationBar 的 toolbar 里（Menu 下拉），
// 视觉上很简陋。这里抽成独立、美观的顶部栏：搜索框 + 胶囊工具按钮，
// 样式对齐网页版 PageToolbar 的简洁风格。

/// 美观搜索框：圆角 + 放大镜 + 清除按钮
struct ListSearchBar: View {
    @Binding var text: String
    var placeholder: String = "搜索…"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// 胶囊工具按钮：图标 + 文字；高亮态用品牌色浅底
struct ToolChip: View {
    let label: String
    var icon: String? = nil
    var highlighted: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(highlighted ? Theme.brand : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                highlighted ? Theme.brand.opacity(0.14) : Color(uiColor: .secondarySystemBackground),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

/// 带下拉菜单的工具胶囊（排序 / 尺寸等）
struct ToolMenuChip<Content: View>: View {
    let label: String
    var icon: String? = nil
    private let menuContent: Content

    init(label: String, icon: String? = nil, @ViewBuilder menuContent: () -> Content) {
        self.label = label
        self.icon = icon
        self.menuContent = menuContent()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
    }
}

// MARK: - 卡片尺寸记忆 + 布局控制器
// 对齐网页版：电影/相册列表的「视图方向」和「卡片大小」按媒体库分别记忆到
// localStorage（web）→ UserDefaults（iOS）。竖版、横版各记一份，切换方向互不干扰。
// 卡片大小支持双指捏合缩放（对齐网页版 usePinchToResize）。

/// UserDefaults 读写辅助（key 按媒体库隔离，nil = 跨库「全部」）
enum CardSizePrefs {
    static func key(_ base: String, libID: Int?) -> String {
        base + "." + (libID.map { String($0) } ?? "all")
    }

    static func load(_ base: String, libID: Int?, fallback: CGFloat) -> CGFloat {
        let v = UserDefaults.standard.double(forKey: key(base, libID: libID))
        return v > 0 ? v : fallback
    }

    static func save(_ base: String, libID: Int?, _ v: CGFloat) {
        UserDefaults.standard.set(Double(v), forKey: key(base, libID: libID))
    }

    static func loadBool(_ base: String, libID: Int?, fallback: Bool) -> Bool {
        let k = key(base, libID: libID)
        guard UserDefaults.standard.object(forKey: k) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: k)
    }

    static func saveBool(_ base: String, libID: Int?, _ v: Bool) {
        UserDefaults.standard.set(v, forKey: key(base, libID: libID))
    }
}

/// 卡片布局控制器：方向（竖/横）+ 分方向卡片尺寸 + 记忆 + 捏合缩放
/// 电影、相册列表页各持有一个实例，逻辑完全一致。
final class CardLayoutController: ObservableObject {
    /// 卡片宽度低于该值时进入「小卡片」模式（只显示封面、标题叠进封面底部渐变）。
    /// ⚠️ 所有方向的 range 下限都必须低于此值，否则缩到最小也进不了小卡片。
    static let compactThreshold: CGFloat = 150

    /// UserDefaults key 前缀（如 "mediaList" / "albumList"）
    private let baseKey: String
    /// 记忆粒度：固定库模式用库 id，跨库模式 nil（退化成「全部」一份）
    private let libID: Int?
    private let portraitRange: ClosedRange<CGFloat>
    private let landscapeRange: ClosedRange<CGFloat>

    /// 当前方向：false = 竖版，true = 横版封面
    @Published var landscape: Bool
    @Published var cardWidthPortrait: CGFloat
    @Published var cardWidthLandscape: CGFloat

    /// 当前方向生效的卡片宽度
    var cardWidth: CGFloat { landscape ? cardWidthLandscape : cardWidthPortrait }
    /// 当前方向生效的尺寸范围（捏合 / 滑块共用）
    var range: ClosedRange<CGFloat> { landscape ? landscapeRange : portraitRange }

    init(baseKey: String, libID: Int?,
         portraitDefault: CGFloat, landscapeDefault: CGFloat,
         portraitRange: ClosedRange<CGFloat>, landscapeRange: ClosedRange<CGFloat>) {
        self.baseKey = baseKey
        self.libID = libID
        self.portraitRange = portraitRange
        self.landscapeRange = landscapeRange
        self.landscape = CardSizePrefs.loadBool(baseKey + ".landscape", libID: libID, fallback: false)
        self.cardWidthPortrait = CardSizePrefs.load(baseKey + ".cardWidthPortrait", libID: libID, fallback: portraitDefault)
        self.cardWidthLandscape = CardSizePrefs.load(baseKey + ".cardWidthLandscape", libID: libID, fallback: landscapeDefault)
    }

    func toggleOrientation() {
        landscape.toggle()
        CardSizePrefs.saveBool(baseKey + ".landscape", libID: libID, landscape)
    }

    /// 捏合 / 滑块拖动过程中只更新内存值（不落盘），避免高频写 UserDefaults 卡顿。
    func resize(to width: CGFloat) {
        let clamped = min(max(width, range.lowerBound), range.upperBound)
        if landscape { cardWidthLandscape = clamped } else { cardWidthPortrait = clamped }
    }

    /// 手势松手 / 滑块松手时落盘一次。
    func commit() {
        CardSizePrefs.save(baseKey + ".cardWidthPortrait", libID: libID, cardWidthPortrait)
        CardSizePrefs.save(baseKey + ".cardWidthLandscape", libID: libID, cardWidthLandscape)
    }
}

/// 尺寸滑块：图标 + 滑块 + 数值，对齐网页版顶部 range input
struct ToolSlider: View {
    let icon: String
    @ObservedObject var layout: CardLayoutController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { layout.cardWidth },
                    set: { layout.resize(to: $0) }
                ),
                in: layout.range,
                onEditingChanged: { editing in
                    // 拖动中只改内存，松手才落盘
                    if !editing { layout.commit() }
                }
            )
            .frame(width: 88)
            Text("\(Int(layout.cardWidth))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - 右滑返回
// 列表页为了「搜索框贴顶」隐藏了导航栏，系统右滑返回手势会随之失效。
// 这里用自定义手势补齐：向右滑时页面**跟手**移动，松手按「位移 + 甩动速度」
// 判定是完成返回还是弹回原位 —— 比原来「松手才瞬间跳走」接近系统的手感。
//
// ⚠️ 为什么没能和详情页完全一致：详情页走的是系统 interactivePop，返回时左边缘
// 露出的是**上一层页面**并带视差；这里我们只是把当前页整体位移，露出的多半是
// 页面背景。要完全对齐只能恢复系统的 interactivePopGestureRecognizer（UIKit 桥接），
// 但那依赖 NavigationStack 的内部行为、隐藏导航栏后能否稳定启用没把握，
// 所以先用这套纯 SwiftUI 的跟手版，不引入不可控的 hack。
struct EdgePopGestureModifier: ViewModifier {
    var enabled: Bool = true
    @Environment(\.dismiss) private var dismiss

    /// 跟手位移。判定返回时**故意不清零** —— 留给系统的 pop 转场接手，
    /// 动画就能从手指松开的位置继续往右滑出去，中间不打断；自己再补一段动画
    /// 反而会看到「滑出去、又滑一次」的重影。
    @State private var offsetX: CGFloat = 0
    /// 本次手势是否真的进入了跟手状态（垂直滚动不该触发）
    @State private var tracking = false

    /// 完成返回的位移阈值（沿用原值，行为不变）
    private let commitDistance: CGFloat = 110
    /// 甩一下就返回：末速度预测位移超过这个值也算 —— 快速轻扫时手指位移未必够 110
    private let commitVelocity: CGFloat = 320

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard enabled else { return }
                        let dx = value.translation.width
                        // 只认「向右且水平为主」：垂直滚列表、向左滑都不跟手
                        guard dx > 0, dx > abs(value.translation.height) else { return }
                        tracking = true
                        offsetX = dx
                    }
                    .onEnded { value in
                        guard enabled, tracking else { return }
                        tracking = false
                        let dx = value.translation.width
                        guard dx > 0, dx > abs(value.translation.height) else {
                            springBack()
                            return
                        }
                        if dx > commitDistance || value.predictedEndTranslation.width > commitVelocity {
                            dismiss()
                        } else {
                            springBack()
                        }
                    }
            )
    }

    private func springBack() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { offsetX = 0 }
    }
}

extension View {
    /// 向右滑返回（配合隐藏导航栏的列表页使用）
    func edgePopGesture(enabled: Bool = true) -> some View {
        modifier(EdgePopGestureModifier(enabled: enabled))
    }
}
