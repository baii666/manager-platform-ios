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

    private var cache: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0

    private var contentWidth: CGFloat {
        guard let cv = collectionView else { return 0 }
        let insets = cv.contentInset
        return cv.bounds.width - insets.left - insets.right
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    override func prepare() {
        guard let cv = collectionView else { return }
        cache.removeAll()
        contentHeight = 0

        let count = cv.numberOfItems(inSection: 0)
        guard count > 0 else { return }

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
