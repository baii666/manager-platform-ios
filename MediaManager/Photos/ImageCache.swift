import UIKit
import CryptoKit

// MARK: - 图片缓存（内存 NSCache + 磁盘）
// 应对百万级照片的关键：内存命中极快、磁盘兜底、自动 LRU 淘汰。
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let fileManager = FileManager.default
    private let diskDir: URL

    init() {
        memory.countLimit = 500
        memory.totalCostLimit = 256 * 1024 * 1024 // 256 MB 内存上限
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// 同步查内存 + 磁盘缓存
    func image(for url: URL) -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        let file = diskDir.appendingPathComponent(key(for: url))
        guard let data = try? Data(contentsOf: file),
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: url as NSURL)
        return img
    }

    func store(_ image: UIImage, for url: URL) {
        memory.setObject(image, forKey: url as NSURL)
        let file = diskDir.appendingPathComponent(key(for: url))
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// 下载 + 缓存 + 返回；命中缓存则直接返回
    func load(from url: URL) async -> UIImage? {
        if let img = image(for: url) { return img }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { return nil }
            store(img, for: url)
            return img
        } catch {
            return nil
        }
    }

    /// 用 SHA256 生成稳定、无非法字符的磁盘文件名
    private func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }
}
