import SwiftUI

// MARK: - 看图器全局呈现器
// ⚠️⚠️ 为什么不用 .fullScreenCover：UIKit 的 fullScreen 呈现会把底层页面**移出窗口层级**，
// 退出（下滑渐隐）时露出的不是上一级页面，而是空窗口（白/灰）—— 就是「退出闪大白屏」。
// 改用 RootView 顶层的 overlay 呈现：底层页面始终在层级里渲染，
// 黑底一渐隐，露出的就是照片网格本身，退出全程无跳变。
// （短视频刷流的 FullscreenOverlay 是同一个思路的先例。）
final class PhotoViewerPresenter: ObservableObject {
    static let shared = PhotoViewerPresenter()

    @Published var isVisible = false
    /// 看图器当前的照片数组。调用方在网格翻页（loadMore）后要调 updatePhotos 同步，
    /// 否则看图器里翻不到新加载的图。
    @Published var photos: [Photo] = []
    private(set) var startIndex = 0
    private(set) var hasMore = false
    private(set) var onLoadMore: (() -> Void)?

    func show(_ photos: [Photo], index: Int, hasMore: Bool = false, onLoadMore: (() -> Void)? = nil) {
        self.photos = photos
        self.startIndex = index
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        isVisible = true
    }

    func updatePhotos(_ photos: [Photo]) { self.photos = photos }

    func dismiss() { isVisible = false }
}
