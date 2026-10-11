import SwiftUI
import UIKit

// MARK: - 关闭 ScrollView 内容触摸延迟
//
// ⚠️ 根因：SwiftUI 的 ScrollView 底层是 UIScrollView，默认 `delaysContentTouches = true`，
// 系统要等「手势判定」完成（区分是点控件还是开始滚动）才把触摸交给子控件。
// 结果就是点搜索框这类可编辑控件时，键盘要等约 0.2~1s 才弹 —— iPad 上尤其明显。
//
// 修法：把 ScrollView 内层的 UIScrollView 的 `delaysContentTouches` 关掉。
// 注意：只关 delays，不动 `canCancelContentTouches`（保留滚动手势对内容的取消），
// 这样既让按钮/输入框点击即时响应，又不影响正常滚动。

struct DelaysContentTouchesFix: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 延迟到下一个 runloop，确保 ScrollView 已经挂进视图树
        DispatchQueue.main.async {
            guard let scrollView = uiView.enclosingScrollView else { return }
            scrollView.delaysContentTouches = false
        }
    }
}

private extension UIView {
    /// 向上找到最近的 UIScrollView（SwiftUI ScrollView 的实现载体）
    var enclosingScrollView: UIScrollView? {
        var view: UIView? = self
        while let v = view {
            if let scroll = v as? UIScrollView { return scroll }
            view = v.superview
        }
        return nil
    }
}

extension View {
    /// 让 ScrollView 里的按钮/输入框点击即时响应（关闭内容触摸延迟）。
    /// 用法：`ScrollView { ... }.fixDelaysContentTouches()`
    func fixDelaysContentTouches() -> some View {
        background(DelaysContentTouchesFix())
    }
}
