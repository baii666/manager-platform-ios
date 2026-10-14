import UIKit

// MARK: - 瀑布流布局委托
protocol MasonryLayoutDelegate: AnyObject {
    /// 返回 indexPath 处照片的宽高比（宽/高），用于计算 cell 高度
    func aspectRatio(for indexPath: IndexPath) -> CGFloat
}

// MARK: - 瀑布流布局
// 把 cell 排进 N 列，每个 cell 放进当前最短的列，实现 Pinterest 式错落。
final class MasonryLayout: UICollectionViewLayout {
    var columns: Int = 3 { didSet { invalidateLayout() } }
    var spacing: CGFloat = 8 { didSet { invalidateLayout() } }
    /// 内容总高变化回调（每次 prepare 后内容高度变了就触发）。
    /// 自适配高度模式（PhotoGrid.fitsContent）靠它把内容高度上报给 SwiftUI 侧定高 ——
    /// UICollectionView 没有 intrinsicContentSize，不这么做嵌进 SwiftUI ScrollView
    /// 会塌成 0 高度。
    var onContentHeight: ((CGFloat) -> Void)?

    private var cache: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    /// 上次回调出去的内容高度：没变就不回调，避免 prepare 里反复改约束触发重入
    private var lastReportedHeight: CGFloat = -1

    private var contentWidth: CGFloat {
        guard let cv = collectionView else { return 0 }
        let insets = cv.contentInset
        // 首帧 SwiftUI 可能还没定宽：夹到 0，别让下面的列宽算成负数
        return max(0, cv.bounds.width - insets.left - insets.right)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    override func prepare() {
        guard let cv = collectionView else { return }
        cache.removeAll()
        contentHeight = 0

        let count = cv.numberOfItems(inSection: 0)
        // 宽度为 0（SwiftUI 首帧 / 还没布局）时不能排：列宽会成负数，
        // 算出来的负高度一旦上报，SwiftUI 侧 .frame(height:) 等于没给。
        // 这里直接清掉不上报，等真正有宽度的那一轮再算。
        guard contentWidth > 0, count > 0 else {
            cache.removeAll()
            contentHeight = 0
            return
        }

        let colCount = max(1, columns)
        var columnHeights = Array(repeating: CGFloat(0), count: colCount)
        let columnWidth = (contentWidth - CGFloat(colCount - 1) * spacing) / CGFloat(colCount)
        let delegate = cv.delegate as? MasonryLayoutDelegate

        for item in 0..<count {
            let indexPath = IndexPath(item: item, section: 0)
            let ratio = delegate?.aspectRatio(for: indexPath) ?? 0.75
            let height = columnWidth / ratio
            let column = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let x = CGFloat(column) * (columnWidth + spacing)
            let y = columnHeights[column]

            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = CGRect(x: x, y: y, width: columnWidth, height: height)
            cache.append(attributes)

            columnHeights[column] = y + height + spacing
            contentHeight = max(contentHeight, columnHeights[column])
        }
        reportContentHeightIfNeeded()
    }

    /// 内容高度变了才回调：prepare 可能在一次布局流程里跑多次，没变就闭嘴
    private func reportContentHeightIfNeeded() {
        guard contentHeight != lastReportedHeight else { return }
        lastReportedHeight = contentHeight
        onContentHeight?(contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cache.first { $0.indexPath == indexPath }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // 宽度变化（旋转/分屏）时重新布局
        guard let cv = collectionView else { return false }
        return newBounds.width != cv.bounds.width
    }
}
