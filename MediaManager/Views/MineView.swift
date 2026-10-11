import SwiftUI

// MARK: - 「我的」里的完整列表路由
// 四个 tab 各自一个 NavigationStack，push 目标只能声明在自己的栈里，
// 所以用一个 Hashable 路由值 + navigationDestination，而不是全局路径。
enum MineListRoute: Hashable {
    case history
    case favorite

    var title: String {
        switch self {
        case .history: return "观看记录"
        case .favorite: return "我的收藏"
        }
    }

    var action: AssetActionKind {
        switch self {
        case .history: return .history
        case .favorite: return .favorite
        }
    }

    var emptyText: String {
        switch self {
        case .history: return "还没有观看记录\n看过的影视会记在这里，方便回头接着找"
        case .favorite: return "还没有收藏\n在详情里点收藏，就会收进这里"
        }
    }
}

// MARK: - 我的
// 之前 iOS 端没有任何「我是谁 / 连的哪台服务器」的入口，也**没有退出登录** ——
// 想换账号只能杀 App 重进。这个 tab 补上账户区，同时把首页的「继续观看 /
// 观看记录 / 收藏」这些私人数据收拢到这里，首页回到「找内容」的定位。
struct MineView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject private var session = AppSession.shared
    /// 外观设置：这里只用来显示当前主题名（「跟随系统 / 浅色 / 深色」）
    @ObservedObject private var appearance = AppearanceSettings.shared

    @State private var pending: PlaybackRequest?
    @State private var playError: String?
    @State private var showingPhotos = false
    @State private var confirmingLogout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                profileCard

                if !viewModel.resume.isEmpty {
                    section("clock.fill", "继续观看") { resumeRow }
                }
                if !viewModel.history.isEmpty {
                    section("clock.arrow.circlepath", "观看记录", route: .history) { historyRow }
                }
                if !viewModel.favorites.isEmpty {
                    section("heart.fill", "我的收藏", route: .favorite) { favoritesRow }
                }

                settingsSection
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
        }
        .appBackground()
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load(showSpinner: false) }
        // 与首页共用一份 viewModel：谁先挂载谁触发加载（HomeViewModel 里有闸）
        .task { await viewModel.loadIfNeeded() }
        .navigationDestination(for: MineListRoute.self) { route in
            ActionAssetListView(route: route)
        }
        .sheet(isPresented: $showingPhotos) {
            // sheet 里的照片页必须用本地 fullScreenCover 看图器：
            // 全局 overlay 在 RootView 层，会被这个 sheet 盖住看不见
            NavigationStack { PhotoBrowserView(useGlobalViewer: false) }
        }
        .alert("无法播放", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好", role: .cancel) { playError = nil }
        } message: {
            Text(playError ?? "")
        }
        .fullScreenCover(item: $pending) { request in
            PlayerHostView(request: request)
        }
    }

    // MARK: 账户卡

    private var profileCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.brand.opacity(0.16))
                Image(systemName: "person.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.headline)
                Text("@\(session.user?.username ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(session.user?.isAdmin == true ? "管理员" : "用户")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.brand)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.brand.opacity(0.14), in: Capsule())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var displayName: String {
        if let n = session.user?.displayName, !n.isEmpty { return n }
        return session.user?.username ?? "未登录"
    }

    // MARK: 区块

    private var resumeRow: some View {
        horizontalRow {
            ForEach(viewModel.resume) { asset in
                ResumeCard(asset: asset) { handleAssetTap(asset) }
            }
        }
    }

    private var historyRow: some View {
        horizontalRow {
            ForEach(viewModel.history) { asset in
                AssetPosterCard(asset: asset) { handleAssetTap(asset) }
            }
        }
    }

    private var favoritesRow: some View {
        horizontalRow {
            ForEach(viewModel.favorites) { asset in
                AssetPosterCard(asset: asset) { handleAssetTap(asset) }
            }
        }
    }

    /// 区块容器：标题行（可选「查看全部」）+ 横滑卡片行
    @ViewBuilder
    private func section<Content: View>(_ icon: String,
                                        _ title: String,
                                        route: MineListRoute? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(title)
                    .font(.title3.weight(.semibold))

                Spacer()

                if let route {
                    NavigationLink(value: route) {
                        HStack(spacing: 3) {
                            Text("查看全部")
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            content()
        }
    }

    /// 统一的行容器：卡片各自固定尺寸，横向滚动
    @ViewBuilder
    private func horizontalRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16, content: content)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
    }

    // MARK: 设置 / 退出

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("设置")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                settingsRow(icon: "network", title: "服务器", value: session.baseURL?.absoluteString ?? "—")
                Divider().padding(.leading, 44)
                settingsRow(icon: "person.circle", title: "账号",
                            value: session.user?.username ?? "—")
                Divider().padding(.leading, 44)
                // 主题模式 + 背景图。用 destination 版 NavigationLink，
                // 不用再给 MineListRoute 加 case（那个枚举只管「完整列表」路由）。
                // ⚠️ 非 List 环境下 NavigationLink 不会自带 chevron，自己补一个，
                // 否则看不出这一行能点进去
                NavigationLink {
                    AppearanceView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paintbrush")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 20)
                        Text("外观")
                            .font(.subheadline)
                        Spacer()
                        Text(appearance.mode.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
            .appSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button(role: .destructive) {
                confirmingLogout = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("退出登录")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            // ⚠️ 退出登录必须二次确认：一点就退会让人以为 App 崩了，
            // 而且退掉之后要重新输账号密码才能回来。
            // alert 挂在按钮上而不是整个 ScrollView 上 —— 同一层挂两个 alert
            // （这里还有「无法播放」）时 SwiftUI 只会认其中一个。
            .alert("退出登录", isPresented: $confirmingLogout) {
                Button("退出", role: .destructive) {
                    Task { @MainActor in session.logout() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后需要重新连接服务器才能继续使用。服务器地址会保留，下次登录直接预填。")
            }
        }
    }

    private func settingsRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    // MARK: 交互

    private func handleAssetTap(_ asset: UnifiedAsset) {
        guard let path = asset.playablePath else {
            if asset.type == .photo {
                showingPhotos = true
            } else {
                playError = "《\(asset.title)》没有可播放的文件路径"
            }
            return
        }
        pending = PlaybackRequest(path: path,
                                  title: asset.title,
                                  assetType: asset.type.rawValue,
                                  assetID: asset.id,
                                  startAt: asset.position,
                                  knownDuration: asset.duration)
    }
}

// MARK: - 完整列表（观看记录 / 我的收藏）
// 「我的」页里横滑行只能放一屏，点「查看全部」进来这里翻全量。
struct ActionAssetListView: View {
    let route: MineListRoute

    @StateObject private var viewModel: ActionAssetListViewModel
    @State private var pending: PlaybackRequest?
    @State private var playError: String?
    @State private var showingPhotos = false

    init(route: MineListRoute) {
        self.route = route
        _viewModel = StateObject(wrappedValue: ActionAssetListViewModel(action: route.action))
    }

    var body: some View {
        GeometryReader { geo in
            let grid = gridLayout(containerWidth: geo.size.width)
            ScrollView {
                if viewModel.items.isEmpty {
                    // 空态只在加载完还没数据的时候显示，别和首屏 loading 打架
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else {
                        emptyState
                    }
                } else {
                    LazyVGrid(columns: grid.columns, spacing: 18) {
                        ForEach(viewModel.items.indices, id: \.self) { i in
                            AssetPosterCard(asset: viewModel.items[i], width: grid.itemWidth) {
                                handleAssetTap(viewModel.items[i])
                            }
                            .task {
                                // 触底加载下一页。用下标判断而不是 last?.id：
                                // 四类内容的 id 各自编号，跨类型会撞（media 3 和 photo 3 都有）
                                if i == viewModel.items.count - 1 {
                                    await viewModel.loadMore()
                                }
                            }
                        }
                    }
                    .padding(16)

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
        }
        .appBackground()
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadIfNeeded() }
        .refreshable { await viewModel.reload() }
        .sheet(isPresented: $showingPhotos) {
            // sheet 里的照片页必须用本地 fullScreenCover 看图器：
            // 全局 overlay 在 RootView 层，会被这个 sheet 盖住看不见
            NavigationStack { PhotoBrowserView(useGlobalViewer: false) }
        }
        .alert("无法播放", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好", role: .cancel) { playError = nil }
        } message: {
            Text(playError ?? "")
        }
        .fullScreenCover(item: $pending) { request in
            PlayerHostView(request: request)
        }
    }

    /// 卡片宽度按容器均分（对齐 MediaListView 的做法）：
    /// 用 adaptive(minimum:) 时列宽会大于卡片固定宽，卡片居中留白，看起来像间距过大
    private func gridLayout(containerWidth: CGFloat) -> (columns: [GridItem], itemWidth: CGFloat) {
        let spacing: CGFloat = 18
        let padding: CGFloat = 16
        let gridW = max(containerWidth - padding * 2, 0)
        let cardW: CGFloat = 150
        let n = max(2, Int((gridW + spacing) / (cardW + spacing)))
        let itemW = (gridW - spacing * CGFloat(n - 1)) / CGFloat(n)
        let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: n)
        return (cols, itemW)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: route == .history ? "clock.arrow.circlepath" : "heart")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(route.emptyText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
        .padding(.horizontal, 32)
    }

    private func handleAssetTap(_ asset: UnifiedAsset) {
        guard let path = asset.playablePath else {
            if asset.type == .photo {
                showingPhotos = true
            } else {
                playError = "《\(asset.title)》没有可播放的文件路径"
            }
            return
        }
        pending = PlaybackRequest(path: path,
                                  title: asset.title,
                                  assetType: asset.type.rawValue,
                                  assetID: asset.id,
                                  startAt: asset.position,
                                  knownDuration: asset.duration)
    }
}
