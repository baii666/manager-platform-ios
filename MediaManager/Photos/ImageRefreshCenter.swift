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
// 做法：下拉刷新结束时 bump 一次，开一个短窗口；窗口内**发起**的图片加载
// 走 forceReload（忽略 NSURLCache + 忽略 ImageCache 命中），下载完按原 URL
// 覆盖写回缓存。窗口外恢复正常缓存路径 —— 否则每次滚动都会把整个库的封面
// 重新下一遍。
final class ImageRefreshCenter: ObservableObject {
    static let shared = ImageRefreshCenter()

    private let lock = NSLock()

    /// 刷新代数。RemoteImage 把它并进 .task(id:)：代数一变，
    /// 当前可见的封面加载任务就会重跑一次。
    @Published private(set) var generation: Int = 0

    /// 强制回源窗口的截止时刻（nil = 不在窗口内）
    private var forceUntil: Date? = nil

    /// 窗口长度。够 SwiftUI 重算可见区、把这一屏的 task 全部起起来就行；
    /// 判定看的是**发起时刻**，不是下载完成时刻。
    private let window: TimeInterval = 8

    /// 触发一次回源窗口。可以任意线程调用；状态统一在主线程改。
    func bump() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.forceUntil = Date().addingTimeInterval(self.window)
        }
    }

    /// 当前是否处在「刚下拉刷新过」的窗口内
    var shouldReloadFromSource: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = forceUntil else { return false }
        if until < Date() {
            forceUntil = nil
            return false
        }
        return true
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
