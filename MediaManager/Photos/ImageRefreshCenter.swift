import SwiftUI

// MARK: - 封面强制回源
//
// 为什么需要这个东西：
// 封面 URL 是「稳定」的 —— /media-image?id=<media_images.id>&size=600。
// 服务端换海报是原地覆盖同一个文件（poster.jpg），media_images 那一行不动，
// 于是 id 不变、URL 一字不差。下拉刷新只重拉了列表 JSON，图片被三层缓存
// 挡在原地，永远是第一次下载时的那一版：
//   1. NSURLCache：/media-image 回的是
//      `Cache-Control: public, max-age=31536000, immutable`，
//      一年内 URLSession 连请求都不发，直接取本地缓存条目；
//   2. ImageCache 磁盘缓存：key 就是 URL 字符串，且从不失效；
//   3. ImageCache 内存缓存：同上。
// 所以「刷新」必须显式让图片回源一次，只刷新列表数据是没用的。
//
// 做法：下拉刷新结束时 bump 一次代际，本代内每张图**领一次回源资格**
// （claimReload），领到的那次加载走 forceReload（忽略 NSURLCache + 忽略
// ImageCache 命中），下载完按原 URL 覆盖写回缓存。
//
// ⚠️ 早期是「刷新后开 8 秒窗口、窗口内才回源」，有三个洞：
//   · 刷新完没马上看，8 秒后滚过去 → 走缓存，还是旧图；
//   · 回源下载被 SwiftUI 取消（cell 滚出可见区）→ 滚回来窗口已过，旧图；
//   · 详情页进来时早就过了 8 秒 → 旧图。
// 改成代际后与时间无关：只要这张图本代没成功回源过，任何时候发起都回源；
// 成功后记一笔，本代内不再重复下载（用 claimBudget 封顶，防止刷新后一路
// 狂滚把整个库的封面重下一遍）。
//
// 另外 ImageCache 现在自己也带 ETag 校验（5 分钟确认一次），即便不下拉刷新，
// 服务端换了图 App 也会自动跟上 —— 这里只负责「刷新后立刻看到」。
final class ImageRefreshCenter: ObservableObject {
    static let shared = ImageRefreshCenter()

    private let lock = NSLock()

    /// 刷新代数。RemoteImage 把它并进 .task(id:)：代数一变，
    /// 当前可见的封面加载任务就会重跑一次。
    @Published private(set) var generation: Int = 0

    /// 本代已经领过回源资格的 URL。
    ///
    /// 为什么不是「时间窗口」：原实现是刷新后开 8 秒窗口，窗口外发起的加载
    /// 不回源。于是这些情况都会漏 ——
    ///   · 列表刷新完用户没马上看，8 秒后滚过去：走缓存，还是旧图；
    ///   · 回源下载被 SwiftUI 取消（cell 滚出可见区），滚回来时窗口已过：旧图。
    /// 改成「代际 + 每代每张只回源一次」：只要这张图在**本代**没成功回源过，
    /// 任何时候发起都回源；成功（或确认无变化）后记一笔，本代内不再重复下载。
    private var claimed: Set<String> = []

    /// 单代回源上限。防止刷新后一路狂滚把整个库的封面都重新下一遍
    /// （挂载盘上一张要 1~6 秒，几万张能把带宽吃干）。
    private let claimBudget = 3000
    private var claimedCount = 0

    /// 触发一次回源代际。可以任意线程调用；状态统一在主线程改。
    func bump() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.lock.lock()
            self.claimed.removeAll()
            self.claimedCount = 0
            self.lock.unlock()
        }
    }

    /// 领取「本代回源资格」：同一代内同一 URL 只有第一次返回 true。
    /// true = 这次要真的回源一次（绕开 NSURLCache + ImageCache 命中）。
    func claimReload(for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let k = url.absoluteString
        if claimed.contains(k) { return false }
        if claimedCount >= claimBudget { return false }
        claimed.insert(k)
        claimedCount += 1
        return true
    }

    /// 归还资格。加载失败/被取消时调用 —— 不归还的话，这张图本代再也不会回源，
    /// 用户看到的就一直是最开始那份旧图。
    func releaseReload(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        if claimed.remove(url.absoluteString) != nil {
            claimedCount = max(0, claimedCount - 1)
        }
    }
}

extension View {
    /// 下拉刷新 + 顺带刷新封面。
    ///
    /// 行为与系统的 .refreshable 完全一致，只是刷新完成后 bump 一次回源窗口，
    /// 让本屏封面重新向服务端要一次 —— 否则换过海报的条目会一直停在旧封面。
    func refreshing(_ action: @escaping () async -> Void) -> some View {
        self.refreshable {
            await action()
            ImageRefreshCenter.shared.bump()
        }
    }
}
