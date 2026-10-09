import SwiftUI

// MARK: - 区块标题
struct SectionHeader: View {
    let icon: String
    let title: String
    var moreLabel: String? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text(title)
                .font(.title3.weight(.semibold))

            Spacer()

            if let moreLabel {
                Button {
                    onMore?()
                } label: {
                    HStack(spacing: 3) {
                        Text(moreLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }
}
