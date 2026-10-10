import UIKit

// MARK: - 图片缓存（内存 + 磁盘）
//
// 之前 RemoteImage 直接用 AsyncImage，只靠 URLSession 的 HTTP 缓存兜底。
// 但系统默认 URLCache 磁盘容量极小，几十张封面就把缓存挤爆，于是每次进
// 「首页 / 电影 / 相册 / 拍摄集」都要把封面重新下一遍 —— 这是加载慢的主因。
//
// 这里自己管两层：
//   1. NSCache 内存缓存：同一会话内滚动列表，封面秒出、不重复解码。
//   2. 磁盘缓存：跨会话（冷启动）也命中，存的是服务端返回的原始字节（webp，无损）。
//
// ⚠️ 只缓存「图片」类资源（封面 / 缩略图），不碰 API 的 JSON，避免脏数据。
final class ImageCache {
    static let shared = ImageCache()

    private let mem = NSCache<NSURL, UIImage>()
    private let diskDir: URL
    private let io = DispatchQueue(label: "imgcache.io", qos: .utility)

    private init() {
        mem.countLimit = 1000
        mem.totalCostLimit = 256 * 1024 * 1024  // 256 MB 内存
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = base.appendingPathComponent("imgcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// 取图：内存 → 磁盘 → 网络（下载后回写两层缓存）。失败返回 nil。
    func image(for url: URL) async -> UIImage? {
        let key = cacheKey(url)

        if let img = mem.object(forKey: url as NSURL) {
            return img
        }
        if let img = loadDisk(key) {
            mem.setObject(img, forKey: url as NSURL)
            return img
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // 先落盘原始字节（webp 无损），再解码显示
            io.async { try? data.write(to: self.diskDir.appendingPathComponent(key), options: .atomic) }
            guard let img = UIImage(data: data) else { return nil }
            mem.setObject(img, forKey: url as NSURL)
            return img
        } catch {
            return nil
        }
    }

    private func loadDisk(_ key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: diskDir.appendingPathComponent(key)) else { return nil }
        return UIImage(data: data)
    }

    private func cacheKey(_ url: URL) -> String {
        // URL 含中文/特殊字符，直接哈希成短文件名，规避文件系统限制
        var h = Hasher()
        h.combine(url.absoluteString)
        return String(h.finalize(), radix: 16)
    }
}
