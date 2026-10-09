import SwiftUI
import UIKit

// MARK: - 缓存图片（SwiftUI 组件）
// 走 ImageCache，命中内存/磁盘直接出图；未命中则下载缓存。
// 相比 AsyncImage：避免重复请求、内存有上限、支持磁盘二次加载。
struct CachedAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var fallbackIcon: String = "photo"
    var fallbackColors: [Color] = [Color.gray.opacity(0.35), Color.gray.opacity(0.12)]

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: fallbackColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: fallbackIcon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    @MainActor
    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = await ImageCache.shared.load(from: url)
    }
}
