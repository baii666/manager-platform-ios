# MediaManager for iPad

一个**独立**的 SwiftUI iPad 客户端，按现有 Emby Manager 系统的首页功能打造，追求 iPad 上的「极致体验」。

> 与现有项目（`D:/manager-platform`）**零耦合**：纯客户端、无后端依赖，数据用 Mock 撑起，网络层预留了接入真实服务的接口。

## 首页功能（已实现）

对齐 Web 端 `HomePageV3` 的消费视角信息架构：

| 区块 | 说明 |
|---|---|
| Hero 搜索 | 统一搜索框 + 语义搜索切换 + 六张统计卡（媒体库/电影/剧集/图片/拍摄集/短视频） |
| 继续观看 | 16:9 横版卡片 + 播放进度条 + hover 播放按钮，跨「影视/写真/短视频/拍摄集」四类 |
| 我的收藏 | 3:4 竖版海报卡，带类型标签与底部渐变标题 |
| 最近入库 | 2:3 海报卡，覆盖电影/剧集/相册 |
| 发现 | 随机照片 / 人物 / 拍摄集 / 短视频连播 四个入口卡 |

其余侧边栏入口（电影/剧集/相册/拍摄集/短视频等）为占位页，供后续迭代。

## 项目结构

```
MediaManager/
├── MediaManagerApp.swift        # App 入口
├── Models/Models.swift          # 数据模型（四类资产 / 统一资产 / 最近入库 / 媒体库 / 统计）
├── Network/
│   ├── DataProvider.swift       # 数据提供协议（UI 只依赖它）
│   ├── MockDataProvider.swift   # Mock 实现（离线可跑）
│   └── APIClient.swift          # 真实后端客户端（预留，未启用）
├── ViewModels/HomeViewModel.swift
├── Views/
│   ├── RootView.swift           # NavigationSplitView 三栏骨架
│   ├── HomeView.swift           # 首页主视图
│   └── Components/              # 搜索框 / 统计卡 / 海报卡 / 进度卡 / 发现卡 / 区块头 / 远程图
├── Theme/Theme.swift            # 品牌色 + 四类内容配色
└── Assets.xcassets
```

## 关键设计

- **解耦靠协议**：UI 只依赖 `DataProviding`，换数据源（Mock → 真实后端）不需要改任何视图。
- **封面离线可降级**：`RemoteImage` 有 URL 走 `AsyncImage`，没有/失败时回退到「渐变 + SF Symbol」，保证离线也能看界面。
- **类型驱动配色**：四类内容（影视/写真/短视频/拍摄集）各有独立占位渐变与标签色，与 Web 端一致。

## 编译运行

> 需要 **macOS + Xcode 15+**（Swift 5.9 / iOS 17+）。当前 Windows 环境无法编译 Swift。

两种方式任选：

**方式 A：XcodeGen（推荐）**
```bash
brew install xcodegen
cd media-manager-ios
xcodegen generate      # 生成 MediaManager.xcodeproj
open MediaManager.xcodeproj
```

**方式 B：手动**
新建一个 iOS App 工程（Device 选 iPad），把 `MediaManager/` 目录整个拖进去，删除自动生成的模板文件即可。

## 接入真实后端

后端是纯 HTTP JSON（约 257 个 REST 端点，默认 `http://<host>:19876`）。接入时：

1. 实现 `APIClient`，把对应端点映射到 `Models.swift` 里的结构：
   - `GET /api/libraries` → `HomeStats`
   - `GET /api/actions/resume` → `[UnifiedAsset]`
   - `GET /api/actions/favorites` → `[UnifiedAsset]`
   - `GET /api/recent?limit=N` → `[RecentItem]`
2. 认证：`POST /api/auth/login` 拿 session cookie，后续请求带上。
3. 封面：`/media-image?id=xxx&size=600`、`/photo?id=xxx&size=600`。
4. 在 `RootView` 里把 `MockDataProvider()` 换成 `APIClient(baseURL:)`。

## 下一步建议

- 播放器：接 `AVKit` 播放 HLS（`/hls/*.m3u8`），这是「极致体验」的核心。
- 照片瀑布流：用 `UICollectionView`/`LazyVGrid` + 缩略图缓存替换静态网格，应对百万级照片。
- 任务进度：用 `URLSession` 长连接封装 SSE，展示扫描/转码进度。
