import SwiftUI

// MARK: - 恢复系统右滑返回（UIKit 桥接）⚠️ 当前停用，保留备用
//
// 列表页曾经为了「搜索框贴顶」执行 .toolbar(.hidden, for: .navigationBar)，
// 导航栏一隐藏，UINavigationController 自带的 interactivePopGestureRecognizer
// 就被系统自己的 delegate 拦下了（它在 shouldBegin 里判断 navigationBar.isHidden）。
// 这个桥接换掉那个 delegate，试图把系统手势请回来。
//
// ❗ 真机结论：**没用**。手势确实恢复了一半（能触发 pop），但右滑过程中仍然是白屏 ——
// 因为白屏的根因不是手势，而是 SwiftUI NavigationStack 在 push 之后不再渲染
// 被盖住的那一层，下面根本没内容可显示。
//
// 最终解法是列表页恢复系统导航栏（搜索框挪进 principal 位，视觉上不额外占高度），
// 手势和转场都由 UINavigationController 接管。
//
// ⚠️ 保留备用：将来若有页面必须隐藏导航栏，可以再挂回来，但要接受
// 「滑动过程中是空白」这个 SwiftUI 的硬限制。

/// 顶替系统 delegate：栈里不止一层就放行。
///
/// ⚠️ 不能直接 `delegate = nil`：那样在栈底（root）右滑会触发一次找不到对应页面的
/// pop 转场，界面卡死不动 —— UINavigationController 的经典坑。这里显式判 count > 1。
///
/// ⚠️ 这里不能标 private：下面 SystemPopGestureEnabler 是 internal，它的三个协议方法
/// 的签名里要用到这个类型，private 会让编译器要求那三个方法也降级成 fileprivate。
final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 1) > 1
    }
}

/// 探测用的透明 VC：挂进 SwiftUI 层级，只为拿到它所在的 UINavigationController。
/// ⚠️ 同 PopGestureDelegate，不能标 private（会被 SystemPopGestureEnabler 的方法签名用到）。
final class PopGestureProbeVC: UIViewController {
    /// 桥接结果回传（成功 = 系统手势已接管）
    var onResolved: ((Bool) -> Void)?

    private let popDelegate = PopGestureDelegate()
    private weak var owningNC: UINavigationController?
    private weak var previousDelegate: UIGestureRecognizerDelegate?
    private var captured = false
    /// 桥接结果只回传一次：updateUIViewController 每次 body 重算都会跑，
    /// 反复写同一个 true 会让 SwiftUI 反复重算 → 死循环。重装 delegate 仍然每次都做。
    private var reported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 纯探针：不参与交互，也不遮住下面的内容
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        install()
    }

    /// 幂等：每次调用都确保 delegate 是我们的。
    /// SwiftUI 的更新周期可能把系统 delegate 装回去，所以不能只装一次。
    func install() {
        guard let nc = navigationController ?? owningNC,
              let gr = nc.interactivePopGestureRecognizer else { return }

        if !captured {
            owningNC = nc
            previousDelegate = gr.delegate
            captured = true
        }
        // 不做「delegate 是不是已经是我们」的判断：协议类型和具体类之间用 === 比较
        // 在类型推断上有变数，而这里重复赋值的代价可以忽略（就是一次属性写入）
        gr.isEnabled = true
        gr.delegate = popDelegate
        popDelegate.navigationController = nc
        guard !reported else { return }
        reported = true
        onResolved?(true)
    }

    /// 本页退出时把 delegate 交还系统，别影响其他页面。
    /// ⚠️ 此时 navigationController 往往已经是 nil，所以用探测时保存的弱引用。
    func restore() {
        if let nc = owningNC, let gr = nc.interactivePopGestureRecognizer {
            gr.delegate = previousDelegate
        }
        owningNC = nil
        captured = false
        reported = false
    }
}

/// SwiftUI 侧包装：把「系统手势是否已接管」回传给调用方。
struct SystemPopGestureEnabler: UIViewControllerRepresentable {
    @Binding var isActive: Bool

    func makeUIViewController(context: Context) -> PopGestureProbeVC {
        let vc = PopGestureProbeVC()
        let binding = $isActive
        vc.onResolved = { ok in
            // 回调来自 UIKit 的生命周期，切回 MainActor 再改 SwiftUI 状态
            Task { @MainActor in binding.wrappedValue = ok }
        }
        return vc
    }

    /// 每次刷新都重装一次：SwiftUI 可能在更新周期里把系统 delegate 装回去
    func updateUIViewController(_ vc: PopGestureProbeVC, context: Context) {
        vc.install()
    }

    static func dismantleUIViewController(_ vc: PopGestureProbeVC, coordinator: ()) {
        vc.restore()
    }
}
