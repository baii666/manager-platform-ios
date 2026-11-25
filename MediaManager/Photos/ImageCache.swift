import UIKit
import CryptoKit
import ImageIO

// MARK: - 图片缓存（内存 NSCache + 磁盘）
// 应对百万级照片的关键：内存命中极快、磁盘兜底、自动 LRU 淘汰。
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    /// URL → 缓存条目的校验信息（ETag + 上次向服务端确认的时刻）
    private let metas = NSCache<NSString, EntryMeta>()
    private let fileManager = FileManager.default
    private let diskDir: URL
    private let lock = NSLock()

    /// 向服务端确认过「还是这一版」之后，多久内不再问一次。
    ///
    /// 与网关 /media-image、/photo 的 `Cache-Control: max-age=300` 对齐：
    /// 服务端 5 分钟后就要重新校验，客户端跟着走，两边节奏一致。
    /// 之前这里是「永不失效」—— 磁盘缓存 key 只是 URL 的哈希，服务端原地换了
    /// 海报，本地磁盘那份旧图会一直命中，App 永远显示旧封面。
    private let revalidateInterval: TimeInterval = 300

    /// 🔴 缓存策略全 App 统一：云端浏览器与相册都走 `revalidateInterval`（5 分钟）。
    /// 之前云端 URL 曾用 7 天校验间隔（为 115 慢链路设计），115 CDN 停用后没必要，
    /// 用户要求「云浏览缓存策略和相册一样」，已移除该特例。

    /// 缓存条目的校验信息（磁盘上存一份 `<sha>.meta`，跨会话保留）
    ///
    /// ⚠️ 必须是 class：NSCache 的 ObjectType 要求 AnyObject，struct 编不过。
    /// 引用类型还有个好处：touchValidated 改的就是内存里那一份，不用再塞回去。
    private final class EntryMeta: Codable {
        var etag: String? = nil
        /// 上次向服务端确认「仍是这一版」的时刻
        var validatedAt: Date = Date()

        init() {}
        init(etag: String?, validatedAt: Date) {
            self.etag = etag
            self.validatedAt = validatedAt
        }
    }

    init() {
        memory.countLimit = 500
        memory.totalCostLimit = 256 * 1024 * 1024 // 256 MB 内存上限
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// 🔴 统一写内存缓存并**计入 cost**。
    /// NSCache 的 totalCostLimit（256MB）只在 setObject 带 cost 时才会触发淘汰；
    /// 此前所有 setObject 都不传 cost（默认 0），等于上限失效，只剩 countLimit=500，
    /// 云端全原图滚动时几百张全尺寸位图只增不减 → 内存爆掉被系统 Jetsam 杀掉（闪退）。
    private func setMemory(_ img: UIImage, forKey k: NSString) {
        memory.setObject(img, forKey: k, cost: imgCost(img))
    }

    /// 位图占用字节数：宽×高×4（RGBA）；动图按所有帧累加。
    private func imgCost(_ img: UIImage) -> Int {
        func bytes(_ i: UIImage) -> Int { Int(i.size.width * i.size.height) * 4 }
        if let frames = img.images { return frames.reduce(0) { $0 + bytes($1) } }
        return bytes(img)
    }

    /// 清空内存 + 磁盘缓存（设置里的「清除图片缓存」）。
    /// 换过海报/封面但 App 一直显示旧图时的手动兜底 —— 缓存没有过期机制，
    /// 而封面 URL 又是稳定的，不主动清就永远命中第一版。
    func clearAll() {
        memory.removeAllObjects()
        metas.removeAllObjects()
        // 🔴 必须连 URLSession 的系统级 NSURLCache 一起清。之前只清自己的磁盘目录，
        // NSURLCache 里仍留着 /thumb 的 Last-Modified 响应；下次请求带 If-Modified-Since
        // 拿到 304 后 load() 的 304 分支会 return image(for:)（本地已被清）→ nil → 满屏灰砖。
        URLCache.shared.removeAllCachedResponses()
        guard let files = try? fileManager.contentsOfDirectory(at: diskDir,
                                                               includingPropertiesForKeys: nil) else { return }
        for f in files { try? fileManager.removeItem(at: f) }
    }

    /// 同步查内存 + 磁盘缓存
    func image(for url: URL) -> UIImage? {
        // ⚠️ 局部变量不能叫 key：会遮蔽成员方法 key(for:)，后面的 key(for:) 调用
        // 会被解析成「调用 NSString 局部变量」报 cannot call value of non-function type
        let memKey = url.absoluteString as NSString
        if let img = memory.object(forKey: memKey) { return img }
        let file = diskDir.appendingPathComponent(key(for: url))
        guard let data = try? Data(contentsOf: file) else { return nil }
        // 🔴 磁盘里动图存的是原始字节，UIImage(data:) 只会解第一帧 → 重启后动图变静态。
        // 和下载路径一样先走 ImageIO 解码。
        let img = decodeAnimated(data) ?? UIImage(data: data)
        guard let img else { return nil }
        setMemory(img, forKey: memKey)
        return img
    }

    /// - Parameter originalData: 下载到的原始字节。动图（gif/apng）必须传它：
    ///   `jpegData()` 只编码第一帧，会把动画压成静态图；存原始字节才能让
    ///   `image(for:)` 用 `UIImage(data:)` 还原出可播放的动图。静态图不传，继续存 jpeg。
    func store(_ image: UIImage, for url: URL, originalData: Data? = nil) {
        setMemory(image, forKey: url.absoluteString as NSString)
        let file = diskDir.appendingPathComponent(key(for: url))
        if let originalData, (image.images?.count ?? 0) > 1 {
            try? originalData.write(to: file, options: .atomic)
        } else if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// 把下载到的字节解码成可显示图片。
    /// 🔴 关键：iOS 的 `UIImage(data:)` 对 GIF/APNG **只解第一帧**（`images` 为 nil）——
    /// 这是本项目 AnimatedWebView 里已验证的事实。所以动图必须用 ImageIO 逐帧解出，
    /// 生成 `UIImage.animatedImage`（SwiftUI `Image(uiImage:)` / UIImageView 都能直接播）。
    /// 静态图照旧 forceDecoded 消除首帧主线程卡顿。
    /// 返回 (图片, 是否动图)，调用方据此决定是否把原始字节交给 store。
    private func decode(_ data: Data) -> (UIImage, Bool)? {
        if let animated = decodeAnimated(data) { return (animated, true) }
        guard let src = UIImage(data: data) else { return nil }
        return (forceDecoded(src), false)
    }

    /// ImageIO 逐帧解码 GIF/APNG → 可播放的 animated UIImage；单帧/解码失败返回 nil。
    /// 帧间隔从 GIF 的 kCGImagePropertyGIFDictionary 读，缺省 0.1s。
    private func decodeAnimated(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var durations: [TimeInterval] = []
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            durations.append(gifDelay(at: i, in: source))
        }
        guard frames.count > 1 else { return nil }
        // durations 仅在都有效时用于近似统一帧率；animatedImage 用单张 duration 表示总时长，
        // 逐帧不等间隔无法精确表达，取平均即可（这批 GIF 实测都是恒定 0.1s）。
        let avg = durations.reduce(0, +) / Double(durations.count)
        let perFrame = avg > 0 && avg.isFinite ? avg : 0.1
        return UIImage.animatedImage(with: frames, duration: perFrame * Double(frames.count))
    }

    private func gifDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let raw = gif[kCGImagePropertyGIFDelayTime] as? NSNumber else { return 0.1 }
        let d = raw.doubleValue
        return d > 0 && d.isFinite ? d : 0.1
    }

    /// 下载 + 缓存 + 返回；命中缓存则直接返回
    /// - Parameter cacheToDisk: 原图体积大且后端就是源文件，没必要再往磁盘写一份（会占满缓存目录），
    ///   传 false 只进内存缓存
    /// - Parameter forceReload: 强制回源。跳过本地两层缓存，并且让 URLSession 也别用
    ///   NSURLCache 的条目（封面接口回的是 immutable，不显式忽略它连请求都不发）。
    ///   下载成功后仍按**原 URL** 写回缓存 —— 覆盖旧文件，不会越积越多。
    ///
    /// 不强制回源时也不是「命中就完事」：
    ///   1. 本地有图且 5 分钟内刚向服务端确认过 → 直接用，一个请求都不发；
    ///   2. 本地有图但超过 5 分钟没确认 → **先给本地这份**（界面不等），
    ///      后台补一次条件请求（If-None-Match: ETag）：
    ///      · 304 → 还是这一版，只刷新确认时刻；
    ///      · 200 → 服务端换了图，写回新图 + 新 ETag，下次进来就是新的。
    ///      ⚠️ 这里刻意不等请求：挂载盘上一张要 1~6 秒，滚动相册时逐张等会卡死。
    ///   3. 本地没图 → 正常下载。
    /// 这样服务端原地换海报，App 最多两轮自动跟上，不靠下拉刷新、不靠版本号。
    func load(from url: URL, cacheToDisk: Bool = true, forceReload: Bool = false) async -> UIImage? {
        if !forceReload, let img = image(for: url) {
            if metaIsFresh(for: url) { return img }
            revalidateInBackground(url, cacheToDisk: cacheToDisk)
            return img
        }
        do {
            var request = URLRequest(url: url)
            if forceReload {
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            } else {
                // 让 URLSession 一定去找服务端确认，而不是直接吃 NSURLCache 的旧条目
                request.cachePolicy = .reloadRevalidatingCacheData
                if let etag = meta(for: url)?.etag {
                    request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200

            if status == 304 {
                // 服务端说没变：正常情况刷新确认时刻、继续用本地这份。
                // 🔴 但 NSURLCache 可能仍缓存着旧响应（Last-Modified 条件请求命中），
                // 而 ImageCache 自己的磁盘图已被 clearAll 清掉 —— 这时 image(for:) 返回 nil，
                // 直接 return 就是灰砖。本地图没了就当没缓存处理：清掉系统缓存、忽略缓存强制回源重写一份。
                if let local = image(for: url) {
                    touchValidated(for: url)
                    return local
                }
                URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
                do {
                    let (data2, resp2) = try await URLSession.shared.data(
                        for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
                    guard let (img2, animated) = decode(data2) else { return nil }
                    if cacheToDisk { store(img2, for: url, originalData: animated ? data2 : nil) }
                    else { setMemory(img2, forKey: url.absoluteString as NSString) }
                    saveMeta(EntryMeta(etag: (resp2 as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
                                       validatedAt: Date()), for: url)
                    return img2
                } catch {
                    return nil
                }
            }

            // 惰性解码坑：UIImage(data:) 只标记数据，真正的位图解码发生在
            // 「首次上屏渲染」那一刻（主线程同步解码，几十 ms → 掉帧）。
            // 静态图主动重画一遍强制解码，把开销留在后台线程；
            // 🔴 动图（gif/apng）绝不能 forceDecoded —— 渲染器只画第一帧，会毁掉动画。
            guard let (img, animated) = decode(data) else {
                // 解不出来也别开天窗：有旧图就先顶着
                return image(for: url)
            }
            if cacheToDisk {
                store(img, for: url, originalData: animated ? data : nil)
            } else {
                setMemory(img, forKey: url.absoluteString as NSString)
            }
            let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            saveMeta(EntryMeta(etag: etag, validatedAt: Date()), for: url)
            return img
        } catch {
            // 网络失败/取消：有旧图就用旧图（宁可旧，不要开天窗）。
            // 下一轮加载还会再试 —— 没成功确认过，meta 的确认时刻不会推进。
            return image(for: url)
        }
    }

    // MARK: - 条目校验信息（ETag + 确认时刻）

    private func metaKey(_ url: URL) -> NSString { url.absoluteString as NSString }

    private func meta(for url: URL) -> EntryMeta? {
        let k = metaKey(url)
        lock.lock()
        let inMem = metas.object(forKey: k)
        lock.unlock()
        if let inMem { return inMem }
        let file = diskDir.appendingPathComponent(key(for: url) + ".meta")
        guard let data = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode(EntryMeta.self, from: data) else { return nil }
        lock.lock()
        metas.setObject(m, forKey: k)
        lock.unlock()
        return m
    }

    private func saveMeta(_ m: EntryMeta, for url: URL) {
        let k = metaKey(url)
        lock.lock()
        metas.setObject(m, forKey: k)
        lock.unlock()
        let file = diskDir.appendingPathComponent(key(for: url) + ".meta")
        try? JSONEncoder().encode(m).write(to: file, options: .atomic)
    }

    /// 304：内容没变，只把「已确认」时刻推到当下
    private func touchValidated(for url: URL) {
        let m = meta(for: url) ?? EntryMeta()
        m.validatedAt = Date()
        saveMeta(m, for: url)
    }

    /// 距上次确认未超过该 URL 的校验间隔 → 直接用本地图，一个请求都不发
    private func metaIsFresh(for url: URL) -> Bool {
        guard let m = meta(for: url) else { return false }
        return Date().timeIntervalSince(m.validatedAt) < revalidateInterval(for: url)
    }

    /// 🔴 全 App 统一 5 分钟校验（相册 / 云端浏览器一致）。
    /// 保留这个方法签名是为了不动 metaIsFresh 的调用链；不再区分云端 URL。
    private func revalidateInterval(for url: URL) -> TimeInterval {
        return revalidateInterval
    }

    /// 正在后台校验的 URL
    private var validating: Set<String> = []
    /// 后台校验并发上限。
    ///
    /// ⚠️ 没有这个限制会很惨：升级后所有老缓存条目都没有 .meta，滚动相册时
    /// 每出现一张就触发一次后台校验，几百张同时发 → 挂载盘直接被压死
    /// （那边一张要 1~6 秒）。限到 4 路，和前台加载互不抢道。
    private let maxConcurrentValidation = 4

    /// 后台补一次校验（不阻塞当前这张图的显示）
    private func revalidateInBackground(_ url: URL, cacheToDisk: Bool) {
        let k = url.absoluteString
        lock.lock()
        if validating.contains(k) || validating.count >= maxConcurrentValidation {
            lock.unlock()
            return // 已在校验 / 队列满了：跳过，下次进来还会再试
        }
        validating.insert(k)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.revalidate(url, cacheToDisk: cacheToDisk)
            // ⚠️ 别把 lock()/unlock() 直接写在这个 async 闭包里：NSLocking 的
            // lock/unlock 带 noasync 标记，Xcode 会在两行各报一次
            // "'lock()' is unavailable from asynchronous contexts; use withLock instead"
            // （Swift 6 语言模式下直接是 error）。挪进同步方法，语义不变。
            self.finishValidation(k)
        }
    }

    /// 同步方法：把校验完的 URL 移出集合。
    /// NSLock 的 lock()/unlock() 不能在 async 上下文调用，包一层即可。
    private func finishValidation(_ k: String) {
        lock.lock()
        validating.remove(k)
        lock.unlock()
    }

    private func revalidate(_ url: URL, cacheToDisk: Bool) async {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        if let etag = meta(for: url)?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 {
                touchValidated(for: url)
                return
            }
            guard let (img, animated) = decode(data) else { return }
            if cacheToDisk {
                store(img, for: url, originalData: animated ? data : nil)
            } else {
                setMemory(img, forKey: url.absoluteString as NSString)
            }
            saveMeta(EntryMeta(etag: http?.value(forHTTPHeaderField: "ETag"),
                               validatedAt: Date()), for: url)
        } catch {
            // 后台校验失败无所谓：meta 不推进，下次还会再试
        }
    }

    // MARK: - 网格缩略图加载（云端原图专用档）
    //
    // 🔴 云端浏览器网格里的图全部来自 /raw 原图（用户红线：云端不出缩略图），
    //    若按原尺寸全量解码进内存，滚动几百张就会 OOM 被系统杀进程（一滑就退出）。
    //    这里给网格单独开一档降采样：静态图按显示尺寸解码、独立缓存 key，
    //    **不写原图档**（看图器点开仍从原图档拿完整原图，红线不受影响）。
    //    动图保持原样走动画解码，不改动画行为（用户要求不改动图）。

    /// 网格专用：静态图按 maxPixel 降采样，动图走原档（保动画）。
    /// - Parameter maxPixel: 长边像素上限。网格 cell 显示尺寸很小，600 足够清晰。
    func loadGridThumb(from url: URL, maxPixel: Int = 600) async -> UIImage? {
        // 静态图：命中独立降采样档直接回
        if let img = downsampledImage(for: url, maxPixel: maxPixel) { return img }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // 动图（多帧）：交回原档走动画解码，保持动画不变
            if let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 1,
               let animated = decodeAnimated(data) {
                setMemory(animated, forKey: url.absoluteString as NSString)
                return animated
            }
            // 静态图：ImageIO 直接产出目标尺寸的已解码位图
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = downsample(src, maxPixel: maxPixel) else {
                return await load(from: url, cacheToDisk: false)  // 兜底：原流程
            }
            setMemory(img, forKey: downKey(url, maxPixel))
            return img
        } catch {
            return downsampledImage(for: url, maxPixel: maxPixel) ?? image(for: url)
        }
    }

    // MARK: - 降采样加载（看图器 preview 档）

    /// 同步查降采样档缓存
    func downsampledImage(for url: URL, maxPixel: Int) -> UIImage? {
        // ⚠️ 同上：局部变量不能叫 key（遮蔽 key(for:) 方法）
        let memKey = downKey(url, maxPixel)
        if let img = memory.object(forKey: memKey) { return img }
        let file = diskDir.appendingPathComponent(key(for: url) + "_ds\(maxPixel)")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            setMemory(img, forKey: memKey)
            return img
        }
        return nil
    }

    /// 下载 + **降采样**到指定长边像素 + 缓存 + 返回；命中缓存则直接返回。
    ///
    /// 为什么需要：后端 `/photo` 只有 original（全尺寸）和 600 缩略图两档
    /// （`thumbpath.Normalize` 把任何尺寸收敛到 StandardSize=600，刻意全局一档），
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
            setMemory(img, forKey: downKey(url, maxPixel))
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
