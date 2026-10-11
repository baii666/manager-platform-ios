import SwiftUI

// MARK: - 列表页顶部状态栏组件
// 之前「搜索 / 排序 / 库筛选」都塞在 navigationBar 的 toolbar 里（Menu 下拉），
// 视觉上很简陋。这里抽成独立、美观的顶部栏：搜索框 + 胶囊工具按钮，
// 样式对齐网页版 PageToolbar 的简洁风格。

/// 美观搜索框：圆角 + 放大镜 + 清除按钮
struct ListSearchBar: View {
    @Binding var text: String
    var placeholder: String = "搜索…"
    /// 放进导航栏时用：纵向 padding 收紧，避免撑高 navigationBar（inline 只有 44pt）
    var compact: Bool = false

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
        .padding(.vertical, compact ? 6 : 9)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - 去掉 iPadOS 26 给 toolbar 项目套的共享玻璃底
// iOS 26 起导航栏 / 工具栏项目会被系统自动套一层共享的 Liquid Glass 圆弧底；
// 我们的控件自带样式（或本来就是纯文字/图标），再套一层就变成两层背景，
// 看着就是一个「半透明圆弧」。官方开关是 .sharedBackgroundVisibility(.hidden)，
// ⚠️ 必须加在 ToolbarItem 上，加在里面那个视图上是无效的。
//
// ⚠️ 该 API 要 iOS 26 SDK（Xcode 26）。CI 的 macos-15 镜像默认 Xcode 16.4 编不过，
// 所以用 compiler(>=6.2) 做**编译期**开关：老工具链原样返回（iOS 26 以下本来
// 也没有玻璃底），两边都能编。
extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutGlass() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - 导航栏里的搜索框（三个列表页共用，保证宽度和位置一致）
//
// 用 .topBarLeading 而不是 .principal：principal 是居中的，左边留一大块空，
// 而且宽度会被两侧的按钮挤来挤去，三个页面各不一样。
// 放 leading 就紧跟在系统返回按钮右边，宽度写死 —— 切页面时搜索框不跳位。
//
// ⚠️ 封装成 ToolbarContent 而不是在各页各写一遍 ToolbarItem：
// 宽度是常量，改一处三个页面同时生效，不会再出现「这个页面的搜索框短一点」。
struct ListSearchBarItem: ToolbarContent {
    @Binding var text: String
    var placeholder: String = "搜索…"
    /// 搜索框**后面**显示的媒体库名（nil = 不显示这一项）
    var title: String? = nil
    /// 窄屏（iPhone）：一行要塞下「返回 + 搜索 + 库名 + 排序 + 横竖版」，搜索框缩短给库名让位
    var narrow: Bool = false

    /// 固定宽度（宽屏）。想要更长/更短只改这一个数字。
    static let width: CGFloat = 280
    /// 窄屏下的搜索框宽度（见 narrow）
    static let narrowWidth: CGFloat = 170

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 10) {
                ListSearchBar(text: $text, placeholder: placeholder, compact: true)
                    // ⚠️ 就是死宽：搜索框长度恒定，不随可用空间伸缩
                    //（试过 min/ideal/max 让它可回缩，结果它一缩用户就看出来了 ——
                    //  后面明明还有一大片空位，没必要让搜索框让路）
                    .frame(width: narrow ? Self.narrowWidth : Self.width)
                if let title {
                    // 库名紧跟搜索框。够宽就整段显示（拉长），不够才尾部省略。
                    // 颜色跟计数（"34 / 120"）一致，整条状态栏一个色调。
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // ⚠️ 这两行是库名「不消失 / 不被截太短」的保险：
                        // minWidth 120 ≈ 8 个汉字 —— iPad 上随便都够 5 个字以上，
                        // 空间再紧也不会被压没；layoutPriority 高于搜索框（默认 0），
                        // 分配空间时先满足库名，剩下的才轮到前面的搜索框。
                        // ⚠️ alignment 必须写 .leading：frame 默认居中，名字短的时候
                        // 会在那 120pt 里居中摆放，看着离搜索框老远。
                        .frame(minWidth: 120, alignment: .leading)
                        .layoutPriority(1)
                }
            }
        }
        .withoutGlass()
    }
}

