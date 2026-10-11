import SwiftUI
import UIKit

// MARK: - 图片查看器
// 对齐网页版 components/ImageViewer.tsx 的核心能力：
//   原图加载（/photo?size=original）+ 缩略图占位 + 失败重试 3 次后回退缩略图
//   手势翻页（横向拖 > 15% 屏宽）/ 下拉关闭（纵向拖 > 150pt）
//   双指捏合缩放（0.3~10）+ 放大后拖动平移 + 双击 2.5x
//   底部工具栏（缩放 / 适应屏幕 / 1:1 / 旋转 / 缩略图条 / 信息 / 收藏 / 保存）
//   前后各 3 张预加载 + 滚到末尾触发 loadMore
struct PhotoViewerView: View {
    let photos: [Photo]
    var hasMore: Bool = false
    var onLoadMore: (() -> Void)? = nil
    var onClose: () -> Void = {}

    @State private var index: Int

    // UI 显隐
    @State private var showUI = true
    @State private var showInfo = false
    @State private var showThumbs = false
    @State private var tip: String?

    // 变换
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var rotation: Double = 0

    // 手势跟随
    @State private var trackOffset: CGFloat = 0
    @State private var dismissY: CGFloat = 0
    @State private var isClosing = false
    /// 关闭阶段整层的淡出系数：退出时看图器（含黑底）整体淡掉，
    /// 屏幕直接交还给上一级页面（照片网格），而不是让 cover 整层滑走。
    @State private var closingFade: Double = 1

    // 1:1 需要「图片像素尺寸」与「容器尺寸」
    @State private var imagePixelSize: CGSize?
    @State private var containerSize: CGSize = .zero

    @State private var isFavorite = false
    @State private var idleTask: Task<Void, Never>?
    @State private var tipTask: Task<Void, Never>?

    // 图片详情（EXIF / AI 标注），点信息按钮时异步拉取
    @State private var photoDetail: PhotoDetail?
    @State private var isLoadingDetail = false
    @State private var detailTask: Task<Void, Never>?

    // 人脸检测 + 相似图片（详情卡片的核心功能，按需展开）
    @State private var faces: [PhotoFace] = []
    @State private var facesLoading = false
    @State private var showFaces = false
    @State private var similarPhotos: [SimilarPhoto] = []
    @State private var similarLoading = false
    @State private var showSimilar = false
    @State private var similarMethod = "phash"

    private var client: APIClient? { AppSession.shared.client }

    init(photos: [Photo], index: Int = 0, hasMore: Bool = false,
         onLoadMore: (() -> Void)? = nil, onClose: @escaping () -> Void = {}) {
        self.photos = photos
        self.hasMore = hasMore
        self.onLoadMore = onLoadMore
        self.onClose = onClose
        _index = State(initialValue: min(max(index, 0), max(photos.count - 1, 0)))
    }

