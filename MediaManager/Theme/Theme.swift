import SwiftUI

// MARK: - 主题
// 品牌色与现有 Web 端保持一致：蓝紫品牌色 + 按类型区分的四类内容配色
// 电影=蓝 / 剧集=紫 / 相册=粉 / 拍摄集=琥珀 / 短视频=橙
enum Theme {
    /// 品牌主色（现有前端的 --brand 蓝紫）
    static let brand = Color(red: 0.38, green: 0.48, blue: 0.71)

    /// 类型配色（与 Web 端 LIB_TYPE_STYLE 对齐）
    static func tint(for type: AssetType) -> Color {
        switch type {
        case .media: return .blue
        case .photo: return .pink
        case .short: return .orange
        case .shoot: return Color(red: 0.95, green: 0.65, blue: 0.25)
        }
    }

    /// 封面缺失时的渐变占位底（每个类型一套，离线可用）
    static func placeholderGradient(for type: AssetType) -> [Color] {
        switch type {
        case .media: return [Color.blue.opacity(0.55), Color(red: 0.10, green: 0.16, blue: 0.32)]
        case .photo: return [Color.pink.opacity(0.5), Color(red: 0.30, green: 0.10, blue: 0.24)]
        case .short: return [Color.orange.opacity(0.5), Color(red: 0.30, green: 0.15, blue: 0.05)]
        case .shoot: return [Color(red: 0.95, green: 0.65, blue: 0.25).opacity(0.55), Color(red: 0.30, green: 0.20, blue: 0.03)]
        }
    }
}
