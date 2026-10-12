import SwiftUI
import UIKit  // 相册层根的窗口快照（UIGraphicsImageRenderer）

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
    /// 系统状态栏是否隐藏。与 isVisible **解耦**：退出时要让状态栏与淡出动画
    /// **同步**恢复 —— 否则 0.27s 后 dismiss 那一刻才出现，背景页「先无状态栏、
    /// 后突然有」，视觉上抖一下（RootView 按它控制 .statusBarHidden）。
    /// show() 置 true；beginDismiss() 置 false（相册层盖着时除外）。
    @Published var statusBarHidden = true
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

    /// 「进入相册」时抓的整屏快照（看图器 + 详情卡片），相册层 NavigationStack 根的
    /// 不透明背景。普通属性（非 @Published）：openAlbum 里先抓快照再设 albumPageTarget，
    /// 后者触发的 body 刷新里读它一定是新值。
    ///
    /// ⚠️ 为什么需要它：相册层是「透明根 NavigationStack + 系统原生 push」。透明根在
    /// **过渡过程中**背后渲染的是窗口底色（浅色模式 = 白），右滑返回滑到一半就是一片
    /// 大白屏。改用这张不透明快照当根的背景后，push/pop 两个方向滑出来的都是看图器
    /// 本身的逐像素副本，不再依赖 UIKit 对透明根的渲染。
    /// 抓取失败时为 nil，相册层退回透明根（最差即旧行为）。
    var albumBackdrop: UIImage? = nil
    /// 每次 openAlbum 自增。RootView 用它给相册层做 .id：返回后 350ms 撤层等待期内
    /// 再次「进入相册」也能立刻重建图层并 push（否则图层不重建、onAppear 不再触发）。
    var albumOpenGeneration = 0

    func show(_ photos: [Photo], index: Int, hasMore: Bool = false, onLoadMore: (() -> Void)? = nil) {
        self.photos = photos
        self.startIndex = index
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        // 相册页里点开照片 → 看图器升到相册层之上；关掉后露出相册层（不是照片流）
        viewerAboveAlbum = (albumPageTarget != nil)
        generation += 1
        isVisible = true
        statusBarHidden = true
    }

    func updatePhotos(_ photos: [Photo]) { self.photos = photos }

    /// 真正退出看图器。若是从相册页里退出的，露出的是相册层
    func dismiss() {
        isVisible = false
        viewerAboveAlbum = false
    }

    /// 退出动画**开始**时调（PhotoViewerView.close() 的 withAnimation 里）：
    /// 状态栏与 0.25s 淡出同步恢复，而不是等 0.27s 后 dismiss 那一刻。
    /// ⚠️ 相册层盖着时（albumPageTarget != nil）退出看图器露出的是相册层 ——
    /// 相册层同样不要状态栏，这里保持隐藏，等相册层自己关闭时看图器仍在，
    /// 状态栏继续藏着，语义一致。
    func beginDismiss() {
        if albumPageTarget == nil { statusBarHidden = false }
    }

    /// 翻页时回写当前下标（看图器若被重建，能回到原来那张而不是最初打开的那张）
    func updateStartIndex(_ i: Int) { startIndex = i }

    /// 进入相册：看图器（连同详情卡片）原地不动，相册层直接盖上来。
    /// 返回时撤掉相册层就是详情卡片 —— 全程没有重建、没有重新弹出。
    func openAlbum(_ album: Album, libID: Int) {
        viewerAboveAlbum = false
        albumOpenGeneration += 1
        // 先抓快照再设 target：RootView 因 target 变化刷新建层时，快照必须已就位。
        // 此刻相册层还没出现，快照内容 = 看图器 + 详情卡片，不会拍到自己。
        albumBackdrop = Self.captureWindowSnapshot()
        albumPageTarget = AlbumOpenTarget(album: album, libID: libID)
    }

    /// 关闭相册层（返回）：下面的看图器和详情卡片本来就在那儿
    func closeAlbum() {
        albumPageTarget = nil
        viewerAboveAlbum = false
        albumBackdrop = nil
        // 兜底：若看图器已经退了（相册层内点开的看图器先关），beginDismiss 因
        // 「露的是相册层」没有恢复状态栏 —— 这里补上，否则状态栏会一直藏着
        if !isVisible { statusBarHidden = false }
    }

    /// 抓当前 key window 的整屏快照。失败返回 nil（调用方退回透明根）。
    private static func captureWindowSnapshot() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = window.traitCollection.displayScale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var captured = false
        let image = renderer.image { _ in
            // afterScreenUpdates: true —— 强制按当前已渲染状态出图，
            // 保证详情卡片这种刚交互过的自绘层一定在快照里。
            captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return captured ? image : nil
    }
}
