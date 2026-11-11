import SwiftUI

// MARK: - 人物聚合页（照片人物 + 影视演员）
// IA 决策：两者都是「以人找内容」，但数据源不同：
//   · 照片人物 = 跨媒体库的人脸聚类（/api/persons），点进去看这个人的全部照片
//   · 影视演员 = 演员库（/api/actors），点进去看简介 / 别名 / 参演作品
// 后端已有 /api/persons/match-actors 与 link-actor 把聚类人物按名字对上演员，
// 所以收在同一个「人物」入口下用分段切换，而不是各开一个入口：
//   · 早期判断「不单开 tab」，后按用户明确要求改回**底栏第 5 个 tab**（人物）。
//     所以本页只作为 tab 根页存在：没有标题顶栏，顶栏只放分段；
//     首页发现区的「人物」卡改成切 tab（不再 push），避免出现两份页面。
//   · 不放媒体库 tab：人物是跨库的，挂在任何单个库下面都不对
//   · 电影/剧集列表的「演员」chip 保留，那是「正在挑片时按演员找片」的场景快捷方式
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
    }

    /// 记住上次停留的分段，切 tab 回来不用每次重选
    @AppStorage("peopleHub.segment") private var segmentRaw = Segment.people.rawValue

    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .people }

    /// 顶栏胶囊与左右滑动共用的选中值（点击胶囊和滑动都写回 AppStorage）
    private var segmentSelection: Binding<Segment> {
        Binding(get: { segment }, set: { segmentRaw = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            // 分段可左右滑动切换（顶栏点击与滑动双向同步），
            // 与媒体库 tab「电影/相册/拍摄集」同一套 TabView(.page) 实现。
            // ⚠️ 两个页面会同时挂载：各自的 navigationDestination 类型不同
            //    （Person / ActorRoute），不像媒体库三页那样会互相顶掉。
            TabView(selection: segmentSelection) {
                PersonsView(embedded: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(Segment.people)
                ActorsView(embedded: true, inlineControls: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(Segment.actors)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        // 顶栏交给分段胶囊：不要标题栏，也不留一条空的导航栏横条
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .appBackground()
    }

    // MARK: 顶栏（只放分段）
    // 与媒体库 tab 的顶 bar（`LibraryHomeView` 里电影/相册/拍摄集那一排）逐项对齐：
    // 居中、上 12 下 8、左右 24、不画分隔线 —— 五个 tab 的顶栏观感必须一致。
    private var headerBar: some View {
        segmentTabs
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            // 只给胶囊上色加动画，不包 segment 赋值
            .animation(.easeInOut(duration: 0.18), value: segment)
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
        }
    }
}
