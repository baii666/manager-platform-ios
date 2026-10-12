import UIKit
import CryptoKit

// MARK: - 图片缓存（内存 NSCache + 磁盘）
// 应对百万级照片的关键：内存命中极快、磁盘兜底、自动 LRU 淘汰。
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
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
        let key = url.absoluteString as NSString
        if let img = memory.object(forKey: key) { return img }
        let file = diskDir.appendingPathComponent(key(for: url))
        guard let data = try? Data(contentsOf: file),
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key)
        return img
    }

    func store(_ image: UIImage, for url: URL) {
        memory.setObject(image, forKey: url.absoluteString as NSString)
        let file = diskDir.appendingPathComponent(key(for: url))
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// 下载 + 缓存 + 返回；命中缓存则直接返回
    /// - Parameter cacheToDisk: 原图体积大且后端就是源文件，没必要再往磁盘写一份（会占满缓存目录），
    ///   传 false 只进内存缓存
    func load(from url: URL, cacheToDisk: Bool = true) async -> UIImage? {
        if let img = image(for: url) { return img }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // 惰性解码坑：UIImage(data:) 只标记数据，真正的位图解码发生在
            // 「首次上屏渲染」那一刻（主线程同步解码，几十 ms → 掉帧）。
            // 这里主动重画一遍强制解码，把开销留在后台线程。
            guard let img = UIImage(data: data).map(forceDecoded) else { return nil }
            if cacheToDisk {
                store(img, for: url)
            } else {
                memory.setObject(img, forKey: url.absoluteString as NSString)
            }
            return img
        } catch {
            return nil
        }
    }

    // MARK: - 降采样加载（看图器 preview 档）

    /// 同步查降采样档缓存
    func downsampledImage(for url: URL, maxPixel: Int) -> UIImage? {
        let key = downKey(url, maxPixel)
        if let img = memory.object(forKey: key) { return img }
        let file = diskDir.appendingPathComponent(key(for: url) + "_ds\(maxPixel)")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key)
            return img
        }
        return nil
    }

    /// 下载 + **降采样**到指定长边像素 + 缓存 + 返回；命中缓存则直接返回。
    ///
    /// 为什么需要：后端 `/photo` 只有 original（全尺寸）和 400px 缩略图两档，
    /// 没有中间档。全尺寸原图 3000×4000~6000×4000，`UIImage(data:)` 会留下
    /// 全尺寸位图（单张 48~96MB），看图器同时挂当前+左右相邻三张原图，
    /// 滑动/退出动画期间每帧都要合成这些巨大纹理，且首帧上屏还要主线程
    /// 同步解码 → 掉帧。用 ImageIO 缩略图 API 在后台直接产出「目标尺寸且
    /// 已解码」的位图，内存降到约 1/6，首帧无解码开销。
    ///
    /// - Parameter maxPixel: 长边像素上限（不会放大小图）
    func loadDownsampled(from url: URL, maxPixel: Int, cacheToDisk: Bool = true) async -> UIImage? {
        if let img = downsampledImage(for: url, maxPixel: maxPixel) { return img }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = downsample(src, maxPixel: maxPixel) else { return nil }
            if cacheToDisk, let jpeg = img.jpegData(compressionQuality: 0.92) {
                let file = diskDir.appendingPathComponent(key(for: url) + "_ds\(maxPixel)")
                try? jpeg.write(to: file, options: .atomic)
            }
            memory.setObject(img, forKey: downKey(url, maxPixel))
            return img
        } catch {
            return nil
        }
    }

    /// ImageIO 缩采样：长边上限 maxPixel，返回的位图**已解码**
    /// （CGImageSourceCreateThumbnailAtIndex 生成即解码，上屏无额外开销）。
    /// ⚠️ 必须带 kCGImageSourceCreateThumbnailWithTransform：否则不应用 EXIF 旋转，
    /// 手机竖拍照片 downsample 后会横竖颠倒（UIImage(data:) 是自动转正的，行为要对齐）。
    private func downsample(_ src: CGImageSource, maxPixel: Int) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // scale=1：img.size 即像素尺寸（onLoaded 回传像素给 1:1 计算用）
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    private func downKey(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.absoluteString)|ds\(maxPixel)" as NSString
    }

    /// 用离屏渲染强制解码位图（消除 UIImage 惰性解码造成的首帧主线程卡顿）
    /// - opaque 保持 false：照片库里可能有 PNG 透明图，true 会把透明区填黑
    private func forceDecoded(_ img: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = img.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: img.size, format: format)
        return renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }

    /// 用 SHA256 生成稳定、无非法字符的磁盘文件名
    private func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }
}
