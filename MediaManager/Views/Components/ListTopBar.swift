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
