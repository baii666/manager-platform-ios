import SwiftUI
import UIKit

// MARK: - 取消类错误（列表加载通用）
/// URLSession 的 async 请求在所属 Task 被取消时抛 URLError(.cancelled)，
/// localizedDescription 正是 "cancelled"。SwiftUI 的 .task / .refreshable 会随
/// cell 复用、列表重绘、页面切走、下拉中途松手取消 Task —— 这是正常生命周期事件，
/// 不能写进 errorMessage：旧实现下拉刷新先清空列表，取消后整页就只剩
/// 「加载失败 · cancelled」。
private func isExpectedCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
    return Task.isCancelled
}

// MARK: - 人物页（人脸聚类）
// 对齐网页端 PersonsPage：人物网格（代表脸头像 + 姓名 + 照片数），点进看该人物的全部照片。
// 入口：相册列表页顶部「人物」行、首页发现区「人物」卡。
// ⚠️ 人物是跨媒体库的全局聚类（face_cluster_persons_* 分表），不属于任何一个库，
// 所以本页自己拉数据，不挂任何库/排序状态。
struct PersonsView: View {
    /// 嵌进「人物」聚合页（PeopleHubView）时由外层统一铺背景与标题。
    var embedded: Bool = false
    @StateObject private var viewModel = PersonsViewModel()

