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

        init(_ parent: PhotoGrid) {
            self.parent = parent
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.photos.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
            cell.configure(with: parent.photos[indexPath.item])
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
            return parent.photos[indexPath.item].aspectRatio
        }
    }
}

// MARK: - Cell
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    private let imageView = UIImageView()
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.masksToBounds = true
        contentView.backgroundColor = .secondarySystemBackground

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
        imageView.image = nil
    }

    func configure(with photo: Photo) {
        let url = photo.thumbURL
        currentURL = url

        guard let url else {
            imageView.image = nil
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }

        imageView.image = nil
        Task {
            let image = await ImageCache.shared.load(from: url)
            guard self.currentURL == url else { return } // cell 已被复用，丢弃过期结果
            await MainActor.run {
                self.imageView.image = image
            }
        }
    }
}
