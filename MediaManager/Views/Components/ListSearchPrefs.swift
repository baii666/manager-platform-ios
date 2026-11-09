import Foundation

// MARK: 列表页「搜索词 + 排序」记忆
// 与 PhotoGridPrefs / CardSizePrefs 同一思路：UserDefaults 按页各记一份，
// 只在 App 内记忆（不随账号、不上云、换服务器也保留）。
//
// 记两样东西：
//   1. 搜索词 —— 离开列表页再回来（含杀进程重开）还原，不用重新打字
//   2. 排序 —— 当前选的排序档 + 升/降序方向
//
// ⚠️ 键只按「页」分，不按媒体库/池分：换库时搜索框保留原文（他要的就是
//「我记得我刚在搜什么」），不会串味到别的页。
// 🔴 例外：相册列表页(albums) 2026-11-10 改为「切走即清空」——用户明确要求
// 切页面后不要残留搜索词，所以它既 loadSearch 也不 saveSearch，见 AlbumListViewModel。
enum ListSearchPrefs {
    private static func key(_ page: String, _ field: String) -> String {
        "listSearch.\(page).\(field)"
    }

    /// 上次的搜索词；没记过返回空串
    static func loadSearch(_ page: String) -> String {
        UserDefaults.standard.string(forKey: key(page, "q")) ?? ""
    }

    static func saveSearch(_ page: String, _ text: String) {
        UserDefaults.standard.set(text, forKey: key(page, "q"))
    }

    /// 清掉某页记过的搜索词。给「切走即清空」的页面用：不落盘、不还原，
    /// 顺手抹掉历史版本已写进 UserDefaults 的旧值，避免重启后又冒出来。
    static func clearSearch(_ page: String) {
        UserDefaults.standard.removeObject(forKey: key(page, "q"))
    }

    /// 上次的排序档。rawValue 对不上时（后端加了新档 / 老值被废弃）回退默认值，
    /// 不会因为一个脏值把列表卡死。
    static func loadSort<R: RawRepresentable>(_ page: String, fallback: R) -> R where R.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key(page, "sort")) else { return fallback }
        return R(rawValue: raw) ?? fallback
    }

    static func saveSort(_ page: String, raw: String) {
        UserDefaults.standard.set(raw, forKey: key(page, "sort"))
    }

    /// 升/降序方向（排序字段与方向分开做两个 chip 的页面用：拍摄集 / 短视频 / 演员）
    static func loadDescending(_ page: String, fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key(page, "desc")) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key(page, "desc"))
    }

    static func saveDescending(_ page: String, _ descending: Bool) {
        UserDefaults.standard.set(descending, forKey: key(page, "desc"))
    }
}

// MARK: - 页面切换信号
// RootView 的 tab 是 ZStack + opacity 常驻的，切 tab / 导航栈 push 时列表页
// **不会** onDisappear，@StateObject 也不会重建 —— 靠生命周期清空搜索词不可靠。
// 改为切页面时发一个通知，需要「切走即清空」的列表页自己订阅。
extension Notification.Name {
    static let listPageShouldResetSearch = Notification.Name("listPageShouldResetSearch")
}
