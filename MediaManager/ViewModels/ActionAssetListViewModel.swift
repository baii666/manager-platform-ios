import Foundation

// MARK: - 收藏 / 观看记录全量列表
// 「我的」tab 里的横滑行只放一屏，点「查看全部」进来翻全量。
// 走统一行为层 GET /api/actions/list?action=…&page=&size=，四类内容混排。
//
// 后端契约（task-service/internal/modules/unifiedactions/api.go · hList）：
//   GET /api/actions/list?action=favorite|history&type=all&page=1&size=60
//   → { items: [{type,id,title,subtitle,cover_url,backdrop_url,path,duration,at}],
//       total, page, size }
//   · action 只有 favorite / history 两种，写别的会静默按 favorite 处理
//   · type=all 展开成 media/photo/short/shoot 四类（AllTypes()），与 AssetType 一一对应
//   · size 上限 200，越界回落到 30；total 是**全部**条数不是本页条数
//   · ⚠️ 与 /api/actions/resume 的关键差别：list **不返回 position**。
//     所以这里的条目没有播放进度（asset.progress 恒为 0），点进去从头播 ——
//     不是 bug，是这个接口就没给。要续播得走 resume。
//   · at 是行为发生的时间戳（秒），后端有返回但客户端暂不消费
//
// ⚠️ 只在方法上标 @MainActor，不标在类上：类级 @MainActor 会让 init 也变成
// MainActor 隔离，而 View 的 init 里就要构造它（StateObject(wrappedValue:)），
// 那种写法在严格并发检查下会报错。项目里其他 ViewModel 也都是标在方法上。
final class ActionAssetListViewModel: ObservableObject {

    @Published var items: [UnifiedAsset] = []
    @Published var total = 0
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?

    let action: AssetActionKind

    private let injected: DataProviding?
    private let pageSize = 60
    private var page = 1
    private var didAutoLoad = false

    init(action: AssetActionKind, provider: DataProviding? = nil) {
        self.action = action
        self.injected = provider
    }

    /// 真实数据源 —— 只可能是后端客户端。
    /// ⚠️ 刻意不回退 MockDataProvider：这一页装的是用户自己的收藏 / 观看记录，
    /// 拿假数据把界面填满会让人误以为接口已经打通，真出问题反而更难排查。
    /// 未登录 / 会话失效时 client 为 nil，那就如实报「未连接服务器」。
    /// 动态取值而不是 init 时快照一次：会话可能在构造之后才恢复。
    /// 写成 if-let 而不是 `injected ?? AppSession.shared.client`：?? 要求两侧同类型，
    /// 让编译器自己去把 APIClient 统一成 DataProviding 并不总是成功。
    private var provider: DataProviding? {
        if let injected { return injected }
        return AppSession.shared.client
    }

    var hasMore: Bool { items.count < total }

    /// 首屏只加载一次：NavigationStack 的 .task 在返回上一层时会再跑一遍，
    /// 不闸住的话每次进出都重新拉第一页
    @MainActor
    func loadIfNeeded() async {
        guard !didAutoLoad else { return }
        didAutoLoad = true
        await reload()
    }

    @MainActor
    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let provider else {
            items = []
            total = 0
            errorMessage = "未连接服务器"
            return
        }
        do {
            let (items, total) = try await provider.fetchActionAssets(action: action, page: 1, size: pageSize)
            self.items = items
            self.total = total
            self.page = 1
        } catch {
            self.items = []
            self.total = 0
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, let provider else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = page + 1
            let (more, total) = try await provider.fetchActionAssets(action: action, page: next, size: pageSize)
            // 只追加本页没出现过的：翻页期间若有新记录插入，total 位移会让边界页重复
            let seen = Set(items.map { "\($0.type.rawValue)-\($0.id)" })
            let fresh = more.filter { !seen.contains("\($0.type.rawValue)-\($0.id)") }
            guard !fresh.isEmpty else { return }
            items.append(contentsOf: fresh)
            self.total = total
            page = next
        } catch {
            // 静默：翻页失败不该把已加载的内容清掉
        }
    }
}