/// 纯文字/图标工具按钮（不带任何背景）。高亮态改用文字颜色 + 字重表达，
/// ⚠️ 不再自己画胶囊底：放进导航栏后系统还会再套一层玻璃底，两层叠一起很难看。
///
/// ⚠️ 颜色一律用 .secondary（和右侧计数 "34 / 120" 同一个灰）：
/// 之前高亮态跳成品牌色，整条状态栏花花绿绿。现在高亮只靠字重/图标区分。
struct ToolChip: View {
    let label: String
    var icon: String? = nil
    var highlighted: Bool = false
    /// 只显示图标、不显示文字（横竖版切换这类图标本身够直观的按钮）
    var iconOnly: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: iconOnly ? 14 : 12, weight: .semibold))
                }
                if !iconOnly {
                    Text(label)
                        .font(.caption.weight(highlighted ? .semibold : .medium))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 只剩图标时文字没了，读屏和长按提示得补上
        .accessibilityLabel(label)
    }
}

/// 带下拉菜单的工具按钮（排序 / 库筛选），同样不画胶囊底。
/// ⚠️ 前面不再放图标：排序那个「上下箭头」是多余装饰，留文字 + 右侧 chevron 就够了。
struct ToolMenuChip<Content: View>: View {
    let label: String
    private let menuContent: Content

    init(label: String, @ViewBuilder menuContent: () -> Content) {
        self.label = label
        self.menuContent = menuContent()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        // ⚠️ 光在 label 里写 .foregroundStyle 没用：Menu 是「控件」，页面上的
        // .tint(Theme.brand) 会把它的标题和展开后的菜单一起染成品牌色。
        // 必须显式给控件本身换 tint（次级灰 = 与计数同一个颜色）才压得住。
        .tint(Color.secondary)
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
    ///
    /// 150 太低了：竖版缩到 150 宽（封面才 225 高）时下方标题区还在，
    /// 15pt 的标题相对卡片就显大。提到 190 —— 再小的卡片一律走内嵌标题。
    ///
    /// ⚠️ 所有方向的 range 下限都必须低于此值，否则缩到最小也进不了小卡片。
    /// ⚠️ 已存进 UserDefaults 的卡片宽度不受影响：用户原来存了 150，
    /// 提高阈值后他会直接看到小卡片模式 —— 这正是「缩很小就该隐藏」的预期。
    static let compactThreshold: CGFloat = 190

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

// MARK: - 右滑返回（⚠️ 当前停用，保留备用）
//
// 列表页以前为了「搜索框贴顶」隐藏导航栏，系统右滑返回随之失效，只能自己兜底。
// 但 SwiftUI 的 NavigationStack 在 push 之后**不再渲染栈里被盖住的那一层** ——
// 自定义手势把当前页推开，下面没有东西可显示，露出容器背景（右滑到一半是白屏），
// 松手后 pop 动画跑完上一层才出现。真机验证过：连 UIKit 桥接启用系统的
// interactivePopGestureRecognizer 也救不回来，白屏依旧。
//
// 所以列表页已恢复系统导航栏（搜索框挪进 principal 位，不额外占高度），
// 手势和转场全部由 UINavigationController 接管，与电影详情页完全一致。
//
// ⚠️ 这段代码保留备用：将来若有页面必须隐藏导航栏，挂 .edgePopGesture() 即可，
// 但要接受「滑动过程中是空白」这个 SwiftUI 的硬限制。
struct EdgePopGestureModifier: ViewModifier {
    var enabled: Bool = true
    @Environment(\.dismiss) private var dismiss

    /// 系统手势是否已经接管。接管后自定义手势必须让位 ——
    /// 两套手势同时响应会看到「页面跟着手指走一遍，系统又滑一遍」的重影。
    @State private var systemPopActive = false

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
    /// 系统边缘手势的起手区宽度
    private let systemEdgeZone: CGFloat = 40

    /// 这次拖动该不该由兜底手势处理。
    /// 系统手势接管后，左边缘这一带让给它 —— 否则两套手势会同时响应，
    /// 看到页面跟着手指走一遍、系统再滑一遍的重影。
    private func shouldHandle(_ value: DragGesture.Value) -> Bool {
        // 桥接没成功（拿不到 UINavigationController）→ 任意位置都得兜底，行为不变
        guard systemPopActive else { return true }
        return value.startLocation.x > systemEdgeZone
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX)
            // 0 尺寸探针：只为拿到本页所在的 UINavigationController。
            // 不占布局、不拦事件（VC 内部也关了 userInteractionEnabled）。
            .background(alignment: .topLeading) {
                if enabled {
                    SystemPopGestureEnabler(isActive: $systemPopActive)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard enabled, shouldHandle(value) else { return }
                        let dx = value.translation.width
                        // 只认「向右且水平为主」：垂直滚列表、向左滑都不跟手
                        guard dx > 0, dx > abs(value.translation.height) else { return }
                        tracking = true
                        offsetX = dx
                    }
                    .onEnded { value in
                        guard enabled, tracking, shouldHandle(value) else { return }
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