    private var photo: Photo? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        GeometryReader { geo in
            // ignoresSafeArea 后 geo.size = 整块屏幕；UI 元素用 safeAreaInsets 避让
            let safe = geo.safeAreaInsets
            // 缩略图条展开时：条直接贴顶盖住顶栏（黑底不透明，计数/关闭本就被挡住），
            // 图片紧贴条下方，不再额外让出「顶栏 + 状态栏」的黑边
            let topReserve: CGFloat = showThumbs ? 60 : 0
            let imageSize = CGSize(width: geo.size.width, height: geo.size.height - topReserve)

            // ⚠️ 对齐 .top：ZStack 默认居中会让 imageLayer（高=全屏-topReserve）顶边落在
            // topReserve/2，再叠加 offset(topReserve) 实际顶边=1.5×topReserve，条和图之间多出一段黑。
            // 顶部对齐后 offset(topReserve) 恰好把图片顶边推到条的下沿，图片也更大。
            ZStack(alignment: .top) {
                Color.black.opacity(backgroundOpacity)

                imageLayer(size: imageSize)
                    .offset(y: topReserve)

                topBar()
                bottomBar(bottomInset: safe.bottom)
                if let tip { toast(tip) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 缩略图条用 overlay 明确贴顶。之前放 ZStack 里、用 frame 撑满 + 外部 padding，
            // padding 落在撑满视图之外会导致整条缩略图超出布局、被 ZStack 居中，浮在画面正中。
            .overlay(alignment: .top) {
                if showThumbs {
                    thumbStrip
                        // 条贴屏幕最顶（状态栏已隐藏），不再给 topBar/灵动岛留黑边
                        .padding(.top, 0)
                }
            }
            .onAppear { containerSize = imageSize }
            .onChange(of: imageSize) { _, new in containerSize = new }
        }
        // ⚠️ 底部黑边根因：GeometryReader 默认遵守 safe area，图片层只画到
        // home indicator 上沿，底下露出黑色背景。ignore 后 geo.size = 全屏，
        // 图片真正铺满整屏；顶栏/底栏用 safeAreaInsets 手动避让。
        .ignoresSafeArea()
        .statusBarHidden(true)
        // ⚠️ 关闭时整层淡出（见 close(after:)）：图片飞出/原地 + 全层透明，
        // cover 真正 dismiss 时已经看不见，屏幕直接是上一级页面 —— 退出才丝滑
        .opacity(closingFade)
        .task(id: index) { await didChangeIndex() }
        // 保险：视图复用（同一 index 再次打开）时把上一次的关闭态清掉，
        // 否则 closingFade 还停在 0，重新打开就是一片空白
        .onAppear { isClosing = false; closingFade = 1; scheduleIdleHide() }
        .onDisappear { idleTask?.cancel(); tipTask?.cancel(); detailTask?.cancel() }
        // 详情用 sheet 弹出：独立于 showUI（点图隐藏工具栏不影响），下滑关闭，
        // 不再是之前那个跟随状态栏一起消失的底部面板。
        .sheet(isPresented: $showInfo) {
            if let photo { detailSheet(photo) }
        }
    }

    // MARK: - 图片层

    private func imageLayer(size: CGSize) -> some View {
        ZStack {
            if let photo {
                singleImage(photo, size: size, extraOffsetX: trackOffset)

                // 相邻图**始终预挂载**在屏幕外（左右各一张），而不是等拖动才挂。
                // 这样翻页时相邻图的原图早已加载好，滑进来就是清晰图，
                // 不会再出现「先缩略图、原图到位后再跳一下」的清晰度突变。
                if scale <= 1.01 {
                    if index + 1 < photos.count {
                        singleImage(photos[index + 1], size: size, extraOffsetX: trackOffset + size.width)
                    }
                    if index - 1 >= 0 {
                        singleImage(photos[index - 1], size: size, extraOffsetX: trackOffset - size.width)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(dragGesture(width: size.width))
        .simultaneousGesture(magnifyGesture)
        .onTapGesture(count: 2) { toggleZoom() }
        .onTapGesture { toggleUI() }
    }

    /// 单张图（含缩放 / 旋转 / 平移）。extraOffsetX 用于连续翻页时把相邻图放到屏幕外。
    private func singleImage(_ p: Photo, size: CGSize, extraOffsetX: CGFloat) -> some View {
        ViewerImageView(
            photo: p,
            containerSize: size,
            rotated: Int(rotation) % 180 != 0,
            // 只有当前主图才回填像素尺寸（供 1:1 计算），相邻图的加载别污染它
            onLoaded: { if p.id == photo?.id { imagePixelSize = $0 } }
        )
        .scaleEffect(scale)
        .rotationEffect(.degrees(rotation))
        .offset(x: offset.width + extraOffsetX, y: offset.height + dismissY)
        .id(p.id)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                    return
                }
                let dx = value.translation.width
                let dy = value.translation.height
                // 同网页版：水平权重 ×1.2，优先判为翻页
                if abs(dx) * 1.2 >= abs(dy) {
                    trackOffset = dx
                    dismissY = 0
                } else {
                    dismissY = dy
                    trackOffset = 0
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    lastOffset = offset
                    return
                }
                // 用预测位移判翻页：快速甩动时即使实际滑动距离短，也会预测出长位移 → 更灵敏；
                // 阈值从 15% 屏宽降到 8%，缩短「要滑多远才翻页」的触程。
                let dx = value.predictedEndTranslation.width
                let dy = value.translation.height
                if abs(dx) * 1.2 >= abs(dy) {
                    if abs(dx) > width * 0.08 {
                        go(dx < 0 ? 1 : -1)
                    } else {
                        withAnimation(Self.pageSpring) { trackOffset = 0 }
                    }
                } else if abs(dy) > 150 {
                    close(after: dy)
                } else {
                    withAnimation(Self.pageSpring) { dismissY = 0 }
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 0.3), 10)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.02 { resetTransform() }
            }
    }

    // MARK: - 变换操作

    private func resetTransform() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.22)) {
            if scale > 1.01 {
                resetTransform()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.18)) {
            scale = min(max(scale * factor, 0.3), 10)
            lastScale = scale
            if scale <= 1.02 { offset = .zero; lastOffset = .zero }
        }
    }

    /// 1:1 原始像素：按容器算出 scale=1 时的显示宽度，再反推缩放比
    /// （竖图竖屏走 fill，显示宽度要按 fill 算，否则 1:1 会偏小）
    private func fitNative() {
        guard let px = imagePixelSize,
              let fit = viewerFit(image: px, container: containerSize),
              fit.width > 0 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            scale = min(max(px.width / fit.width, 0.3), 10)
            lastScale = scale
            offset = .zero
            lastOffset = .zero
        }
    }

    // MARK: - 翻页 / 关闭

    /// 翻页弹簧：松手后「滑到位」用接近临界阻尼的弹簧，干脆利落、不回头，
    /// 接近系统相册翻页手感（easeOut 结尾减速「拖泥带水」，dampingFraction 过低会 overshoot 回头）。
    private static let pageSpring = Animation.interactiveSpring(response: 0.32, dampingFraction: 0.92, blendDuration: 0.2)

    private func go(_ delta: Int) {
        let next = index + delta
        if next < 0 {
            withAnimation(Self.pageSpring) { trackOffset = 0 }
            return
        }
        if next >= photos.count {
            if hasMore { onLoadMore?() }
            withAnimation(Self.pageSpring) { trackOffset = 0 }
            return
        }
        // 两图连续翻页：先把当前图连同相邻图一起滑到目标位置，动画真正结束后再切 index。
        // ⚠️ 不能用 DispatchQueue.asyncAfter(0.29) 兜「0.28s 动画结束」——那是 wall-clock 定时，
        // 主线程被原图解码卡一下就会让「动画还没滑到位就被强制切 index」，
        // 表现为翻页「跳一下」。改用 completionCriteria 等动画逻辑完成后才切。
        let width = containerSize.width
        let target = delta > 0 ? -width : width
        withAnimation(Self.pageSpring, completionCriteria: .logicallyComplete) {
            trackOffset = target
        } completion: {
            // 切 index 时 scale 已随位移过程归位，这里只做一次无动画的收尾复位，
            // 避免在切图那一帧把 scale 从非 1 值瞬跳（造成「顿一下」）。
            trackOffset = 0
            index = next
            resetTransform()
            imagePixelSize = nil
        }
    }

    private func close(after dy: CGFloat = 0) {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeOut(duration: 0.25)) {
            // dy == 0 = 点关闭按钮（不是手势）：图片原地不动，整层淡出即可。
            // 只有手势方向明确时才让图片顺着那个方向飞出去。
            if dy != 0 { dismissY = dy > 0 ? 1600 : -1600 }
            // 整层淡到 0：cover 真正 dismiss 时已经完全透明，
            // 屏幕上看到的就是上一级页面 —— 不会再出现「先黑/先白再跳一下」
            closingFade = 0
        }
        // 淡出动画走完（0.25s）再让 cover 消失：此时整层已透明，
        // 系统那一下 dismiss 就看不到了，屏幕上一直是上一级页面
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { onClose() }
    }

    private var backgroundOpacity: Double {
        guard dismissY != 0 else { return 1 }
        // 跟手下拉：黑底随位移渐隐，直接露出上一级页面（照片网格）。
        // 退出的背景就该是上一级页面本身，所以允许一路淡到 0（不再保留 0.15 底）。
        return max(CGFloat(0), CGFloat(1) - abs(dismissY) / CGFloat(900))
    }

    @MainActor
    private func didChangeIndex() async {
        resetTransform()
        await loadFavorite()
        preloadNeighbors()
        if hasMore, index >= photos.count - 3 { onLoadMore?() }
        // 翻页：清掉上一张的人脸/相似结果（避免串图）
        faces = []
        showFaces = false
        similarPhotos = []
        showSimilar = false
        // 信息面板开着时，翻页要同步刷新详情（否则会一直显示上一张的 EXIF）
        if showInfo { loadDetail() }
        scheduleIdleHide()
    }

    private func preloadNeighbors() {
        let list = photos
        let idx = index
        for delta in 1...3 {
            for i in [idx - delta, idx + delta] where list.indices.contains(i) {
                guard let url = list[i].fullURL else { continue }
                Task.detached(priority: .userInitiated) {
                    _ = await ImageCache.shared.load(from: url, cacheToDisk: false)
                }
            }
        }
    }

    // MARK: - UI 自动隐藏

    private func toggleUI() {
        withAnimation(.easeOut(duration: 0.2)) { showUI.toggle() }
        if showUI { scheduleIdleHide() } else { idleTask?.cancel() }
    }

    private func scheduleIdleHide() {
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showUI = false }
        }
    }

    private func showTip(_ text: String) {
        tip = text
        tipTask?.cancel()
        tipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { tip = nil }
        }
    }

    // MARK: - 收藏 / 保存

    @MainActor
    private func loadFavorite() async {
        guard let client, let photo else { return }
        do {
            isFavorite = try await client.fetchFavorite(type: "photo", id: photo.id)
        } catch {
            isFavorite = false
        }
    }

    private func toggleFavorite() {
        guard let photo else { return }
        let next = !isFavorite
        isFavorite = next
        Task { @MainActor in
            guard let client else { return }
            do {
                isFavorite = try await client.setFavorite(type: "photo", id: photo.id, on: next)
            } catch {
                isFavorite = next
                showTip("收藏失败")
            }
        }
    }

    private func saveToAlbum() {
        guard let url = photo?.fullURL else { return }
        Task { @MainActor in
            guard let image = await ImageCache.shared.load(from: url, cacheToDisk: false) else {
                showTip("图片还没加载好")
                return
            }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            showTip("已保存到相册")
        }
    }

    // MARK: - 顶部栏

    private func topBar() -> some View {
        ZStack(alignment: .top) {
            HStack(alignment: .center) {
                Text("\(index + 1) / \(photos.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: Capsule())

                Spacer()

                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.35), in: Circle())
                }
            }
            .padding(.horizontal, 16)
            // ⚠️ 横幅紧贴屏幕顶部，不再用 safe.top 避让。状态栏已 statusBarHidden，
            // 但灵动岛机型的 safe.top 仍返回挖孔高度，会把横幅推到顶部以下一大块，
            // 中间露出黑边。改为固定小间距贴顶。
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(showUI ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: showUI)
        .allowsHitTesting(showUI)
    }

    // MARK: - 信息面板（图片详情卡片）

    /// 异步拉取当前图片的详情（EXIF / AI 标注），翻页或点信息按钮时调用。
    private func loadDetail() {
        guard let client, let photo else { return }
        // 已加载过同一张，直接复用，避免重复请求
        if photoDetail?.id == photo.id { return }
        detailTask?.cancel()
        photoDetail = nil
        isLoadingDetail = true
        detailTask = Task { @MainActor in
            do {
                photoDetail = try await client.fetchPhotoDetail(id: photo.id)
            } catch {
                photoDetail = nil
            }
            isLoadingDetail = false
        }
    }

    /// 加载人脸检测结果
    private func loadFaces() {
        guard let client, let photo, !facesLoading else { return }
        facesLoading = true
        Task { @MainActor in
            do {
                faces = try await client.fetchPhotoFaces(photoId: photo.id)
            } catch {
                faces = []
            }
            facesLoading = false
        }
    }

    /// 加载相似图片（method: phash | clip）
    private func loadSimilar(method: String) {
        guard let client, let photo else { return }
        similarMethod = method
        similarLoading = true
        similarPhotos = []
        Task { @MainActor in
            do {
                similarPhotos = try await client.fetchSimilarPhotos(photoId: photo.id, method: method)
            } catch {
                similarPhotos = []
            }
            similarLoading = false
        }
    }

    /// 进入所在相册：先关详情 sheet，再关闭看图器 + 通过全局 presenter 让 RootView 跳转。
    private func openInAlbum(_ albumRef: PhotoDetail.AlbumRef, libID: Int) {
        showInfo = false
        var album = Album(id: albumRef.id)
        album.folderName = albumRef.folderName ?? ""
        PhotoViewerPresenter.shared.openAlbum(album, libID: libID)
    }

    private func detailSheet(_ photo: Photo) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 功能按钮：人脸 / 像素相似 / 语义相似
                    HStack(spacing: 8) {
                        actionButton("人脸", active: showFaces) {
                            withAnimation { showFaces.toggle() }
                            if showFaces && faces.isEmpty { loadFaces() }
                        }
                        actionButton("像素相似", active: showSimilar && similarMethod == "phash") {
                            if showSimilar && similarMethod == "phash" {
                                withAnimation { showSimilar = false }
                            } else {
                                withAnimation { showSimilar = true }
                                loadSimilar(method: "phash")
                            }
                        }
                        actionButton("语义相似", active: showSimilar && similarMethod == "clip") {
                            if showSimilar && similarMethod == "clip" {
                                withAnimation { showSimilar = false }
                            } else {
                                withAnimation { showSimilar = true }
                                loadSimilar(method: "clip")
                            }
                        }
                    }

                    // 相似图片结果
                    if showSimilar { similarSection }

                    // 人脸列表
                    if showFaces { facesSection }

                    // 基本信息
                    sectionTitle("基本信息")
                    VStack(spacing: 6) {
                        infoRow("ID", "\(photo.id)")
                        infoRow("文件名", photo.fileName ?? "")
                        infoRow("大小", photo.sizeText ?? "未知")
                        if let px = imagePixelSize {
                            infoRow("尺寸", String(format: "%.0f × %.0f", px.width, px.height))
                        } else if let dimension = photo.dimensionText {
                            infoRow("尺寸", dimension)
                        }
                        if let d = photoDetail {
                            infoRow("缩略图", d.hasThumb ? "已生成" : "未生成")
                        }
                    }

                    // 拍摄信息（EXIF）
                    if let d = photoDetail, hasShootInfo(d) {
                        sectionTitle("拍摄信息")
                        VStack(spacing: 6) {
                            if let t = d.takenAt, !t.isEmpty { infoRow("拍摄时间", t) }
                            let cam = [d.cameraMake, d.cameraModel]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                            if !cam.isEmpty { infoRow("相机", cam) }
                            if let f = d.focalLength, f > 0 { infoRow("焦距", "\(f) mm") }
                            if let a = d.aperture, a > 0 { infoRow("光圈", "f/\(a)") }
                            if let iso = d.iso, iso > 0 { infoRow("ISO", "\(iso)") }
                            if let lat = d.gpsLat, let lng = d.gpsLng {
                                infoRow("GPS", String(format: "%.6f, %.6f", lat, lng))
                            }
                        }
                    }

                    // AI 分析
                    if let d = photoDetail, d.aestheticScore != nil || !(d.aiCaption ?? "").isEmpty {
                        sectionTitle("AI 分析")
                        VStack(alignment: .leading, spacing: 8) {
                            if let score = d.aestheticScore {
                                HStack(spacing: 8) {
                                    Text("美学评分")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    ProgressView(value: min(score / 10.0, 1.0))
                                        .tint(.orange)
                                    Text(String(format: "%.2f", score))
                                        .font(.caption2.monospacedDigit())
                                }
                            }
                            if let caption = d.aiCaption, !caption.isEmpty {
                                Text(caption)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let at = d.captionAt, !at.isEmpty {
                                    Text("生成于 \(at)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // 路径信息
                    if let d = photoDetail {
                        sectionTitle("路径信息")
                        VStack(spacing: 6) {
                            infoRow("文件夹", d.folderName ?? "未知")
                            infoRow("完整路径", d.filePath)
                        }
                    }

                    // 所属信息
                    if let d = photoDetail {
                        sectionTitle("所属信息")
                        VStack(spacing: 6) {
                            infoRow("媒体库", d.library.map { "\($0.name) (\($0.type))" } ?? "未知")
                            if let albumRef = d.album, let libRef = d.library {
                                HStack(spacing: 10) {
                                    Text("相册")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Text("\(albumRef.folderName ?? "") (\(albumRef.photoCount ?? 0) 张)")
                                        .font(.caption2)
                                    Spacer()
                                    Button {
                                        openInAlbum(albumRef, libID: libRef.id)
                                    } label: {
                                        Text("进入")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Theme.brand)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Theme.brand.opacity(0.15), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                infoRow("相册", d.album.map { "\($0.folderName ?? "") (\($0.photoCount ?? 0) 张)" } ?? "未知")
                            }
                        }
                    }

                    if photoDetail == nil && isLoadingDetail {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("加载详情…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("图片详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showInfo = false }
                }
            }
        }
    }

    /// 拍摄信息区块是否有内容（对标网页版：任一 EXIF 字段存在即显示）
    private func hasShootInfo(_ d: PhotoDetail) -> Bool {
        (d.takenAt?.isEmpty == false) ||
        (d.cameraMake?.isEmpty == false) || (d.cameraModel?.isEmpty == false) ||
        d.focalLength != nil || d.aperture != nil || d.iso != nil ||
        (d.gpsLat != nil && d.gpsLng != nil)
    }

    /// 功能按钮（人脸 / 像素相似 / 语义相似）
    private func actionButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(active ? Theme.brand : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? Theme.brand.opacity(0.15) : Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 相似图片结果网格
    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if similarLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("搜索中…").font(.caption).foregroundStyle(.secondary)
                }
            } else if similarPhotos.isEmpty {
                Text(similarMethod == "phash"
                     ? "未找到相似图片"
                     : "未找到语义相似图片（可能该图未生成 CLIP embedding）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                    ForEach(similarPhotos) { sp in
                        Button {
                            // 相似图在当前列表里则跳转（先关 sheet，看图器翻页后可按需再开）
                            if let idx = photos.firstIndex(where: { $0.id == sp.id }) {
                                showInfo = false
                                index = idx
                                resetTransform()
                                imagePixelSize = nil
                            }
                        } label: {
                            ViewerThumb(url: client?.makeURL("/photo", queryItems: [
                                URLQueryItem(name: "id", value: "\(sp.id)"),
                                URLQueryItem(name: "size", value: "600"),
                            ]))
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(alignment: .bottom) {
                                if let score = sp.scoreText {
                                    Text(score)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.black.opacity(0.65))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                        .padding(3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 人脸列表网格
    private var facesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if facesLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("检测中…").font(.caption).foregroundStyle(.secondary)
                }
            } else if faces.isEmpty {
                Text("该图片未检测到人脸").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                    ForEach(faces) { face in
                        VStack(spacing: 2) {
                            ViewerThumb(url: client?.faceThumbURL(face.id))
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(face.scoreText)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    /// 详情卡片里的一行「标签 + 值」
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 底部工具栏

    private func bottomBar(bottomInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                toolButton("minus.magnifyingglass") { zoom(by: 1 / 1.25) }
                toolButton("plus.magnifyingglass") { zoom(by: 1.25) }
                toolButton("aspectratio") { withAnimation { resetTransform() } }
                toolButton("1.magnifyingglass") { fitNative() }
                divider
                toolButton("rotate.left") { withAnimation { rotation -= 90 } }
                toolButton("rotate.right") { withAnimation { rotation += 90 } }
                divider
                toolButton("square.grid.3x3.fill", active: showThumbs) {
                    withAnimation { showThumbs.toggle() }
                    // 保险：开关缩略图条时确保工具栏在，关闭入口随时可见
                    showUI = true
                    scheduleIdleHide()
                }
                toolButton("info.circle") {
                    showInfo = true
                    loadDetail()
                }
                toolButton(isFavorite ? "heart.fill" : "heart", active: isFavorite, tint: .red) {
                    toggleFavorite()
                }
                toolButton("square.and.arrow.down") { saveToAlbum() }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // 按钮内容避开 home indicator 触摸条；背景渐变在 padding 外、延伸到屏幕底
            .padding(.bottom, bottomInset)
            .background(
                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.55)],
                               startPoint: .bottom, endPoint: .top)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(showUI ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: showUI)
        .allowsHitTesting(showUI)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private func toolButton(_ systemName: String, active: Bool = false, tint: Color = Theme.brand,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(active ? tint : Color.white)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 缩略图条

    private var thumbStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(indexedPhotos) { entry in
                        Button {
                            index = entry.index
                            resetTransform()
                            imagePixelSize = nil
                        } label: {
                            ViewerThumb(url: entry.photo.thumbURL ?? entry.photo.fullURL)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(entry.index == index ? Color.blue : .clear, lineWidth: 2)
                                }
                                .opacity(entry.index == index ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .id(entry.index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)  // ⚠️ 固定高度：ScrollView 在 overlay 里会被提议全屏高，不加就会撑满、纯黑背景盖住图片/按钮并吃掉点击
            .background(Color.black)  // 纯黑不透明，避免半透明蒙层透出底图
            .onAppear { scrollStrip(proxy) }
            .onChange(of: index) { _, _ in scrollStrip(proxy) }
        }
    }

    /// 缩略图条需要「下标 + 照片」，用一个显式 Identifiable 包装，
    /// 避免 ForEach 直接遍历 enumerated() 元组带来的下标解构歧义
    private var indexedPhotos: [IndexedPhoto] {
        photos.enumerated().map { IndexedPhoto(index: $0.offset, photo: $0.element) }
    }

    private func scrollStrip(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(index, anchor: .center) }
        }
    }

    // MARK: - 提示

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - 显示尺寸计算
//
// iOS 版 iPad 竖屏容器宽高比约 820/1180 ≈ 0.695。默认 .fit 会把图片完整塞进容器，
// 于是 3:4 竖图（0.75）得到 820×1093 —— 上下各留 ~43pt 黑边；2:3 竖图（0.667）
// 得到 787×1180 —— 宽度比屏幕窄一截。两种都「不满屏」。
//
// 对策：竖图 + 竖屏时改用 .fill（等比放大到铺满，溢出部分裁掉），
// 可见宽度恒等于屏宽、上下不留黑边。但裁切比例超过 20% 的超长图（9:16 长截图等）
// 仍然走 .fit，否则一张图会被切掉一大截。
fileprivate struct ViewerFit {
    /// scale = 1 时图片的显示宽度
    let width: CGFloat
    let mode: ContentMode
}

fileprivate func viewerFit(image px: CGSize, container box: CGSize) -> ViewerFit? {
    guard px.width > 0, px.height > 0, box.width > 0, box.height > 0 else { return nil }
    let aspect = px.width / px.height
    let boxAspect = box.width / box.height

    // fit：宽度受限时取屏宽，否则按高度反推
    let fitWidth: CGFloat = aspect >= boxAspect ? box.width : box.height * aspect

    // 仅「竖图 + 竖屏」才考虑铺满
    if aspect < 1, boxAspect < 1, fitWidth > 0 {
        let fillWidth: CGFloat = max(box.width, box.height * aspect)
        if fillWidth / fitWidth <= 1.25 {
            return ViewerFit(width: fillWidth, mode: .fill)
        }
    }
    return ViewerFit(width: fitWidth, mode: .fit)
}

// MARK: - 单张图（原图加载 + 缩略图占位 + 重试回退）

struct ViewerImageView: View {
    let photo: Photo
    /// 容器（即整屏）尺寸，用来决定 fit / fill 并把图撑到屏宽
    var containerSize: CGSize = .zero
    /// 已旋转 90°/270°：图片实际朝向与原始像素相反，此时一律走 fit，避免裁切加剧
    var rotated: Bool = false
    var onLoaded: ((CGSize) -> Void)? = nil

    @State private var image: UIImage?
    @State private var placeholder: UIImage?
    @State private var isLoading = false
    @State private var showSpinner = false
    @State private var retries = 0
    /// 原图连试 3 次仍失败 → 退回缩略图（同网页版 onError 分支）
    @State private var fallBackToThumb = false

    var body: some View {
        ZStack {
            if let image {
                imageContent(image)
            } else if let placeholder {
                imageContent(placeholder)
            }
            if showSpinner {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white.opacity(0.7))
            }
        }
        .task(id: photo.id) { await load() }
    }

    /// 撑满容器再按 fit / fill 摆放。
    /// ⚠️ 不能直接写 resizable().scaledToFill() 而不给 frame —— resizable 后 Image
    /// 的 ideal size 就是原图像素尺寸（动辄 3000×4000），没有 frame 约束会按原尺寸渲染。
    @ViewBuilder
    private func imageContent(_ img: UIImage) -> some View {
        // 旋转 90°/270° 后朝向翻转，按翻转后的尺寸判定，避免竖图旋转后被过度裁切
        let px = rotated
            ? CGSize(width: img.size.height, height: img.size.width)
            : img.size
        if let fit = viewerFit(image: px, container: containerSize) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: fit.mode)
                .frame(width: containerSize.width, height: containerSize.height)
                // fill 时超出容器的部分由这里裁掉（外层 imageLayer 也有一道 .clipped()）
                .clipped()
        } else {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        }
    }

    @MainActor
    private func load() async {
        image = nil
        showSpinner = false
        isLoading = true

        // 网格刚加载过，缩略图通常已在内存里，先顶上避免白屏
        if let thumbURL = photo.thumbURL {
            placeholder = ImageCache.shared.image(for: thumbURL)
        }

        let url = (fallBackToThumb ? photo.thumbURL : photo.fullURL) ?? photo.thumbURL
        guard let url else { isLoading = false; return }

        if let cached = ImageCache.shared.image(for: url) {
            finish(cached)
            return
        }

        // 同网页版：800ms 内加载完就不显示转圈，避免快速翻页闪一下
        let spinner = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if isLoading { showSpinner = true }
        }

        // 原图不落盘（后端本来就是源文件，再存一份会撑爆缓存目录）
        let loaded = await ImageCache.shared.load(from: url, cacheToDisk: fallBackToThumb)
        spinner.cancel()

        if let loaded {
            finish(loaded)
            return
        }

        isLoading = false
        showSpinner = false
        guard retries < 3 else {
            if !fallBackToThumb { fallBackToThumb = true; await load() }
            return
        }
        retries += 1
        try? await Task.sleep(nanoseconds: 800_000_000)
        await load()
    }

    @MainActor
    private func finish(_ img: UIImage) {
        image = img
        isLoading = false
        showSpinner = false
        onLoaded?(img.size)
    }
}

// MARK: - 缩略图条用图

private struct IndexedPhoto: Identifiable {
    let index: Int
    let photo: Photo
    var id: Int { photo.id }
}

private struct ViewerThumb: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .task(id: url?.absoluteString ?? "") {
            guard let url, image == nil else { return }
            image = await ImageCache.shared.load(from: url)
        }
    }
}