    /// iPad 卡片更大（对齐网页版人物资料页的大卡观感）
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        VStack(spacing: 0) {
            // 「人物」tab 的系统导航栏是收起来的（顶栏只放分段胶囊），所以搜索框
            // 画在内容区，与「影视演员」分段的 inlineControlBar 同行高、同款淡底胶囊。
            searchBar

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: hSizeClass == .regular ? 210 : 150), spacing: 14)], spacing: 14) {
                    ForEach(viewModel.items) { person in
                        NavigationLink(value: person) {
                            PersonCard(person: person, profile: viewModel.profileFacts[person.id])
                        }
                        .buttonStyle(.plain)
                        // ⚠️ 别用 .task：SwiftUI 会在 cell 复用 / items 重绘时取消它，
                        // 连带取消正在跑的 URLSession 请求（URLError.cancelled），
                        // 于是滑到底那一页静默丢掉、还写一条 cancelled 错误。
                        // 改 onAppear + 非结构化 Task，去重交给 VM 的 isLoading。
                        .onAppear {
                            if person.id == viewModel.items.last?.id {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    }
                }
                .padding(16)
                .bottomBarClearance()
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            // ⚠️ .refreshable 必须挂在 ScrollView 上，不能挪到外层 VStack
            .refreshing { await viewModel.reload() }
        }
        // 嵌进「人物」聚合页时不写标题：顶栏交给外层那段「照片人物 / 影视演员」分段，
        // 独立从相册页 push 进来时才需要「人物」标题
        .navigationTitle(embedded ? "" : "人物")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 每个 push 进来的页面都要自己垫一层背景：NavigationStack 只渲染栈顶那一层。
        // 嵌进「人物」聚合页时由外层统一铺，否则背景图模式会压暗两次。
        .background { if !embedded { AppBackgroundView() } }
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? (viewModel.searchText.isEmpty ? "暂无人物" : "没有匹配的人物"),
                    systemImage: viewModel.errorMessage == nil
                        ? (viewModel.searchText.isEmpty ? "person.2.fill" : "magnifyingglass")
                        : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadInitial() }
        // 档案资料独立拉一次，失败不影响列表
        .task { await viewModel.loadFacts() }
        // 搜索防抖交给 VM 的可取消任务：连续输入只发最后一次请求。
        // 后端 /api/persons 单次约 3s，旧实现每个字符都发一发，会堆成一串慢请求。
        .onChange(of: viewModel.searchText) { viewModel.scheduleSearch() }
        // 🔴 这里不注册 navigationDestination：本页只作为「人物」tab 的
        // TabView(.page) 分页使用，page 内部注册的路由不会生效（点了没反应），
        // Person 的路由统一由外层 PeopleHubView 注册。若将来要独立使用本页，
        // 记得在调用方的 NavigationStack 里补 for: Person.self。
    }

    /// 内容区搜索行：后端 `/api/persons?q=` 按簇名模糊匹配，右侧显示命中总数。
    /// 布局和演员分段的 inlineControlBar 对齐（左右 16、下 8、胶囊高 32）。
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("搜索人物名…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

            if viewModel.totalCount > 0 {
                Text("\(viewModel.totalCount) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - 人物卡
// 对齐网页版人物资料页 ProfileCard：封面原生 3:4 完整显示，
// 图上左上「N 脸」黑胶囊、右上相似度胶囊；图下名字一行 + 出生/身高并排一行。
// 卡片边界只是一条 0.5pt 细描边 + 薄底板，不是厚边框。
private struct PersonCard: View {
    let person: Person
    /// 已挂档案的资料（无档案传 nil，卡片就不显示资料行 / 相似度）
    var profile: PersonProfile? = nil

    /// 与网页版人物列表一致：簇名优先，簇名为空才回退到档案名（thenude_name），
    /// 再没有才显示占位。不能用 profile.displayName——那是「档案名优先」，口径相反。
    private var displayName: String {
        let cluster = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cluster.isEmpty { return cluster }
        let archived = (profile?.thenudeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return archived.isEmpty ? "人物 #\(person.id)" : archived
    }

    /// 与网页版同款三事实：出生 → 身高 → 出生地，取前两条并排在同一行（· 分隔）
    private var facts: [(icon: String, text: String)] {
        guard let p = profile else { return [] }
        var list: [(String, String)] = []
        if let born = p.bornText { list.append(("birthday.cake", born)) }
        if let height = p.heightText { list.append(("ruler", height)) }
        if let birth = p.birthplaceText { list.append(("mappin.and.ellipse", birth)) }
        return list.prefix(2).map { ($0.0, $0.1) }
    }

    /// 相似度胶囊底色：≥0.75 绿、≥0.62 琥珀、其余黑（网页版同规则）
    private func simColor(_ sim: Double) -> Color {
        sim >= 0.75 ? Color.green.opacity(0.75)
            : sim >= 0.62 ? Color.orange.opacity(0.75)
            : Color.black.opacity(0.55)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图区：封面原生 3:4，clear 撑比例、图 overlay 填满（object-top）
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    RemoteImage(url: personCoverURL(person), fallbackURL: personFaceURL(person),
                                fallbackIcon: "person.fill",
                                fallbackColors: Theme.placeholderGradient(for: .photo))
                        .imageFilled(alignment: .top)
                }
                .overlay(alignment: .topLeading) {
                    if person.faceCount > 0 {
                        imageCapsule("\(person.faceCount.formatted()) 脸")
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let sim = profile?.thenudeSim, sim > 0 {
                        imageCapsule("\(Int((sim * 100).rounded()))%", color: simColor(sim))
                            .padding(6)
                    }
                }

            // 文字区整块固定高度：名字一行 + 资料一行（日期/身高并排，用 · 分隔）。
            // 用显式 VStack 容器固定，不能把 .frame 加在 Group 上（Group 会把 frame
            // 传给每个子行，不同行数的卡就比别的卡高，整页网格对不齐）。
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(height: 19)

                VStack(alignment: .leading, spacing: 0) {
                    if facts.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.rectangle")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Text("\(person.faceCount.formatted()) 张人脸")
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(facts.indices, id: \.self) { i in
                                HStack(spacing: 4) {
                                    if i > 0 {
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                    }
                                    Image(systemName: facts[i].icon)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                    Text(facts[i].text)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .topLeading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .appSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 边界只是一条细线，不是厚边框
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    /// 图上的小胶囊：默认黑底白字 11 号；相似度传自定义底色
    private func imageCapsule(_ text: String,
                              color: Color = Color.black.opacity(0.55)) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

// MARK: - 人物页顶部信息区
// 固定在瀑布流上方（不随滚动）：头像 + 名字 + 作品数 / 人脸数。
// 下面的瀑布流就是「这个人物的作品」，两者用一条细分隔线隔开。
// MARK: - 人物资料共用组件（iPhone 顶部条 / iPad 左栏共用）
/// 人物封面（/person-cover），参数是簇 id —— 离线打分流程按簇产出的上半身标准肖像
private func personCoverURL(_ person: Person) -> URL? {
    AppSession.shared.client?.personCoverURL(person.id)
}

/// 封面缺失时的回退图：代表脸（/face-thumb）→ 代表照片
private func personFaceURL(_ person: Person) -> URL? {
    let client = AppSession.shared.client
    if let faceId = person.representativeFaceId { return client?.faceThumbURL(faceId) }
    if let photoId = person.representativePhotoId {
        return client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(photoId)"),
            URLQueryItem(name: "size", value: "600"),
        ])
    }
    return nil
}

/// 展开后的结构化资料。结构与网页版 PersonProfileInfo 一致：
/// 三格关键数字 → 17 项字段表 → 别名 → 收录站点 → 简介 → 外链。
/// 无档案时按网页版显示空态文案，不留一片空白。
private func personDetails(_ p: PersonProfile) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        if p.hasProfileMeta {
            // 关键数字三格：身高 / 三围 / 族裔
            HStack(spacing: 8) {
                ForEach(p.topFacts, id: \.label) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label).font(.caption2).foregroundStyle(.tertiary)
                        Text(fact.value)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            // 字段表（只显示有值的行）
            if !p.profileFields.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(p.profileFields, id: \.label) { field in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(field.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .leading)
                            Text(field.value)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // 别名 / AKA
            if let aka = p.aliasesText {
                VStack(alignment: .leading, spacing: 5) {
                    Text("别名 / AKA").font(.caption2).foregroundStyle(.tertiary)
                    Text(aka)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 收录站点（按套图数倒序，最多 18 个，与网页版一致）
            if !p.siteTags.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("收录站点 (\(p.siteTags.count))")
                        .font(.caption2).foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], spacing: 6) {
                        ForEach(p.siteTags.prefix(18), id: \.name) { site in
                            HStack(spacing: 3) {
                                Text(site.name).lineLimit(1)
                                if site.count > 0 {
                                    Text("\(site.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(Theme.brand)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.brand.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }

            // 简介
            if let desc = p.descriptionText {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("该人物尚未关联 thenude 档案")
                    .font(.caption).foregroundStyle(.secondary)
                Text("仍可查看下方图片与相册；关联判据需人工复核后才会写入")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // 外链（网页版同款两个按钮）
        if p.sourceURL != nil || p.avatarSourceURL != nil {
            HStack(spacing: 8) {
                if let url = p.sourceURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "safari").font(.system(size: 11, weight: .semibold))
                            Text("打开 thenude 档案").font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let url = p.avatarSourceURL {
                    Link(destination: url) {
                        Text("档案头像原图")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

/// 网页版 PersonProfileMediaTabs 三 tab：图片 / 相册 / 视频
private enum PersonMediaTab: String, CaseIterable, Identifiable {
    case photos = "图片"
    case albums = "相册"
    case videos = "视频"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .photos: return "photo.stack"
        case .albums: return "folder"
        case .videos: return "film"
        }
    }
}

/// 相册卡点进去用的路由：AlbumPhotosView 必须要 libID，后端相册项带 library_id。
/// 单列一个 Hashable 路由，避免给全局 Album 模型加字段影响别的页面。
struct PersonAlbumRoute: Hashable {
    let id: Int
    let libID: Int
    let name: String
    let count: Int
    let coverPhotoId: Int
}

/// 人物详情「相册」tab 的封面方向，与网页版相册列表同一口径：
/// 横版取 cover_photo_id（16:9），竖版取 cover_photo_id_portrait（2:3），缺哪边用另一边兜底。
private enum AlbumCoverOrientation: String, Equatable {
    case landscape
    case portrait
}

/// 人物照片页的排序（Photo 没有拍摄时间，能排的只有文件名与后端默认顺序）
private enum PersonPhotoSort: String, CaseIterable, Identifiable {
    case original = "默认顺序"
    case nameAsc = "文件名 ↑"
    case nameDesc = "文件名 ↓"
    var id: String { rawValue }
}

private struct PersonPhotosHeader: View {
    let person: Person
    /// 外部档案：约 96% 的聚类人物没匹配到（接口 200 但 meta 为空），
    /// 这种人物顶部保持原来的一行信息，不出现「资料」入口
    let profile: PersonProfile?
    /// 绑定父层的隐藏状态：点按钮/左滑时整张卡向左滑走
    @Binding var isHidden: Bool
    /// 后端返回的作品总数
    let total: Int
    /// 已加载条数（首批还没回来时用它兜底）
    let loaded: Int

    /// 资料默认展开；整张卡可左滑/点按钮隐藏，不是折叠详情
    @State private var expanded = true

    /// 头像优先级：封面 → 聚类代表脸 → 代表照片 → 占位图标
    private var coverURL: URL? { personCoverURL(person) }

    /// 首批还没回来时别闪一个「0 张照片」
    private var photosText: String {
        if total > 0 { return "\(total) 张照片" }
        if loaded > 0 { return "\(loaded) 张照片" }
        return "照片加载中…"
    }

    /// 对齐网页版 PersonDetailView：人脸数在前，「N 张人脸 · N 张照片」
    private var infoLine: String {
        if person.faceCount > 0 { return "\(person.faceCount) 张人脸 · \(photosText)" }
        return photosText
    }

    private var displayName: String {
        profile?.displayName ?? person.displayName
    }

    /// 收起时的一行摘要；展开后资料区已写同样内容，不重复
    private var summaryLine: String? {
        guard let p = profile else { return nil }
        let parts = [p.bornText, p.heightText, p.measurementsText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 人名在图片上方（顶栏已不再显示人名）
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let profile, profile.hasProfileMeta {
                    toggleButton
                }
                hideButton
            }

            HStack(spacing: 16) {
                RemoteImage(url: coverURL, fallbackURL: personFaceURL(person),
                            fallbackIcon: "person.fill",
                            fallbackColors: Theme.placeholderGradient(for: .photo))
                    .imageFilled(alignment: .top)
                    .frame(width: 80, height: 107)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(infoLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !expanded, let summaryLine {
                        Text(summaryLine)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }

            if expanded, let profile, profile.hasProfileMeta {
                personDetails(profile)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().frame(maxWidth: .infinity).opacity(0.6)
        }
        // 向左滑整张资料卡即隐藏（不是折叠详情），与按钮等效
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width < -60,
                       abs(value.translation.width) > abs(value.translation.height) {
                        isHidden = true
                    }
                }
        )
    }

    /// 把整张资料卡向左滑走收起
    private var hideButton: some View {
        Button(action: {
            isHidden = true
        }, label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel("隐藏资料卡")
    }

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(expanded ? "收起" : "资料")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - iPad 人物详情左资料栏（与演员详情页 profileColumn 同构，280pt）
private struct PersonSidebar: View {
    let person: Person
    let profile: PersonProfile?
    /// 绑定父层的左栏隐藏状态
    @Binding var isHidden: Bool
    let total: Int
    let loaded: Int

    /// 资料默认展开；整栏可隐藏，不是折叠详情
    @State private var expanded = true

    private var displayName: String { profile?.displayName ?? person.displayName }
    /// 对齐网页版文案：照片数（不再是「作品」）
    private var photosText: String {
        if total > 0 { return "\(total) 张照片" }
        if loaded > 0 { return "\(loaded) 张照片" }
        return "照片加载中…"
    }

    /// 与网页版一致：人脸数在前，「N 张人脸 · N 张照片」
    private var infoLine: String {
        if person.faceCount > 0 { return "\(person.faceCount) 张人脸 · \(photosText)" }
        return photosText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 人名在图片上方（顶栏不再显示人名）；隐藏按钮同行右端
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let profile, profile.hasProfileMeta {
                    Text("已挂档案")
                        .font(.caption2)
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.brand.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                Button(action: {
                    isHidden = true
                }, label: {
                    HStack(spacing: 2) {
                        Text("隐藏").font(.caption2)
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .accessibilityLabel("隐藏资料栏")
            }

            avatar.frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                Text(infoLine).font(.subheadline).foregroundStyle(.secondary)
                if let profile, profile.thenudeSim > 0 {
                    HStack(spacing: 8) {
                        Text("档案相似度").font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Text(String(format: "%.1f%%", profile.thenudeSim * 100))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(profile.thenudeSim >= 0.75 ? Color.green : Color.orange)
                    }
                }
            }

            if let profile {
                if profile.hasProfileMeta {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(expanded ? "收起资料" : "资料")
                                .font(.caption.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded { personDetails(profile) }
                } else {
                    // 网页版同款空态：没挂档案也要有明确说明，不是一片空白
                    personDetails(profile)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 头像按 /person-cover 原生 3:4（675×900）显示，不做 1:1 方裁；
    /// 宽度铺满左栏内容区（280 - 20×2 = 240），与网页版 3:4 大头像一致。
    @ViewBuilder
    private var avatar: some View {
        if let url = personCoverURL(person) {
            RemoteImage(url: url, fallbackURL: personFaceURL(person),
                        fallbackIcon: "person.fill",
                        fallbackColors: Theme.placeholderGradient(for: .photo))
                .imageFilled(alignment: .top)
                .frame(width: 240, height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.brand.opacity(0.16))
                .frame(width: 240, height: 320)
                .overlay {
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.system(size: 72, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
        }
    }
}

// MARK: - 人物照片页
// 某个聚类人物的全部照片。复用全局看图器（PhotoViewerPresenter）——
// 与相册内照片页同一套呈现，翻页加载后同步 updatePhotos。
struct PersonPhotosView: View {
    let person: Person

    @State private var photos: [Photo] = []
    /// 瀑布流列数：双指捏合缩放，按「人物照片页」记忆
    @State private var columns = PhotoGridPrefs.load("personPhotos", fallback: 4)
    @State private var isLoading = false
    @State private var page = 1
    @State private var hasMore = true
    @State private var errorMessage: String?
    /// 后端给的作品总数（不是已加载条数）：顶部信息区显示它，翻页时不跳动
    @State private var total = 0
    /// 三个 tab 各自的按库分布 + 筛选库（nil=全部）。切库重置该 tab 分页重新拉第一页。
    @State private var breakdown = PersonLibraryBreakdown()
    @State private var photoFilterLibrary: Int? = nil
    @State private var albumFilterLibrary: Int? = nil
    @State private var videoFilterLibrary: Int? = nil
    /// 外部人物档案（thenude）。多数人物没有（meta 为空），顶部退回原来的一行信息
    @State private var profile: PersonProfile?
    /// 资料卡/资料栏是否已被用户向左隐藏（默认展开，隐藏后留小入口唤出）
    @State private var profileHidden = false
    @State private var sidebarHidden = false
    /// 只请求一次：.task 在页面重新出现时可能重跑，避免重复请求
    @State private var profileLoaded = false
    /// 右栏顶端固定工具行：排序（Photo 无拍摄时间，只排文件名 / 默认顺序）
    @State private var photoSort: PersonPhotoSort = .original
    /// 右栏三 tab（网页版 PersonProfileMediaTabs）
    @State private var mediaTab: PersonMediaTab = .photos
    /// 相册封面方向：默认横版（与网页版相册列表一致），跨会话记忆
    @AppStorage("personAlbumCoverOrientation") private var albumOrientation: AlbumCoverOrientation = .landscape
    /// 视频封面方向：默认横版（剧照 fanart），跨会话记忆（与网页版 personVideoOrientation 对应）
    @AppStorage("personVideoCoverOrientation") private var videoOrientation: AlbumCoverOrientation = .landscape
    /// 相册/视频卡片的捏合缩放宽度（每 tab 独立记忆）。捏合放大→宽度变大→列数变少
    @State private var albumCardWidth: CGFloat = CGFloat(PhotoGridPrefs.load("personAlbumCards", fallback: 150))
    @State private var videoCardWidth: CGFloat = CGFloat(PhotoGridPrefs.load("personVideoCards", fallback: 200))
    @State private var albumPinchStart: CGFloat = 0
    @State private var videoPinchStart: CGFloat = 0
    private let cardWidthRange: ClosedRange<CGFloat> = 90...420
    /// 相册 tab：懒加载 + 触底分页，接口只读不动库
    @State private var albums: [PersonAlbum] = []
    @State private var albumsTotal = 0
    @State private var albumsUnassigned = 0
    @State private var albumsPage = 1
    @State private var albumsHasMore = true
    @State private var albumsLoading = false
    @State private var albumsErrorMessage: String?

    /// 视频 tab：只消费 confirmed 正式关联（候选不在这里），懒加载
    @State private var videos: [PersonVideo] = []
    @State private var videosTotal = 0
    @State private var videosPage = 1
    @State private var videosHasMore = true
    @State private var videosLoading = false
    @State private var videosErrorMessage: String?
    @State private var videosLoaded = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isWide: Bool { hSizeClass == .regular }
    /// 与演员详情页同一套分栏宽度 / 内边距，两页视觉一致
    private var sidebarWidth: CGFloat { 280 }
    private var panePadding: CGFloat { isWide ? 20 : 16 }
    /// 顶 bar 统一底色：系统导航栏与整宽工具行同色，和下面内容区分开
    private var topBarColor: Color { Color(uiColor: .systemGray6) }
    private var barDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
    }

    var body: some View {
        Group {
            if isWide { wideContent } else { narrowContent }
        }
        // 顶栏：人名移到资料卡图片上方；这里用 principal 放 图片/相册/视频 三个 tab
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                tabPicker
            }
        }
        // 顶 bar 保持实心并与下面那条整宽工具行同色：连成一个整体 bar
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(topBarColor, for: .navigationBar)
        .ignoresSafeArea(edges: .bottom)
        // 两个 task 并发：资料很轻，先回来也不会拖慢照片首屏
        .task { await loadProfile() }
        .task { await loadMore() }
        .task { await loadLibraryBreakdown() }
        .appBackground()
        // 🔴 相册卡在本页（被 push 的详情页）里，destination 必须在**本页**也注册一份：
        // push 出去的页面不在 PeopleHubView 的视图树里，只挂在外层的话这里的
        // NavigationLink(value: PersonAlbumRoute) 匹配不到，表现就是「点相册没反应」。
        // 与项目既有做法一致：MediaItem 在 RootView 与 ActorsView 各注册一份。
        .navigationDestination(for: PersonAlbumRoute.self) { route in
            AlbumPhotosView(album: {
                var a = Album(id: route.id)
                a.folderName = route.name
                a.count = route.count
                a.coverPhotoId = route.coverPhotoId > 0 ? route.coverPhotoId : nil
                return a
            }(), libID: route.libID)
        }
        // 视频卡点进影视详情（同 RootView/ActorsView 的注册方式）
        .navigationDestination(for: MediaItem.self) { item in
            MediaDetailView(media: item)
        }
    }

    /// 资料是可选增强：没有档案的人物返回 200 + 空 meta，网络失败也静默忽略
    @MainActor
    private func loadProfile() async {
        guard !profileLoaded, let client = AppSession.shared.client else { return }
        profileLoaded = true
        profile = try? await client.fetchPersonProfile(personId: person.id)
    }

    @MainActor
    private func loadMore() async {
        guard let client = AppSession.shared.client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, totalCount) = try await client.fetchPersonPhotos(
                personId: person.id, page: page, libraryId: photoFilterLibrary)
            // 页面已切走 / 任务已取消时别再改 UI，也别把取消写成失败
            guard !Task.isCancelled else { return }
            photos.append(contentsOf: batch)
            total = totalCount
            page += 1
            hasMore = !batch.isEmpty
            errorMessage = nil
        } catch {
            guard !isExpectedCancellation(error) else { return }
            errorMessage = "加载照片失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }

    /// 三个 tab 的库分布：进页面加载一次，与筛选无关（始终全量）
    @MainActor
    private func loadLibraryBreakdown() async {
        guard let client = AppSession.shared.client else { return }
        breakdown = (try? await client.fetchPersonLibraryBreakdown(personId: person.id))
            ?? PersonLibraryBreakdown()
    }

    /// 当前 tab 的库分布 / 筛选库
    private var activeLibraryStats: [PersonLibraryStat] {
        switch mediaTab {
        case .photos: return breakdown.libraries
        case .albums: return breakdown.albums
        case .videos: return breakdown.videos
        }
    }
    private var activeFilterLibrary: Int? {
        switch mediaTab {
        case .photos: return photoFilterLibrary
        case .albums: return albumFilterLibrary
        case .videos: return videoFilterLibrary
        }
    }

    /// 点库 chip 筛选：传 nil=全部；传当前已选库=取消筛选，重置该 tab 分页重新拉第一页。
    @MainActor
    private func applyLibraryFilter(_ libId: Int?) async {
        let next: Int?
        if let libId { next = (activeFilterLibrary == libId) ? nil : libId }
        else { next = nil }
        switch mediaTab {
        case .photos:
            photoFilterLibrary = next
            isLoading = false
            photos = []; total = 0; page = 1; hasMore = true; errorMessage = nil
            await loadMore()
        case .albums:
            albumFilterLibrary = next
            albumsLoading = false
            albums = []; albumsTotal = 0; albumsPage = 1; albumsHasMore = true; albumsErrorMessage = nil
            await loadAlbums(reset: false)
        case .videos:
            videoFilterLibrary = next
            videosLoading = false
            videos = []; videosTotal = 0; videosPage = 1; videosHasMore = true; videosErrorMessage = nil
            await loadVideos(reset: false)
        }
    }

    /// 相册 tab 懒加载：切到才请求，触底追加；重复 onAppear 由 albumsLoading 防重入
    @MainActor
    private func loadAlbums(reset: Bool = false) async {
        if reset {
            albumsPage = 1
            albumsHasMore = true
            albums = []
            albumsErrorMessage = nil
        }
        guard let client = AppSession.shared.client, !albumsLoading, albumsHasMore else { return }
        albumsLoading = true
        defer { albumsLoading = false }
        do {
            let (batch, total, unassigned) = try await client.fetchPersonAlbums(
                personId: person.id, page: albumsPage, libraryId: albumFilterLibrary)
            guard !Task.isCancelled else { return }
            if albumsPage == 1 {
                albums = batch
            } else {
                let known = Set(albums.map(\.id))
                albums.append(contentsOf: batch.filter { !known.contains($0.id) })
            }
            albumsTotal = total
            albumsUnassigned = unassigned
            albumsPage += 1
            albumsHasMore = !batch.isEmpty
            albumsErrorMessage = nil
        } catch {
            guard !isExpectedCancellation(error) else { return }
            albumsErrorMessage = "加载相册失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }

    /// 视频 tab 懒加载：切到才请求，只拉 confirmed 关联；未确认候选不显示。
    @MainActor
    private func loadVideos(reset: Bool = false) async {
        if reset {
            videosPage = 1
            videosHasMore = true
            videos = []
            videosErrorMessage = nil
        }
        guard let client = AppSession.shared.client, !videosLoading, videosHasMore else { return }
        videosLoading = true
        defer { videosLoading = false }
        do {
            let (batch, total) = try await client.fetchPersonVideos(
                personId: person.id, page: videosPage, libraryId: videoFilterLibrary)
            guard !Task.isCancelled else { return }
            if videosPage == 1 {
                videos = batch
            } else {
                let known = Set(videos.map(\.id))
                videos.append(contentsOf: batch.filter { !known.contains($0.id) })
            }
            videosTotal = total
            videosPage += 1
            videosHasMore = !batch.isEmpty
            videosLoaded = true
            videosErrorMessage = nil
        } catch {
            guard !isExpectedCancellation(error) else { return }
            videosErrorMessage = "加载视频关联失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }

    /// 排序只改显示顺序，不动 photos 本体（分页追加 / 去重逻辑保持原样）
    private var displayPhotos: [Photo] {
        switch photoSort {
        case .original: return photos
        case .nameAsc:
            return photos.sorted {
                ($0.fileName ?? "").localizedStandardCompare($1.fileName ?? "") == .orderedAscending
            }
        case .nameDesc:
            return photos.sorted {
                ($0.fileName ?? "").localizedStandardCompare($1.fileName ?? "") == .orderedDescending
            }
        }
    }

    // MARK: iPad 双栏：系统导航栏是唯一横跨整页的顶 bar；
    // bar 之下左栏信息 / 右栏数据，三 tab + 图库筛选只在右栏顶行，不跨到资料区上方
    private var wideContent: some View {
        VStack(spacing: 0) {
            // 顶 bar 的下边界，属于系统导航栏那一条，不属于数据区
            barDivider

            HStack(spacing: 0) {
                if !sidebarHidden {
                    ScrollView {
                        PersonSidebar(person: person, profile: profile, isHidden: $sidebarHidden,
                                      total: total, loaded: photos.count)
                            .padding(panePadding)
                            .bottomBarClearance()
                    }
                    .frame(width: sidebarWidth)
                    .clipped()
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 0.5)
                }

                // 三 tab + 排序 / 数量合为一行，属于右侧数据区，不跨到资料区上方
                VStack(spacing: 0) {
                    mediaToolbar
                    mediaContent
                        // UICollectionView 在 VStack 里需要明确拿到剩余空间，否则会塌成 0 高
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.22), value: sidebarHidden)
    }

    // MARK: iPhone 单栏（顶部资料条 + 一行三 tab/排序/计数 + 网格）
    private var narrowContent: some View {
        VStack(spacing: 0) {
            if profileHidden {
                hiddenProfileStrip
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                PersonPhotosHeader(person: person, profile: profile, isHidden: $profileHidden,
                                   total: total, loaded: photos.count)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            mediaToolbar
            mediaContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.22), value: profileHidden)
    }

    /// 资料卡向左隐藏后，顶部只留这一条细入口，点它恢复资料卡
    private var hiddenProfileStrip: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { profileHidden = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("资料").font(.caption.weight(.medium))
                }
                .foregroundStyle(Theme.brand)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.brand.opacity(0.10), in: Capsule())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("显示资料卡")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, panePadding)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { barDivider }
    }

    /// 顶栏（navigationBar principal）的三个 tab：图片 / 相册 / 视频。
    /// 相册/视频懒加载：切到才请求，切回不重拉。
    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(PersonMediaTab.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) { mediaTab = tab }
                    if tab == .albums && albums.isEmpty && !albumsLoading {
                        Task { await loadAlbums(reset: true) }
                    }
                    if tab == .videos && !videosLoaded {
                        Task { await loadVideos(reset: true) }
                    }
                }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 12))
                        Text(tab.rawValue)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mediaTab == tab ? Theme.brand : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        mediaTab == tab ? Theme.brand.opacity(0.12) : Color.clear,
                        in: Capsule()
                    )
                })
                .buttonStyle(.plain)
            }
        }
    }

    /// 工具行：左=图库筛选 chips；右=加载数/总数 + 排序/方向。三 tab 已移到顶栏。
    /// 列数仍可双指捏合调整，并按「人物照片页」记忆。
    private var mediaToolbar: some View {
        HStack(spacing: 6) {
            // iPad 左栏被向左隐藏后，在这一行左边留一个唤出入口
            if isWide && sidebarHidden {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarHidden = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("显示资料栏")
            }

            libraryFilterChips

            // 右侧：加载数/总数 + 排序/方向
            HStack(spacing: 6) {
                // 加载数/总数：图片=已加载/总数，相册=已加载/总数，视频空态不显示
                if mediaTab == .videos ? !videos.isEmpty : true {
                    Text(mediaCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                if mediaTab == .photos {
                    Menu {
                        ForEach(PersonPhotoSort.allCases) { s in
                            Button {
                                photoSort = s
                            } label: {
                                if photoSort == s { Label(s.rawValue, systemImage: "checkmark") }
                                else { Text(s.rawValue) }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .tint(Color.secondary)
                    .accessibilityLabel("照片排序")
                }

                if mediaTab == .albums || mediaTab == .videos {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if mediaTab == .albums {
                                albumOrientation = (albumOrientation == .portrait) ? .landscape : .portrait
                            } else {
                                videoOrientation = (videoOrientation == .portrait) ? .landscape : .portrait
                            }
                        }
                    } label: {
                        let current: AlbumCoverOrientation = mediaTab == .albums ? albumOrientation : videoOrientation
                        Image(systemName: current == .portrait ? "rectangle.portrait" : "rectangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 26)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mediaTab == .videos
                        ? (videoOrientation == .portrait ? "切换横版剧照" : "切换竖版海报")
                        : (albumOrientation == .portrait ? "切换横版封面" : "切换竖版封面"))
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, panePadding)
        .padding(.vertical, 5)
        .background(topBarColor)
        .overlay(alignment: .bottom) { barDivider }
    }

    /// 顶栏右侧的图库筛选：可横向滚动，点库筛该 tab，再点取消。
    private var libraryFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                libraryChip(id: nil, name: "全部",
                            count: activeLibraryStats.isEmpty ? activeTotal
                                                              : activeLibraryStats.reduce(0) { $0 + $1.count },
                            active: activeFilterLibrary == nil)
                ForEach(activeLibraryStats) { s in
                    libraryChip(id: s.libraryId, name: s.name, count: s.count,
                                active: activeFilterLibrary == s.libraryId)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 26)
    }

    /// 当前 tab 的总数（分布未到时给「全部」chip 用）
    private var activeTotal: Int {
        switch mediaTab {
        case .photos: return total
        case .albums: return albumsTotal
        case .videos: return videosTotal
        }
    }

    /// 工具行显示的「已加载/总数」：图片=已加载照片/后端总数，相册/视频同理
    private var mediaCountText: String {
        let loaded: Int
        switch mediaTab {
        case .photos: loaded = photos.count
        case .albums: loaded = albums.count
        case .videos: loaded = videos.count
        }
        let t = activeTotal > 0 ? "\(activeTotal)" : (loaded > 0 ? "\(loaded)" : "—")
        return "\(loaded)/\(t)"
    }

    @ViewBuilder
    private func libraryChip(id: Int?, name: String, count: Int, active: Bool) -> some View {
        Button {
            Task { await applyLibraryFilter(id) }
        } label: {
            HStack(spacing: 4) {
                Text(name)
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(active ? .primary : .tertiary)
            }
            .font(.caption2)
            .foregroundStyle(active ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(active ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch mediaTab {
        case .photos: photoGrid
        case .albums: albumGrid
        case .videos: videoGrid
        }
    }

    /// 相册网格：官方相册封面 + 命中数 + 相册名/总数，点进去复用相册照片页。
    /// 封面方向跟着 albumOrientation 走：竖版 2:3，横版 16:9（网页版同款比例）。
    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: albumCardWidth), spacing: 12)],
                      spacing: 14) {
                ForEach(albums) { album in
                    NavigationLink(value: PersonAlbumRoute(
                        id: album.id, libID: album.libraryId, name: album.title,
                        count: album.photoCount, coverPhotoId: selectedAlbumCoverId(album)
                    )) {
                        albumCard(album)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 触底追加；loadAlbums 内部有 albumsLoading 防重入
                    .onAppear {
                        if album.id == albums.last?.id { Task { await loadAlbums() } }
                    }
                }
            }
            .padding(panePadding)
            if albumsUnassigned > 0 {
                Text("另有 \(albumsUnassigned) 张照片未匹配到相册记录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, panePadding)
                    .padding(.bottom, 12)
            }
        }
        // 双指捏合缩放卡片大小（对齐相册列表页）
        .simultaneousGesture(albumPinch)
        .overlay {
            if albums.isEmpty {
                if let albumsErrorMessage {
                    ContentUnavailableView(albumsErrorMessage, systemImage: "exclamationmark.triangle")
                } else if albumsLoading {
                    ProgressView("加载相册…")
                } else {
                    ContentUnavailableView("该人物的照片暂未归入任何相册", systemImage: "folder")
                }
            }
        }
    }

    private func albumCard(_ album: PersonAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: albumCoverURL(album), fallbackIcon: "folder.fill",
                            fallbackColors: Theme.placeholderGradient(for: .photo))
                    .imageFilled(alignment: .center)
                    .aspectRatio(albumOrientation == .portrait ? 2.0 / 3.0 : 16.0 / 9.0,
                                 contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("\(album.matched) 张")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            Text(album.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("相册共 \(album.photoCount) 张")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// 按当前方向取相册官方封面 id；缺该方向时用另一方向兜底（与网页版一致）
    private func selectedAlbumCoverId(_ album: PersonAlbum) -> Int {
        if albumOrientation == .portrait {
            return album.coverPhotoIdPortrait > 0 ? album.coverPhotoIdPortrait : album.coverPhotoId
        }
        return album.coverPhotoId > 0 ? album.coverPhotoId : album.coverPhotoIdPortrait
    }

    private func albumCoverURL(_ album: PersonAlbum) -> URL? {
        let id = selectedAlbumCoverId(album)
        guard id > 0 else { return nil }
        return AppSession.shared.client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(id)"),
            URLQueryItem(name: "size", value: "600"),
        ])
    }

    /// 视频关联网格：只显示人工复核确认过的正式关联（sim 标在角标），
    /// 点进复用 MediaDetailView（与 RootView/ActorsView 同一套影视详情）。
    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: videoCardWidth), spacing: 14)],
                      spacing: 18) {
                ForEach(videos) { v in
                    NavigationLink(value: MediaItem(id: v.mediaId, title: v.displayTitle)) {
                        videoCard(v)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if v.id == videos.last?.id {
                        Color.clear.frame(height: 1).onAppear { Task { await loadVideos() } }
                    }
                }
            }
            .padding(panePadding)
            if videosLoading && !videos.isEmpty {
                ProgressView().padding()
            }
        }
        // 双指捏合缩放卡片大小（对齐相册列表页）
        .simultaneousGesture(videoPinch)
        .overlay {
            if videos.isEmpty {
                if let videosErrorMessage {
                    VStack(spacing: 12) {
                        ContentUnavailableView(videosErrorMessage, systemImage: "exclamationmark.triangle")
                        Button("重试") { Task { await loadVideos(reset: true) } }
                            .buttonStyle(.bordered)
                    }
                } else if videosLoading || !videosLoaded {
                    ProgressView("加载视频关联…")
                } else {
                    videosEmpty
                }
            }
        }
    }

    private func videoCard(_ v: PersonVideo) -> some View {
        let isPortrait = videoOrientation == .portrait
        // 竖版用海报(poster)，横版用剧照(fanart)；缺哪边用另一边兜底（网页版口径）
        let primaryURL = isPortrait ? (v.coverURL ?? v.backdropURL) : (v.backdropURL ?? v.coverURL)
        // 横版没有剧照、只有竖版海报时：模糊同图铺底 + 完整显示，避免把海报裁成中间一条
        let blurredFallback = !isPortrait && v.backdropURL == nil && v.coverURL != nil
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    if let url = primaryURL {
                        if blurredFallback {
                            // 底层：模糊放大铺满（先模糊再放大，边缘不出软边）
                            RemoteImage(url: url, fallbackIcon: "film",
                                        fallbackColors: Theme.placeholderGradient(for: .media))
                                .imageFilled(alignment: .center)
                                .blur(radius: 20)
                                .scaleEffect(1.15)
                            // 上层：完整显示海报，不裁切
                            RemoteImage(url: url, fallbackIcon: "film",
                                        fallbackColors: Theme.placeholderGradient(for: .media))
                                .imageFitted()
                        } else {
                            RemoteImage(url: url, fallbackIcon: "film",
                                        fallbackColors: Theme.placeholderGradient(for: .media))
                                .imageFilled(alignment: .center)
                        }
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(isPortrait ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(String(format: "sim %.3f", v.sim))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(7)
            }
            Text(v.displayTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(v.year.isEmpty ? "—" : v.year) · 已人工确认")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// 相册 tab 双指捏合缩放卡片宽度。拖动中只改内存，松手才落盘。
    private var albumPinch: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if albumPinchStart == 0 { albumPinchStart = albumCardWidth }
                albumCardWidth = min(max(albumPinchStart * scale, cardWidthRange.lowerBound), cardWidthRange.upperBound)
            }
            .onEnded { _ in
                albumPinchStart = 0
                PhotoGridPrefs.save("personAlbumCards", Int(albumCardWidth))
            }
    }

    /// 视频 tab 双指捏合缩放卡片宽度。
    private var videoPinch: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if videoPinchStart == 0 { videoPinchStart = videoCardWidth }
                videoCardWidth = min(max(videoPinchStart * scale, cardWidthRange.lowerBound), cardWidthRange.upperBound)
            }
            .onEnded { _ in
                videoPinchStart = 0
                PhotoGridPrefs.save("personVideoCards", Int(videoCardWidth))
            }
    }

    /// 视频关联空态：与网页版文案一致，不按名字/封面自动猜关联
    private var videosEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("暂无视频关联").font(.headline)
            Text("人物簇目前只与照片存在关联边，影视与短视频尚无已确认的人物标注。后续需经「人脸候选 → 人工复核 → 正式关联」才会出现在这里；本页不会按名字或封面自动猜测关联。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(panePadding)
    }

    private var photoGrid: some View {
        PhotoGrid(
            photos: displayPhotos,
            columns: columns,
            onColumnsChange: { columns = $0; PhotoGridPrefs.save("personPhotos", $0) },
            onSelect: { photo in
                let list = self.displayPhotos
                guard let i = list.firstIndex(where: { $0.id == photo.id }) else { return }
                PhotoViewerPresenter.shared.show(list, index: i, hasMore: hasMore, onLoadMore: {
                    Task {
                        await self.loadMore()
                        PhotoViewerPresenter.shared.updatePhotos(self.displayPhotos)
                    }
                })
            },
            onReachEnd: { Task { await self.loadMore() } }
        )
        // 加载/错误提示只盖住网格区域，左栏资料与顶端工具行始终可见
        .overlay {
            if photos.isEmpty {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("加载照片…")
                }
            }
        }
    }
}

// MARK: - 人物 VM
final class PersonsViewModel: ObservableObject {
    @Published var items: [Person] = []
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// 搜索词：后端 `/api/persons?q=` 按簇名模糊匹配。
    /// 与演员库一样按页记住上次输入（切走不清空，只有相册列表是「切走即清空」）。
    @Published var searchText = "" {
        didSet { ListSearchPrefs.saveSearch("persons", searchText) }
    }
    /// 已挂档案人物的资料（出生/身高/出生地/相似度），按簇 id 索引。
    /// 卡片用它显示网页版人物资料页同款的数据行；没挂档案的人物卡片少两行小字。
    @Published var profileFacts: [Int: PersonProfile] = [:]

    private var page = 1
    private let pageSize = 60
    private var hasMore = true
    /// 刷新代际：下拉刷新成功后 +1，让刷新前发出的分页请求结果作废，避免旧页混进新列表
    private var generation = 0
    /// 档案列表只拉一次（数据不随分页变化）
    private var factsLoaded = false
    /// 搜索防抖任务。每次输入先取消上一个，只有停手后才真正发请求 ——
    /// `/api/persons` 单次 3s 上下，绝不能让中间输入各打一发把请求堆起来。
    private var searchTask: Task<Void, Never>?

    private var client: APIClient? { AppSession.shared.client }

    init() {
        // 初始化期间给 @Published 赋值不触发 didSet，所以这里不需要额外持久化
        self.searchText = ListSearchPrefs.loadSearch("persons")
    }

    /// 输入变化 → 取消防抖任务 → 250ms 后只请求一次（读最新的 searchText）
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    /// 一次拉全档案列表（约 976 条，接口 size 上限 300 → 最多 4 页并发）。
    /// 失败静默：档案只是卡片上的增强数据，不该拖垮列表本身。
    @MainActor
    func loadFacts() async {
        guard !factsLoaded, let client else { return }
        factsLoaded = true
        do {
            let (_, total) = try await client.fetchPersonProfiles(page: 1)
            let pages = max(1, Int(ceil(Double(total) / 300.0)))
            var dict: [Int: PersonProfile] = [:]
            try await withThrowingTaskGroup(of: [PersonProfile].self) { group in
                for p in 1...pages {
                    group.addTask {
                        try await client.fetchPersonProfiles(page: p, size: 300).items
                    }
                }
                for try await batch in group {
                    for profile in batch { dict[profile.id] = profile }
                }
            }
            profileFacts = dict
        } catch {
            // 取消 / 失败都允许下次进页面重试
            factsLoaded = false
        }
    }

    @MainActor
    func loadInitial() async {
        // 同 AlbumListView：从照片页返回时 .task 可能重跑，已有数据就跳过，保住滚动位置
        guard items.isEmpty else { return }
        await reload()
    }

    @MainActor
    func reload() async {
        // ⚠️ 不要在请求前清空 items：.refreshable 的 Task 会被系统取消
        //（下拉中途松手 / 切 tab / 页面重绘），URLSession 抛 URLError.cancelled。
        // 旧实现清空后整页只剩「加载失败 · cancelled」。改成拿回数据再整体替换，
        // 取消或真失败时都保留原列表。
        await loadMore(replacing: true)
    }

    @MainActor
    func loadMore(replacing: Bool = false) async {
        if replacing {
            // 换搜索词 / 下拉刷新时**立刻**换代：在途的旧请求回来会被 gen 检查丢掉，
            // 不会出现「上一轮搜索的名单迟到，把新结果盖掉」。
            generation += 1
            page = 1
            hasMore = true
            errorMessage = nil
            // 允许新请求取代进行中的那一发（旧请求的 defer 只会把标记复位）
            isLoading = false
        }
        guard let client, (replacing || (!isLoading && hasMore)) else { return }
        let gen = generation
        // 请求发起时的页码快照：刷新换代后旧请求回来也不能把 page 改回旧值
        let requestedPage = page
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.fetchPersons(
                page: requestedPage, size: pageSize,
                q: searchText.isEmpty ? nil : searchText)
            // 刷新已换代的旧分页结果、以及已被取消的任务，都不要再改 UI
            guard gen == generation, !Task.isCancelled else { return }
            if replacing {
                generation += 1   // 作废刷新前发出的分页请求
                items = batch
            } else {
                items.append(contentsOf: batch)
            }
            totalCount = total
            page = requestedPage + 1
            hasMore = !batch.isEmpty && items.count < total
            errorMessage = nil
        } catch {
            // 取消是正常生命周期事件，不是加载失败；真失败才提示
            guard !isExpectedCancellation(error) else { return }
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
