import SwiftUI
import UIKit

// MARK: - 照片瀑布流网格
// 用 UICollectionView 承载百万级照片：cell 复用 + 懒加载 + 预取 + 缩略图缓存，
// 内存与滚动性能远好于 SwiftUI 自绘网格。
struct PhotoGrid: UIViewRepresentable {
    let photos: [Photo]
    /// 初始列数（各页面默认值不同）。⚠️ 它只是初始值 / 外部显式修改的入口：
    /// 用户捏合后的实时列数以 Coordinator 为准，父视图重渲染不会把它弹回去
    ///（见 updateUIView 的 syncsColumns 注释）。
    var columns: Int = 3
    /// 捏合缩放的列数范围。放大（分开手指）→ 列数变少，最小 1 列铺满全宽
    var minColumns: Int = 1
    var maxColumns: Int = 6
    /// 列数变化回调（每步触发）。父视图据此持久化（各页记忆自己的列数），
    /// 并把 columns 参数同步回来。不传 = 捏合只当场生效，不记忆。
    var onColumnsChange: ((Int) -> Void)? = nil
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
        // 双指捏合缩放列数（对齐相册列表 / 影视列表页的捏合）。
        // 挂在 cv 上而不是 SwiftUI 侧：列数是离散档位，原生手势可以直接改布局，
        // 不经过父视图状态 → 没有每步 reloadData 的闪烁
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        cv.addGestureRecognizer(pinch)
        context.coordinator.collectionView = cv
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self
        let layout = cv.collectionViewLayout as? MasonryLayout
        // columns 参数只在「父视图显式改了它」时跟随（持久化恢复 / 宽度自适应的默认值变化）。
        // ⚠️ 两个不能无条件写回的理由：
        // ① 捏合过程中父视图每步都会重渲染走到这里，写回参数会把用户捏出的列数弹回旧值；
        // ② 无回调页面的参数是常量，而 Coordinator 里的实时值可能已被手势改掉。
        // 有回调的页面靠 onColumnsChange 把参数同步回来，两边不会打架。
        if syncsColumns, let layout, layout.columns != columns {
            layout.columns = columns
            context.coordinator.liveColumns = columns
        }
        // 数据变了才 reload：count + 首尾 id 做指纹，replace 成同长度数组也不会漏判
        //（以前每次 updateUIView 都 reloadData，捏合时 cell 全量重建会剧烈闪烁）
        let token = (photos.count, photos.first?.id ?? -1, photos.last?.id ?? -1)
        if token != context.coordinator.dataToken {
            context.coordinator.dataToken = token
            cv.reloadData()
        }
    }

    /// 父视图是否跟随列数变化（有回调才会把 columns 参数同步回来）
    private var syncsColumns: Bool { onColumnsChange != nil }

    // MARK: Coordinator

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, MasonryLayoutDelegate {
        var parent: PhotoGrid
        weak var collectionView: UICollectionView?
        /// 图片加载后回填的真实宽高比（photo.id → 宽/高）。
        /// 对齐网页版 PhotoWaterfallGrid：真实加载尺寸 > 数据 width/height > 后备比例。
        private var ratioCache: [Int: CGFloat] = [:]
        /// 捏合后的实时列数。父视图的 columns 参数只是初始值，手势改完后以这里为准
        ///（否则任何父视图刷新都会把用户捏好的列数弹回旧值，见 updateUIView 注释）。
        /// ⚠️ 不能标 private：updateUIView（外层 struct）要读写它
        var liveColumns: Int
        /// 上次 reloadData 时的数据指纹（count + 首尾 id），用于跳过无谓的整表重载。
        /// ⚠️ 同上，外层 updateUIView 要读写
        var dataToken: (Int, Int, Int)
        /// 捏合开始时视野顶部的 item：列数变化后把它钉回顶部，避免内容跳动
        private var pinchAnchor: IndexPath?
        /// 每档步进的触感反馈（对齐系统相册捏合的手感）
        private let feedback = UISelectionFeedbackGenerator()

        init(_ parent: PhotoGrid) {
            self.parent = parent
            self.liveColumns = parent.columns
            self.dataToken = (parent.photos.count,
                              parent.photos.first?.id ?? -1,
                              parent.photos.last?.id ?? -1)
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

        // MARK: 捏合缩放

        /// 双指捏合 → 列数步进。放大（分开手指）列数变少、合拢列数变多，
        /// 每跨过一档就把手势参考点重置（scale=1），下次重新累计 —— 连续捏合可以一路缩到底。
        /// ⚠️ 不能标 private：makeUIView 里用 #selector(Coordinator.handlePinch) 注册，
        /// 跨类型引用 private 成员编译不过。
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let cv = collectionView else { return }
            switch gesture.state {
            case .began:
                pinchAnchor = cv.indexPathsForVisibleItems.min(by: { $0.item < $1.item })
                feedback.prepare()
            case .changed:
                let scale = gesture.scale
                var stepped = false
                if scale > 1.5, liveColumns > parent.minColumns {
                    liveColumns -= 1
                    stepped = true
                } else if scale < 0.67, liveColumns < parent.maxColumns {
                    liveColumns += 1
                    stepped = true
                }
                guard stepped else { return }
                gesture.scale = 1
                applyColumns(cv)
                feedback.selectionChanged()
                feedback.prepare()
            case .ended, .cancelled, .failed:
                pinchAnchor = nil
            default:
                break
            }
        }

        /// 把实时列数写进布局并重排；保持手势开始时顶部那张仍在顶部。
        /// 只 invalidateLayout 不 reloadData：masonry 布局与数据无关，cell 全部复用。
        private func applyColumns(_ cv: UICollectionView) {
            let layout = cv.collectionViewLayout as? MasonryLayout
            guard layout?.columns != liveColumns else { return }
            layout?.columns = liveColumns
            cv.layoutIfNeeded()
            if let anchor = pinchAnchor, anchor.item < cv.numberOfItems(inSection: 0) {
                cv.scrollToItem(at: anchor, at: .top, animated: false)
            }
            parent.onColumnsChange?(liveColumns)
        }
    }
}

