import SwiftUI

// MARK: - 看图器全局呈现器
// ⚠️⚠️ 为什么不用 .fullScreenCover：UIKit 的 fullScreen 呈现会把底层页面**移出窗口层级**，
// 退出（下滑渐隐）时露出的不是上一级页面，而是空窗口（白/灰）—— 就是「退出闪大白屏」。
// 改用 RootView 顶层的 overlay 呈现：底层页面始终在层级里渲染，
// 黑底一渐隐，露出的就是照片网格本身，退出全程无跳变。
// （短视频刷流的 FullscreenOverlay 是同一个思路的先例。）
// MARK: - 相册跳转目标
// 看图器详情卡片点「进入相册」→ 看图器原地不动，RootView 在它之上盖一层相册页
//（AlbumPageLayer）。返回时撤掉那层就是详情卡片，全程不重建、不重新弹出。
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

    /// 「进入相册」打开的相册层：非 nil 时 RootView 在看图器**之上**渲染 AlbumPageLayer。
    /// ⚠️ 看图器全程 isVisible=true（不隐藏、不卸载），相册层只是盖在它上面 ——
    /// 滑动返回的整个过程中，下面的看图器和详情卡片都是实时可见的。
    /// 之前把相册页 push 到 tab 导航栈、看图器设成透明挂起，结果滑到一半时
    /// 看图器还是透明的（path 要等 pop 完成才变化），半路露出的是照片流。
    @Published var albumPageTarget: AlbumOpenTarget?
    /// 相册页里点开照片时，看图器要临时升到相册层之上（RootView 按它排 zIndex）。
    @Published var viewerAboveAlbum = false

    func show(_ photos: [Photo], index: Int, hasMore: Bool = false, onLoadMore: (() -> Void)? = nil) {
        self.photos = photos
        self.startIndex = index
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        // 相册页里点开照片 → 看图器升到相册层之上；关掉后露出相册层（不是照片流）
        viewerAboveAlbum = (albumPageTarget != nil)
        generation += 1
        isVisible = true
    }

    func updatePhotos(_ photos: [Photo]) { self.photos = photos }

    /// 真正退出看图器。若是从相册页里退出的，露出的是相册层
    func dismiss() {
        isVisible = false
        viewerAboveAlbum = false
    }

    /// 翻页时回写当前下标（看图器若被重建，能回到原来那张而不是最初打开的那张）
    func updateStartIndex(_ i: Int) { startIndex = i }

    /// 进入相册：看图器（连同详情卡片）原地不动，相册层直接盖上来。
    /// 返回时撤掉相册层就是详情卡片 —— 全程没有重建、没有重新弹出。
    func openAlbum(_ album: Album, libID: Int) {
        viewerAboveAlbum = false
        albumPageTarget = AlbumOpenTarget(album: album, libID: libID)
    }

    /// 关闭相册层（返回）：下面的看图器和详情卡片本来就在那儿
    func closeAlbum() {
        albumPageTarget = nil
        viewerAboveAlbum = false
    }
}
