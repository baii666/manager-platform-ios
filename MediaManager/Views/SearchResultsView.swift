import SwiftUI

// MARK: - 搜索结果
// 影视 / 照片 / 相册 / 拍摄集共用一个结果网格，点海报直接播放或打开照片浏览器
struct SearchResultsView: View {
    let results: [UnifiedAsset]
    var onSelect: ((UnifiedAsset) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView.search
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(results) { asset in
                            AssetPosterCard(asset: asset) {
                                onSelect?(asset)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}
