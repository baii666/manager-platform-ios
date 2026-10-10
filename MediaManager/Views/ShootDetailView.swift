import SwiftUI

// MARK: - 拍摄集详情页
// 对齐网页端 ShootDetailPage：Tab(全部/视频/照片) + 视频列表(播放) + 照片瀑布流(看图器) + 无限滚动
struct ShootDetailView: View {
    let shoot: Shoot

    @StateObject private var viewModel: ShootDetailViewModel
    @State private var playing = false
    @State private var playingURL: URL?
    @State private var showViewer = false
    @State private var viewerIndex = 0

    private var client: APIClient? { AppSession.shared.client }

    init(shoot: Shoot) {
        self.shoot = shoot
        _viewModel = StateObject(wrappedValue: ShootDetailViewModel(shoot: shoot))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("内容", selection: $viewModel.activeTab) {
                Text("全部 (\(viewModel.totalCount))").tag(ShootDetailViewModel.Tab.all)
                Text("视频 (\(viewModel.videos.count))").tag(ShootDetailViewModel.Tab.videos)
                Text("照片 (\(viewModel.photoTotal))").tag(ShootDetailViewModel.Tab.photos)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            ScrollView {
                if viewModel.activeTab == .videos || viewModel.activeTab == .all {
                    if !viewModel.videos.isEmpty {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.videos) { file in
                                ShootVideoRow(file: file) {
                                    if let url = client?.shootFileURL(file.id) {
                                        playingURL = url; playing = true
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if viewModel.activeTab == .photos || viewModel.activeTab == .all {
                    if !viewModel.photos.isEmpty {
                        PhotoGrid(photos: viewModel.viewerPhotos, columns: 3, onSelect: { photo in
                            if let idx = viewModel.viewerPhotos.firstIndex(where: { $0.id == photo.id }) {
                                viewerIndex = idx
                            }
                            showViewer = true
                        }) {
                            await viewModel.loadMorePhotos()
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                if viewModel.photos.isEmpty && viewModel.videos.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView("暂无内容", systemImage: "photo.on.rectangle.angled")
                        .padding(.top, 60)
                }
            }
        }
        .navigationTitle(shoot.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadInitial() }
        .fullScreenCover(isPresented: $playing) {
            if let playingURL {
                NavigationStack {
                    VideoPlayerView(url: playingURL, title: shoot.title)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { playing = false }
                        } }
                }
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            if !viewModel.viewerPhotos.isEmpty {
                PhotoViewerView(photos: viewModel.viewerPhotos, index: viewerIndex, hasMore: viewModel.photoHasMore) {
                    Task { await viewModel.loadMorePhotos() }
                } onClose: { showViewer = false }
            }
        }
    }
}

// MARK: - 拍摄集详情 VM
final class ShootDetailViewModel: ObservableObject {
    enum Tab: Hashable { case all, videos, photos }

    let shoot: Shoot
    @Published var activeTab: Tab = .all
    @Published var videos: [ShootFile] = []
    @Published var photos: [ShootFile] = []
    @Published var photoTotal = 0
    @Published var photoHasMore = false
    @Published var isLoading = false

    private var photoPage = 1
    private let photoSize = 50

    init(shoot: Shoot) { self.shoot = shoot }

    var totalCount: Int { videos.count + photoTotal }

    /// 把照片 ShootFile 适配成 Photo 供看图器使用
    var viewerPhotos: [Photo] {
        photos.map { f in
            var p = Photo(id: f.id)
            p.thumbURL = AppSession.shared.client?.shootPhotoURL(f.id, size: 600)
            p.fullURL = AppSession.shared.client?.shootPhotoURL(f.id)
            p.width = f.width
            p.height = f.height
            p.fileSize = f.fileSize
            p.fileName = f.filename
            return p
        }
    }

    @MainActor
    func loadInitial() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await client.fetchShootDetail(id: shoot.id)
            videos = detail.videos
        } catch {}
        await loadMorePhotos()
    }

    @MainActor
    func loadMorePhotos() async {
        guard let client, !isLoading, photoHasMore || photoPage == 1 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let batch = try await client.fetchShootPhotos(id: shoot.id, page: photoPage, size: photoSize)
            let existing = Set(photos.map { $0.id })
            photos.append(contentsOf: batch.filter { !existing.contains($0.id) })
            photoTotal = photos.count // 后端未返回总页，用已加载数 + hasMore 近似
            photoPage += 1
            photoHasMore = !batch.isEmpty
        } catch {}
    }
}

// MARK: - 视频行
private struct ShootVideoRow: View {
    let file: ShootFile
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.placeholderGradient(for: .shoot))
                        .frame(width: 56, height: 56)
                    Image(systemName: "play.fill")
                        .font(.system(size: 20)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.filename).font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 8) {
                        if let d = file.durationText {
                            Label(d, systemImage: "clock").font(.caption2)
                        }
                        if let dim = file.dimensionText {
                            Text(dim).font(.caption2)
                        }
                        Text(file.sizeText).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.secondarySystemBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }
}
