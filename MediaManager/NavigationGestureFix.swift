import UIKit

// MARK: - 恢复 NavigationStack 隐藏导航栏后的 pop 返回手势
// SwiftUI NavigationStack 用 .toolbar(.hidden) 隐藏导航栏后，底层 UINavigationController 的
// interactivePopGestureRecognizer 会因导航栏隐藏而不再响应 —— 边缘右滑返回失效。
// 通过 swizzle viewDidLoad，把手势 delegate 换成始终允许、并强制启用，恢复右滑返回。
extension UINavigationController {
    /// App 启动时调用一次；之后所有 NavigationStack 隐藏导航栏后仍可右滑返回。
    static func enablePopGesture() {
        _ = swizzleOnce
    }

    private static let swizzleOnce: Void = {
        guard let original = class_getInstanceMethod(UINavigationController.self, #selector(viewDidLoad)),
              let swizzled = class_getInstanceMethod(UINavigationController.self, #selector(swizzled_viewDidLoad)) else { return }
        method_exchangeImplementations(original, swizzled)
    }()

    @objc private func swizzled_viewDidLoad() {
        swizzled_viewDidLoad()
        interactivePopGestureRecognizer?.delegate = PopGestureDelegate.shared
        interactivePopGestureRecognizer?.isEnabled = true
    }
}

private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = PopGestureDelegate()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 始终允许 begin；root 页拖动手势会跟手但松手弹回（系统默认行为）
        true
    }
}
