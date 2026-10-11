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

    /// 「进入相册」跳转目标：看图器里点进入所在相册时设置，RootView 监听后 push。
    @Published var openAlbumTarget: AlbumOpenTarget?

    // MARK: - 进入相册时「保留挂载、只隐藏」
    // ⚠️ 演进过程（都是踩过的坑）：
    //  1) 最初直接关掉看图器 → 相册页返回后退回打开看图器之前的照片流，详情卡片丢了；
    //  2) 改成「关掉再恢复」→ 看图器是重建的，详情卡片被重新弹一次，很怪；
    //  3) 现在：看图器**保留在层级里**，只是透明 + 不吃点击（suspended），
    //     相册页 push 在 tab 的导航栈里正常显示；pop 回来把透明度恢复即可 ——
    //     看图器和详情卡片的状态（包括翻到第几张、卡片开着与否）全都在，
    //     看到的就是「返回直接露出上一页」。
    /// 只是被相册页临时遮住（看图器仍在层级里，不能卸载）
    @Published var suspended = false

    func show(_ photos: [Photo], index: Int, hasMore: Bool = false, onLoadMore: (() -> Void)? = nil) {
        self.photos = photos
        self.startIndex = index
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        suspended = false
        generation += 1
        isVisible = true
    }

    func updatePhotos(_ photos: [Photo]) { self.photos = photos }

    /// 真正退出看图器：卸载（与「挂起」区分开）
    func dismiss() {
        isVisible = false
        suspended = false
    }

    /// 翻页时回写当前下标（看图器若被重建，能回到原来那张而不是最初打开的那张）
    func updateStartIndex(_ i: Int) { startIndex = i }

    /// 进入相册：看图器保留挂载、只隐藏（好让相册页可见），并把跳转目标交给 RootView。
    /// ⚠️ 详情卡片是自绘 overlay（不是 sheet），会跟着父视图一起隐藏 —— 不会被留在屏幕上。
    func openAlbum(_ album: Album, libID: Int) {
        suspended = true
        openAlbumTarget = AlbumOpenTarget(album: album, libID: libID)
        isVisible = false
    }

    /// 相册页被 pop 掉 → 把看图器恢复成可见（不是重建）
    func resumeFromAlbum() {
        guard suspended else { return }
        suspended = false
        isVisible = true
    }
}