// MARK: - 瀑布流列数记忆
// 对齐列表页 CardSizePrefs 的思路：每个照片页各记一份，捏合缩到位后下次进来还是那个列数。
enum PhotoGridPrefs {
    static func load(_ key: String, fallback: Int) -> Int {
        // UserDefaults.integer 未命中返回 0，用 >=1 区分「没存过」和「存过 1」
        let v = UserDefaults.standard.integer(forKey: "photoGrid.columns.\(key)")
        return v >= 1 ? v : fallback
    }

    static func save(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: "photoGrid.columns.\(key)")
    }
}

// MARK: - Cell
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    private let imageView = UIImageView()
    /// 左下角胶囊角标（语义搜索的相似度）。photo.badge 为 nil 时不显示
    private let badgeLabel = BadgeLabel()
    private var currentURL: URL?
    private var onImageLoaded: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.masksToBounds = true
        // ⚠️ 设了全局背景图时必须透底：这是 UIKit 的 cell，不透明底色会把
        // 背景图挡死，整个照片网格变成一块块实心灰砖（SwiftUI 侧全是毛玻璃）。
        // cell 重用时会被再次调用，外观切换后滚动一下即刷新。
        contentView.backgroundColor = AppearanceSettings.shared.hasBackground
            ? .clear
            : .secondarySystemBackground

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

        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.layer.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.isHidden = true
        contentView.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            badgeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
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
        badgeLabel.text = nil
        badgeLabel.isHidden = true
    }

    func configure(with photo: Photo, onImageLoaded: ((CGFloat) -> Void)? = nil) {
        let url = photo.thumbURL
        currentURL = url
        self.onImageLoaded = onImageLoaded

        // 角标：语义搜索会带相似度（"87%"），普通照片为 nil
        badgeLabel.text = photo.badge
        badgeLabel.isHidden = photo.badge == nil

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

/// 带内边距的角标 Label：UILabel 没有 padding，只能靠 drawText(in:) + intrinsicContentSize 自己撑
private final class BadgeLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }
}
