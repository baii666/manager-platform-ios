import SwiftUI
import UIKit

// MARK: - 全局导航栏返回按钮样式
//
// ❗ 返回按钮不能用自定义按钮替换。真机验证过三次：
//   · .navigationBarBackButtonHidden(true) → interactivePop 被一起禁掉，右滑返回没了
//   · 自定义位移手势（跟手版）→ NavigationStack push 后不渲染下一层，滑出来是白屏
//   · UIKit 桥接换 delegate → 转场仍然接管不了，白屏依旧
// 结论：系统返回按钮和右滑手势是绑定的，必须留着，只能改它的外观。
//
// 系统按钮在 UIKit 里确实能动的点就两个：
//   1) 文字：setBackButtonTitlePositionAdjustment 把标题推出屏幕 → 只剩一个箭头
//   2) 颜色：跟随 UINavigationBar 的 tintColor
//
// ⚠️ iPadOS 26 那层 Liquid Glass 圆弧底是系统画在按钮上的，
//    hidesSharedBackground 只对**自己创建**的 UIBarButtonItem 有效，
//    对 SwiftUI 合成的系统返回按钮无效（Apple 开发者论坛已证实）。
//    要去掉只能走 Info.plist 的 UIDesignRequiresCompatibility = true，
//    代价是整个 App 退回 iOS 18 外观（不再有 Liquid Glass），本项目暂未启用。
enum NavigationBarStyle {

    // ↓↓↓ 返回按钮样式的全部可调项 ↓↓↓

    /// true = 只显示箭头，去掉「返回」/ 上一层标题那串文字（默认开，最紧凑）
    ///
    /// ⚠️ 这是全局的：详情页的返回按钮也只剩箭头。
    /// 想要回文字就把它改成 false（删除那次 setBackButtonTitlePositionAdjustment 调用）。
    static let hideBackButtonTitle = true

    /// 返回按钮（以及导航栏其它按钮）的颜色。nil = 用系统默认蓝。
    static let tint: Color? = Theme.brand

    static func configure() {
        if hideBackButtonTitle {
            // 把标题推出屏幕，而不是置空 —— 置空标题会让系统判定「这一层没有标题」
            // 从而改变箭头位置与按钮内边距；推出屏幕只是看不见，布局最稳。
            // ⚠️ UI_APPEARANCE_SELECTOR：必须通过 appearance 代理调用才全局生效，
            //    对单个 UIBarButtonItem 实例调用无效。
            UIBarButtonItem.appearance()
                .setBackButtonTitlePositionAdjustment(
                    UIOffset(horizontal: -1000, vertical: 0),
                    for: .default
                )
        }

        if let tint {
            UINavigationBar.appearance().tintColor = UIColor(tint)
        }
    }
}
