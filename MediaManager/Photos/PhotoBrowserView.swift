import SwiftUI

// MARK: - 照片浏览状态（懒加载分页）
final class PhotoBrowserViewModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var isLoading = false

    private let provider: DataProviding
    private let pageSize = 60
    private var offset = 0

    init(provider: DataProviding? = nil) {
        self.provider = provider ?? AppSession.shared.client ?? MockDataProvider()
    }

    @MainActor
    func loadInitial() async {
        guard photos.isEmpty else { return }
        await loadMore()
    }

    @MainActor
    func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let batch = try await provider.fetchPhotos(limit: pageSize, offset: offset)
            offset += batch.count
            photos.append(contentsOf: batch)
        } catch {
            // 忽略：保留已加载内容即可
        }
    }
}

// MARK: - 照片浏览页（瀑布流 + 懒加载 + 大图查看）
struct PhotoBrowserView: View {
    /// 看图器走哪条路。默认全局 overlay（PhotoViewerPresenter，退出丝滑）；
    /// ⚠️ 但本页若被装在 **sheet** 里（「我的 → 照片」），全局 overlay 会被 sheet
    /// 盖在下面看不见 —— 此时传 false，退回本页自己的 fullScreenCover。
    var useGlobalViewer = true
    @State private var localViewerIndex: Int?

    @StateObject private var viewModel = PhotoBrowserViewModel()

    var body: some View {
        PhotoGrid(
            photos: viewModel.photos,
            columns: 4,
            onSelect: { photo in
                guard let i = viewModel.photos.firstIndex(where: { $0.id == photo.id }) else { return }
                if useGlobalViewer {
                    PhotoViewerPresenter.shared.show(viewModel.photos, index: i, hasMore: true, onLoadMore: {
                        Task {
                            await viewModel.loadMore()
                            PhotoViewerPresenter.shared.updatePhotos(viewModel.photos)
                        }
                    })
                } else {
                    localViewerIndex = i
                }
            },
            onReachEnd: {
                Task { await viewModel.loadMore() }
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("相册")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.photos.isEmpty {
                ProgressView("加载照片…")
            }
        }
        .task { await viewModel.loadInitial() }
        .fullScreenCover(isPresented: Binding(
            get: { localViewerIndex != nil },
            set: { if !$0 { localViewerIndex = nil } }
        )) {
            if let index = localViewerIndex {
                PhotoViewerView(
                    photos: viewModel.photos,
                    index: index,
                    hasMore: true,
                    onLoadMore: { Task { await viewModel.loadMore() } },
                    onClose: { localViewerIndex = nil }
                )
            }
        }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来。
        .appBackground()
    }
}
