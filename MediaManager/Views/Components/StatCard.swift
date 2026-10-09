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
                    // 照片库动辄几百万，全量展开会把卡片撑成两行
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: true, vertical: false)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    /// 3,126,174 → "312.6万"，13,707 → "1.4万"，2315 保持原样
    private var valueText: String {
        if value >= 100_000_000 {
            return String(format: "%.2f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            let w = Double(value) / 10_000
            return w >= 100 ? String(format: "%.0f万", w) : String(format: "%.1f万", w)
        }
        return value.formatted()
    }
}
