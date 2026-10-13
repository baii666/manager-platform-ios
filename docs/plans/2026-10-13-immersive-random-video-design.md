# 沉浸式随机播放视频 — 设计方案

- 日期：2026-10-13
- 状态：**部分实现**（2026-10-13：短视频随机入口已按「首页卡」落地；电影沉浸式随机播放器仍搁置，实现时从本文恢复）
- 触发语：「沉浸式随机出视频先」

## 需求

不想选片，一键进入全屏随机观影：随机挑一部电影开播，播完自动续下一部，可随时手动「换一部」或退出。

## 入口设计（三入口，一个播放器）

| 入口 | 位置 | 随机范围 | 说明 |
| --- | --- | --- | --- |
| ① 主入口 | 首页 HomeView「发现」区新增 DiscoverCard「随机观影」（蓝色 film 图标，与现有「随机照片」卡并列） | 全库电影 | 一键沉浸，适合「不想选直接看」 |
| ② 上下文入口 | 电影列表页 MediaListView 工具栏新增 ToolChip「随机」（shuffle 图标，iconOnly，挨着排序菜单） | 当前媒体库 + 当前搜索词 | 在「漫威」搜索结果里随机就只在漫威里随机 |
| ③ 短视频入口 | 首页 HomeView「发现」区「短视频连播」DiscoverCard（用户 2026-10-13 定稿走此入口，不加工具栏 chip） | 当前池随机起始下标 | ✅ **已实现**：`ShortsRandomRequest` 单例广播 → ShortsView 置随机 startIndex 进已有 ShortFeedView |

明确不做：剧集（tv）随机（随机单集要先拉剧集文件列表，容易踩坑）、拍摄集随机。

## 播放器（新增 ImmersiveRandomView）

- 形态：ZStack overlay 盖在来源页上，完全对齐 ShortFeedView 模式 —— `.transition(.move(edge:.trailing))`、`zIndex(1)`、`FullscreenOverlay.shared.active = true` 藏底栏、右滑退出手势（`exitDragGesture`，dx>100 滑出）
- 复用 VideoPlayerView：`showsCloseButton: false`（关闭按钮自绘在顶栏配件里）、传 `assetType: "media"` + `assetID`，随机观看的进度照常上报进「继续观看」
- 自绘顶栏配件（见下方 VideoPlayerView 改动）：左侧关闭 `xmark`，右侧计数胶囊「随机 3 / 100」+「换一部」shuffle 按钮
- 控制条用播放器自带的（4 秒自动隐藏、单击显隐）
- 随机袋算法：池 shuffle 成数组，`popLast()` 取下一部，取空后 reshuffle，看完一轮不重复
- 播完自动续：靠新增的 `onFinish` 回调触发 `advance()`
- 预解析下一部：当前片开播后后台 `resolvePlayback` 下一部地址存为 `nextTarget`，MKV/AVI（resolvePlayback 要 1~10s）也能无缝续播；只预解析一部（服务端 FFmpeg 会话有成本，别贪多）
- 候选池构建：`fetchMedia(type:libID:page:size:60:sort:q:)` 顺序翻页直到 ≥120 条或翻尽（上限 5 页 300 条），参数取来源页当前的 type / libID / sort / 搜索词
- 错误态：复用 ShortFeedPage placeholder 模式（错误文案 + 重试 + 换一部）

## 需要改动的文件

1. **新增** `MediaManager/Views/ImmersiveRandomView.swift` —— 播放器本体 + 池构建 + 随机袋 + 预解析
2. `Player/PlayerEngine.swift` —— `load(url:startAt:autoplay:loop:)` 里 endObserver 改为**无条件注册**：loop 分支保持「seek 到 0 重播」，否则回调新增的 `var onFinish: (() -> Void)?`
3. `Player/VideoPlayerView.swift` —— 加两个透传参数：
   - `var onFinish: (() -> Void)? = nil`（`setup()` 里赋给 `engine.onFinish`）
   - `var topBarAccessory: AnyView? = nil`（在 `controls` 的 VStack 里 `topBar` **上方**渲染，避免和播放器自己的顶栏重叠）
4. `Views/HomeView.swift` —— `discoverSection` 的 LazyVGrid 加一张 DiscoverCard
5. `Views/MediaListView.swift` —— `TrailingToolsItem` 里加随机 ToolChip，`type == "movie"` 才显示
6. `Views/ShortsView.swift` —— 工具栏加随机 chip

## 遗留决策点（实现时定）

- 随机池大小 120 是否合适（翻页请求数 vs 随机质量）
- 「换一部」要不要加上滑手势：和播放器的垂直亮度/音量手势冲突，倾向不加，只给按钮
- 横屏/iPad 适配：VideoPlayerView 本身支持，验证一遍即可

## 关键复用点（实现前必读）

- `ShortFeedView.swift`：overlay 呈现、右滑退出、单页 prepare() 的取地址逻辑（MP4 同步 `streamURL`，其他走 `resolvePlayback`）
- `ShortsView.swift`：`feedEntry` item 触发 overlay 的写法（避免闭包读到旧下标）
- `PlayerHostView.swift`：`PreparingOverlay` 的等待反馈（片名 + 阶段文案 + 已等待秒数）
- ⚠️ 换行符：仓库 CRLF，新文件写完也要归一化成 CRLF 再提交

## 实现记录（2026-10-13，入口③ 短视频随机）

- 新增 `ShortsRandomRequest`（ShortsView.swift）：ObservableObject 单例，`generation` 自增即一次新请求
- `HomeView`：加 `@Binding var tab: RootTab`；「短视频连播」卡 action = `tab = .short` + `ShortsRandomRequest.shared.request()`
- `ShortsView`：`@ObservedObject randomRequest` + `pendingRandomOpen`；`.onChange(generation)` 消费请求（刷流中忽略连点）；items 为空时置位，由 `.onChange(items.count)` 等首屏加载完了补开；`startRandomFeed()` 取随机下标置 `feedEntry`
- `RootView`：HomeView 调用点补传 `tab: $tab`
- 仍未做（搁置）：电影沉浸式随机播放器 ImmersiveRandomView、`PlayerEngine.onFinish`、电影列表工具栏 chip
