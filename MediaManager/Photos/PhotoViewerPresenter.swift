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

    // MARK: - 进入相册时的「挂起 / 恢复」
    // ⚠️ 之前 openAlbum 直接把看图器关掉（isVisible=false），相册页 pop 回来就退回
    // 打开看图器之前的那个照片流 —— 用户从详情卡片点「进入相册」，回来却丢了详情卡片。
    // 现在改成「挂起」：只是暂时隐藏看图器（好让相册页可见），栈弹回来时原样恢复，
    // 连详情卡片一起重新打开。
    /// 是否有挂起的看图器等待恢复
    private(set) var pendingResume = false
    /// 挂起时详情卡片是否开着（恢复时原样重开）
    private var resumeInfoCard = false
    /// 详情卡片恢复请求：由 PhotoViewerView 出现时消费一次
    private var infoCardRequested = false

    func show(_ photos: [Photo], index: Int, hasMore: Bool = false, onLoadMore: (() -> Void)? = nil) {
        self.photos = photos
        self.startIndex = index
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        // 相册页里另开看图器 = 新会话，取消上一次的挂起（否则 pop 时会错恢复旧的那张）
        pendingResume = false
        resumeInfoCard = false
        infoCardRequested = false
        generation += 1
        isVisible = true
    }

    func updatePhotos(_ photos: [Photo]) { self.photos = photos }

    func dismiss() {
        isVisible = false
        pendingResume = false
    }

    /// 翻页时回写当前下标：挂起恢复后 PhotoViewerView 会按 startIndex 重建，
    /// 不回写就会跳回最初打开的那张。
    func updateStartIndex(_ i: Int) { startIndex = i }

    /// 关闭看图器并请求跳转到相册（挂起，不是销毁）。
    func openAlbum(_ album: Album, libID: Int, infoCardOpen: Bool) {
        resumeInfoCard = infoCardOpen
        pendingResume = true
        openAlbumTarget = AlbumOpenTarget(album: album, libID: libID)
        // 只是隐藏：相册页 push 在 tab 的导航栈里，看图器 overlay 会盖住它
        isVisible = false
    }

    /// 相册页被 pop 掉 → 恢复挂起的看图器（含详情卡片）。没有挂起就直接返回。
    /// ⚠️ 不加 @MainActor：调用方（RootView / PhotoViewerView）本来就在主线程，
    /// 标了反而要在类内做隔离转换。
    func resumeFromAlbum() {
        guard pendingResume else { return }
        pendingResume = false
        isVisible = true
        if resumeInfoCard { infoCardRequested = true }
        resumeInfoCard = false
    }

    /// PhotoViewerView 出现时调用：是否需要立刻把详情卡片重新弹出来。
    /// ⚠️ 走「标志位 + 消费」而不是 @Published + onChange：恢复时视图是新创建的，
    /// onChange 首次渲染不触发（它只比较生命周期内的值变化），收不到。
    func consumeInfoCardRequest() -> Bool {
        guard infoCardRequested else { return false }
        infoCardRequested = false
        return true
    }
}
