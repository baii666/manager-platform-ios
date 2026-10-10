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

    // 1:1 需要「图片像素尺寸」与「容器尺寸」
    @State private var imagePixelSize: CGSize?
    @State private var containerSize: CGSize = .zero

    @State private var isFavorite = false
    @State private var idleTask: Task<Void, Never>?
    @State private var tipTask: Task<Void, Never>?

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
            ZStack {
                Color.black.opacity(backgroundOpacity)

                imageLayer(size: geo.size)

                // 缩略图条：贴顶，且让开顶部栏那一行
                //
                // ⚠️ 这里的 frame 不能省。内层 ZStack(alignment:.top) 只决定「它自己的子视图」
                // 怎么对齐，它本身在外层 ZStack 里仍按默认 .center 摆放 —— 不显式撑满并贴顶，
                // 整条缩略图会浮在画面正中：既盖住图片，又会吃掉 imageLayer 的点击
                // （toggleUI）和下拉关闭手势，表现成「挡住图且退不出去」。
                ZStack(alignment: .top) {
                    if showThumbs { thumbStrip }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 52 + safe.top)

                topBar(topInset: safe.top)
                if showInfo, let photo { infoPanel(photo, topInset: safe.top) }
                bottomBar(bottomInset: safe.bottom)
                if let tip { toast(tip) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { containerSize = geo.size }
            .onChange(of: geo.size) { _, new in containerSize = new }
        }
        // ⚠️ 底部黑边根因：GeometryReader 默认遵守 safe area，图片层只画到
        // home indicator 上沿，底下露出黑色背景。ignore 后 geo.size = 全屏，
        // 图片真正铺满整屏；顶栏/底栏用 safeAreaInsets 手动避让。
        .ignoresSafeArea()
        .statusBarHidden(true)
        .task(id: index) { await didChangeIndex() }
        .onAppear { scheduleIdleHide() }
        .onDisappear { idleTask?.cancel(); tipTask?.cancel() }
    }

    // MARK: - 图片层

    private func imageLayer(size: CGSize) -> some View {
        ZStack {
            if let photo {
                singleImage(photo, size: size, extraOffsetX: trackOffset)

                // 连续翻页：横向拖动时把相邻那张也挂出来跟手一起滑，
                // 松手后两张一起滑到位，而不是「旧图瞬间换新图」的生硬切换。
                if scale <= 1.01 {
                    if trackOffset < 0, index + 1 < photos.count {
                        singleImage(photos[index + 1], size: size, extraOffsetX: trackOffset + size.width)
                    } else if trackOffset > 0, index - 1 >= 0 {
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
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) * 1.2 >= abs(dy) {
                    if abs(dx) > width * 0.15 {
                        go(dx < 0 ? 1 : -1)
                    } else {
                        withAnimation(.easeOut(duration: 0.28)) { trackOffset = 0 }
                    }
                } else if abs(dy) > 150 {
                    close(after: dy)
                } else {
                    withAnimation(.easeOut(duration: 0.32)) { dismissY = 0 }
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

    private func go(_ delta: Int) {
        let next = index + delta
        if next < 0 {
            withAnimation(.easeOut(duration: 0.28)) { trackOffset = 0 }
            return
        }
        if next >= photos.count {
            if hasMore { onLoadMore?() }
            withAnimation(.easeOut(duration: 0.28)) { trackOffset = 0 }
            return
        }
        // 两图连续翻页：先把当前图连同相邻图一起滑到目标位置，动画结束后再切 index
        let width = containerSize.width
        let target = delta > 0 ? -width : width
        withAnimation(.easeOut(duration: 0.28)) { trackOffset = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.29) {
            trackOffset = 0
            index = next
            resetTransform()
            imagePixelSize = nil
        }
    }

    private func close(after dy: CGFloat = 0) {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeOut(duration: 0.32)) { dismissY = dy > 0 ? 1600 : -1600 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { onClose() }
    }

    private var backgroundOpacity: Double {
        guard dismissY != 0 else { return 1 }
        return max(CGFloat(0.15), CGFloat(1) - abs(dismissY) / CGFloat(900))
    }

    @MainActor
    private func didChangeIndex() async {
        resetTransform()
        await loadFavorite()
        preloadNeighbors()
        if hasMore, index >= photos.count - 3 { onLoadMore?() }
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

    private func topBar(topInset: CGFloat) -> some View {
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
            .padding(.top, 8 + topInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(showUI ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: showUI)
        .allowsHitTesting(showUI)
    }

    // MARK: - 信息面板

    private func infoPanel(_ photo: Photo, topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(photo.fileName ?? "#\(photo.id)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                if let px = imagePixelSize {
                    Text(String(format: "%.0f × %.0f", px.width, px.height))
                } else if let dimension = photo.dimensionText {
                    Text(dimension)
                }
                if let size = photo.sizeText { Text(size) }
                Text("ID: \(photo.id)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 16)
        .padding(.top, 60 + topInset)
        .opacity(showUI ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: showUI)
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
                toolButton("info.circle", active: showInfo) {
                    withAnimation { showInfo.toggle() }
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
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55))
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
