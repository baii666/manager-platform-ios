import SwiftUI

// MARK: - 看图器全局呈现器
// ⚠️⚠️ 为什么不用 .fullScreenCover：UIKit 的 fullScreen 呈现会把底层页面**移出窗口层级**，
// 退出（下滑渐隐）时露出的不是上一级页面，而是空窗口（白/灰）—— 就是「退出闪大白屏」。
// 改用 RootView 顶层的 overlay 呈现：底层页面始终在层级里渲染，
// 黑底一渐隐，露出的就是照片网格本身，退出全程无跳变。
// （短视频刷流的 FullscreenOverlay 是同一个思路的先例。）
// MARK: - 相册跳转目标
// 看图器里点「进入相册」→ 关闭看图器 + 通过此目标让 RootView 切到媒体库 tab 并 push 相册页。
struct AlbumOpenTarget: Hashable, Identifiable {
    let album: Album
    let libID: Int
    var id: Int { album.id }
}

final class PhotoViewerPresenter: ObservableObject {
    static let shared = PhotoViewerPresenter()

    @Published var isVisible = false
    /// 看图器当前的照片数组。调用方在网格翻页（loadMore）后要调 updatePhotos 同步，
    /// 否则看图器里翻不到新加载的图。
    @Published var photos: [Photo] = []
    /// 代际令牌：show() 每次自增。PhotoViewerView 的 photos/index 是创建时的快照
    ///（let + @State initialValue），不响应 presenter.photos 变化；用 .id(generation)
    /// 强制重建视图，才能正确切换到新的照片数组（例如点击相似图单图覆盖）。
    @Published var generation = 0
    private(set) var startIndex = 0
    private(set) var hasMore = false
    private(set) var onLoadMore: (() -> Void)?

    /// 「进入相册」跳转目标：看图器里点进入所在相册时设置，RootView 监听后切 tab + push。
    @Published var openAlbumTarget: AlbumOpenTarget?

    func show(_ photos: [Photo], index: Int, hasMore: Bool = false, onLoadMore: (() -> Void)? = nil) {
        self.photos = photos
        self.startIndex = index
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        generation += 1
        isVisible = true
    }

    func updatePhotos(_ photos: [Photo]) { self.photos = photos }

    func dismiss() { isVisible = false }

    /// 关闭看图器并请求跳转到相册。
    func openAlbum(_ album: Album, libID: Int) {
        openAlbumTarget = AlbumOpenTarget(album: album, libID: libID)
        isVisible = false
    }
}
