import SwiftUI

// MARK: - 继续观看卡（16:9 横版 + 进度条）
struct ResumeCard: View {
    let asset: UnifiedAsset
    var onPlay: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.easeOut(duration: 0.2), value: hovering)
        }
        .onHover { hovering = $0 }
        .onTapGesture { onPlay() }
    }

    private var cover: some View {
        RemoteImage(
            url: asset.backdropURL ?? asset.coverURL,
            fallbackIcon: asset.type.systemImage,
            fallbackColors: Theme.placeholderGradient(for: asset.type)
        )
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Image(systemName: asset.type.systemImage).font(.caption2)
                Text(asset.type.label)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(7)
        }
        .overlay(alignment: .topTrailing) {
            if asset.progress > 0 {
                Text("\(Int(asset.progress * 100))%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(7)
            }
        }
        .overlay {
            if hovering {
                ZStack {
                    Color.black.opacity(0.25)
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(asset.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if asset.progress > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.25))
                                    Capsule().fill(Theme.brand)
                                        .frame(width: geo.size.width * asset.progress)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(10)
                }
        }
    }
}
