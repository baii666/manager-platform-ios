import SwiftUI

// MARK: - 远程图片（带渐变占位降级）
// 有 URL 走 AsyncImage；没有 URL 或加载失败时，退回到「渐变 + 图标」占位，
// 保证离线 / 封面缺失时界面依然美观。
struct RemoteImage: View {
    let url: URL?
    var fallbackIcon: String
    var fallbackColors: [Color]

    init(url: URL?, fallbackIcon: String = "photo", fallbackColors: [Color] = [Color.gray.opacity(0.35), Color.gray.opacity(0.12)]) {
        self.url = url
        self.fallbackIcon = fallbackIcon
        self.fallbackColors = fallbackColors
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
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
}
