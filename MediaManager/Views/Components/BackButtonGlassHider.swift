import SwiftUI

// MARK: - 去掉返回按钮的玻璃底（iPadOS 26）
//
// 系统返回按钮不是我们自己的 ToolbarItem，.sharedBackgroundVisibility 管不到它 ——
// 那层半透明圆弧底是 UINavigationBar 自己画在返回按钮上的。iOS 26 的 UIKit 给了
// 对应的开关 hidesSharedBackground，设在「上一层」导航项的 backBarButtonItem 上，
// 也就是当前这个返回按钮真正使用的那个 item。
//
// ⚠️ 这里只改外观，绝不能碰 .navigationBarBackButtonHidden —— 真机验证过：
// 藏掉系统返回按钮，右滑返回手势会一起失效，而且没有任何可靠手段能把手势取回来
// （自定义位移手势会因为 NavigationStack 不渲染下一层而推出白屏）。
// 保持按钮存在，手势就仍由 UINavigationController 接管。
//
// ⚠️ 同样是 iOS 26 SDK 才有的属性，用 compiler(>=6.2) 做编译期开关，
// 老工具链（Xcode 16）下这段代码整体被跳过，不影响编译。
struct BackButtonGlassHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BackButtonGlassProbeVC {
        let vc = BackButtonGlassProbeVC()
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: BackButtonGlassProbeVC, context: Context) {
        vc.hideBackButtonGlass()
    }
}

/// ⚠️ 不能标 private：它出现在上面三个协议方法的签名里，而那个 struct 是
/// internal（要跨文件用），Swift 会要求协议方法跟着降级成 fileprivate 而报错。
final class BackButtonGlassProbeVC: UIViewController {

    func hideBackButtonGlass() {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *) else { return }
        guard let bar = navigationController?.navigationBar,
              let backItem = bar.backItem else { return }

        // 上一层没设过 backBarButtonItem（SwiftUI 一般是合成的）就自己造一个，
        // 标题沿用 backItem.title —— 标题为空就不动，免得把按钮文字弄没了。
        let title = backItem.backBarButtonItem?.title ?? backItem.title
        guard let title, !title.isEmpty else { return }

        let item = backItem.backBarButtonItem
            ?? UIBarButtonItem(title: title, style: .plain, target: nil, action: nil)
        item.title = title
        item.hidesSharedBackground = true
        backItem.backBarButtonItem = item
        #endif
    }
}
