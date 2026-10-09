import SwiftUI

// MARK: - 竖版海报卡（收藏 / 最近入库通用）
// 顶部类型标签 + 底部渐变标题，hover 时轻微上浮。
struct AssetPosterCard: View {
    let asset: UnifiedAsset
    var aspectRatio: CGFloat = 3.0 / 4.0
    var onTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .onTapGesture(perform: onTap)
    }

    private var cover: some View {
        RemoteImage(
            url: asset.coverURL,
            fallbackIcon: asset.type.systemImage,
            fallbackColors: Theme.placeholderGradient(for: asset.type)
        )
        .overlay(alignment: .topLeading) {
            Text(asset.type.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(7)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let subtitle = asset.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                }
        }
    }
}

// MARK: - 最近入库卡（RecentItem 专用）
struct RecentPosterCard: View {
    let item: RecentItem
    var aspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var cover: some View {
        RemoteImage(url: item.coverURL, fallbackIcon: item.kind.systemImage)
            .overlay(alignment: .topLeading) {
                Text(item.kind.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(7)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .padding(10)
                    }
            }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let name = item.libraryName { parts.append(name) }
        if item.kind == .album, let count = item.photoCount { parts.append("\(count) 张") }
        return parts.joined(separator: " · ")
    }
}
