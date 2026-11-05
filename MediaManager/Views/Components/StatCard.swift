import SwiftUI
import UIKit

// MARK: - 统计卡
struct StatCard: View {
    let icon: String
    let label: String
    let value: Int
    let tint: Color
    var action: (() -> Void)? = nil

    var body: some View {
        // 没接动作的卡片不要做成 Button，否则点了有按压动画却没反应，像是坏了
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(valueText)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    // 完整数字可能 7~9 位（照片库几百万），按卡宽自动缩字号，
                    // 保持单行且不被截断。不能再用 fixedSize(horizontal: true)：
                    // 那会强制理想宽度，把 label 挤出卡片、minimumScaleFactor 也失效。
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .appSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 一律显示完整原数字（带千分位分组），不再缩写为「万 / 亿」。
    /// 3,126,174 / 13,707 / 2315 都用同一种写法，与原先小数值的样式一致。
    private var valueText: String {
        value.formatted()
    }
}
