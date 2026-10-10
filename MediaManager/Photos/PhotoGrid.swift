import SwiftUI
import UIKit

// MARK: - 照片瀑布流网格
// 用 UICollectionView 承载百万级照片：cell 复用 + 懒加载 + 预取 + 缩略图缓存，
// 内存与滚动性能远好于 SwiftUI 自绘网格。
struct PhotoGrid: UIViewRepresentable {
    let photos: [Photo]
    var columns: Int = 3
    var onSelect: (Photo) -> Void = { _ in }
    var onReachEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = MasonryLayout()
        layout.columns = columns
        layout.spacing = 8

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator
        cv.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        cv.contentInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        context.coordinator.collectionView = cv
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self
        (cv.collectionViewLayout as? MasonryLayout)?.columns = columns
        cv.reloadData()
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, MasonryLayoutDelegate {
        var parent: PhotoGrid
        weak var collectionView: UICollectionView?
        /// 图片加载后回填的真实宽高比（photo.id → 宽/高）。
        /// 对齐网页版 PhotoWaterfallGrid：真实加载尺寸 > 数据 width/height > 后备比例。
        private var ratioCache: [Int: CGFloat] = [:]

        init(_ parent: PhotoGrid) {
            self.parent = parent
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.photos.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
            let photo = parent.photos[indexPath.item]
            cell.configure(with: photo) { [weak self] ratio in
                self?.updateRatio(for: photo.id, ratio: ratio)
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            parent.onSelect(parent.photos[indexPath.item])
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            for ip in indexPaths where ip.item < parent.photos.count {
                if let url = parent.photos[ip.item].thumbURL {
                    Task { _ = await ImageCache.shared.load(from: url) }
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // 滚到接近底部时触发加载更多
            if indexPath.item >= parent.photos.count - 6 {
                parent.onReachEnd()
            }
        }

        func aspectRatio(for indexPath: IndexPath) -> CGFloat {
            guard indexPath.item < parent.photos.count else { return 0.75 }
            let photo = parent.photos[indexPath.item]
            // 图片已加载出真实尺寸时，优先用它（数据里的 width/height 可能缺失或未按 EXIF 校正）
            if let cached = ratioCache[photo.id] { return cached }
            return photo.aspectRatio
        }

        /// 图片加载后回填真实比例；只有和数据里的比例差异明显时才重排，避免滚动时反复无效重算
        func updateRatio(for id: Int, ratio: CGFloat) {
            guard ratio.isFinite, ratio > 0 else { return }
            if let old = ratioCache[id], abs(old - ratio) < 0.005 { return }
            ratioCache[id] = ratio
            guard let idx = parent.photos.firstIndex(where: { $0.id == id }) else { return }
            let dataRatio = parent.photos[idx].aspectRatio
            guard abs(ratio - dataRatio) > 0.02 else { return }
            // 异步重排，避免在 cellForItemAt（缓存命中时同步回调）里重入布局
            DispatchQueue.main.async { [weak self] in
                self?.collectionView?.collectionViewLayout.invalidateLayout()
            }
        }
    }
}

// MARK: - Cell
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    private let imageView = UIImageView()
    private var currentURL: URL?
    private var onImageLoaded: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.masksToBounds = true
        contentView.backgroundColor = .secondarySystemBackground

        // 格子高度会按「图片真实尺寸」重排对齐，所以这里填满也不会裁到内容
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentURL = nil
        onImageLoaded = nil
        imageView.image = nil
    }

    func configure(with photo: Photo, onImageLoaded: ((CGFloat) -> Void)? = nil) {
        let url = photo.thumbURL
        currentURL = url
        self.onImageLoaded = onImageLoaded

        guard let url else {
            imageView.image = nil
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            imageView.image = cached
            reportSize(cached)
            return
        }

        imageView.image = nil
        Task {
            let image = await ImageCache.shared.load(from: url)
            guard self.currentURL == url else { return } // cell 已被复用，丢弃过期结果
            await MainActor.run {
                self.imageView.image = image
                if let image { self.reportSize(image) }
            }
        }
    }

    /// 图片加载后回填真实宽高比，让瀑布流按真实比例重排格子高度
    private func reportSize(_ image: UIImage) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        onImageLoaded?(size.width / size.height)
    }
}
