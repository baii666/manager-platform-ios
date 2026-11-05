import SwiftUI

// MARK: - 人物聚合页（照片人物 + 影视演员）
// IA 决策：两者都是「以人找内容」，但数据源不同：
//   · 照片人物 = 跨媒体库的人脸聚类（/api/persons），点进去看这个人的全部照片
//   · 影视演员 = 演员库（/api/actors），点进去看简介 / 别名 / 参演作品
// 后端已有 /api/persons/match-actors 与 link-actor 把聚类人物按名字对上演员，
// 所以收在同一个「人物」入口下用分段切换，而不是各开一个入口：
//   · 不加第 5 个 tab：4 个 tab 已覆盖消费路径，人物是「找内容」的次级维度
//   · 不放媒体库 tab：人物是跨库的，挂在任何单个库下面都不对
//   · 首页发现区「人物」卡是聚合入口；电影/剧集列表的「演员」chip 保留，
//     那是「正在挑片时按演员找片」的场景快捷方式，不算重复入口
struct PeopleHubView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case people = "照片人物"
        case actors = "影视演员"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .people: return "person.crop.circle.fill"
            case .actors: return "film.fill"
            }
        }

        var hint: String {
            switch self {
            case .people: return "人脸聚类结果 · 点开看同一个人的全部照片"
            case .actors: return "演员库 · 点开看简介、别名与参演作品"
            }
        }
    }

    /// 记住上次停留的分段，切 tab 回来不用每次重选
    @AppStorage("peopleHub.segment") private var segmentRaw = Segment.people.rawValue

    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .people }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            segmentTabs
                .padding(.horizontal, 24)
                .padding(.top, 20)

            // 两类「人」不是同一份数据，一句话说清当前在看什么。
            // 压到 caption2 + tertiary：不跟上面的切换控件抢视觉重量。
            Text(segment.hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 2)

            switch segment {
            case .people:
                PersonsView(embedded: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .actors:
                ActorsView(embedded: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("人物")
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
    }

    // MARK: 顶部分段
    // ⚠️ 不用 .pickerStyle(.segmented)：系统那块灰色圆角底板 + 灰字在全站
    //    「inline 标题 + 左右 24」的顶部节奏里像个外挂控件（用户明确否掉）。
    //    改用和搜索页分类胶囊同一套语言：品牌色 15% 淡底 + 品牌色文字 + 图标，
    //    未选中透明底，没有整条灰底板。
    // ⚠️ 字重恒定（不随选中态切 regular/semibold）：中文字重变化会让胶囊宽度
    //    跳一两个点，切换时整排跟着左右晃。宽度只由文字 + 固定 padding 决定。
    private var segmentTabs: some View {
        HStack(spacing: 8) {
            ForEach(Segment.allCases) { s in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { segmentRaw = s.rawValue }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(s.rawValue)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(segment == s ? Theme.brand : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        segment == s ? Theme.brand.opacity(0.15) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
