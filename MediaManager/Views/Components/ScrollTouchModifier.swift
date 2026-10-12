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
//
// ⚠️⚠️ 历史教训（2026-10-12）：这个 fix 曾经长期**静默失效** ——
// `.background()` 注入的探针视图与目标 ScrollView 是**兄弟节点**（同父级），
// 旧实现只往上走 superview 链找「祖先 UIScrollView」，永远找不到目标，
// 探针返回 nil 什么都不做，症状原样存在。
// 正确做法：从探针逐级上溯，在每一级祖先的子树里做 BFS 取**最浅**的 UIScrollView ——
// 第一次找到的就是目标 ScrollView（与该级平级），不会误取内容里的横向滚动条（更深）。

struct DelaysContentTouchesFix: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 延迟到下一个 runloop，确保 ScrollView 已经挂进视图树
        DispatchQueue.main.async {
            uiView.disableEnclosingScrollViewDelays()
        }
    }
}

private extension UIView {
    /// 关闭「包住本视图的那个 SwiftUI ScrollView」的内容触摸延迟。
    /// 逐级上溯：在每一级祖先（含自身）的子树里 BFS 找最浅的 UIScrollView，
    /// 第一个找到的就是目标（探针是 background 注入的，与它是兄弟）。
    func disableEnclosingScrollViewDelays() {
        var current: UIView? = self
        var depth = 0
        while let view = current, depth < 8 {
            if let scroll = view.shallowestScrollView() {
                scroll.delaysContentTouches = false
                return
            }
            current = view.superview
            depth += 1
        }
    }

    /// BFS 本子树（含自身），返回最浅的 UIScrollView。
    /// 广度优先保证：目标 ScrollView（浅）先于内容里的横向滚动条（深）被找到。
    private func shallowestScrollView() -> UIScrollView? {
        var queue: [UIView] = [self]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView { return scroll }
            queue.append(contentsOf: view.subviews)
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
