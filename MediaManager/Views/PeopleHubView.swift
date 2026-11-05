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
        VStack(spacing: 0) {
            Picker("人物类型", selection: $segmentRaw) {
                ForEach(Segment.allCases) { s in
                    Text(s.rawValue).tag(s.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // 两类「人」不是同一份数据，一句话说清当前在看什么
            Text(segment.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
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
}
