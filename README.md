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

## Mac 上从零开始（clone + 认证）

私有仓库需要先认证，再 clone。

**前置**：App Store 装 Xcode（15+）；装 Homebrew（https://brew.sh）；Mac 上有能访问 GitHub 的代理。

**认证（SSH 推荐，与 Windows 同款免密）**：

```bash
ssh-keygen -t ed25519 -C "你的邮箱"     # 一路回车
cat ~/.ssh/id_ed25519.pub              # 复制输出 → GitHub → Settings → SSH and GPG keys → New SSH key

# 配 SSH 走代理（端口改成你 Mac 代理的；代理不转发 22 端口时用 ssh.github.com:443）
cat >> ~/.ssh/config <<'EOF'
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519
    ProxyCommand nc -X 5 -x 127.0.0.1:7890 %h %p
EOF

ssh -T git@github.com   # 应返回 "Hi baii666! ..." 即成功
```

**clone**：

```bash
git clone git@github.com:baii666/manager-platform-ios.git
cd manager-platform-ios
```

> HTTPS 备选：`git clone https://github.com/baii666/manager-platform-ios.git`，用户名 `baii666`、密码填 PAT（先 `git config --global http.proxy http://127.0.0.1:7890`）。

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

## 安装到 iPad 真机

默认用**免费 Apple ID 签名**（Personal Team），可直接装到自己的 iPad，但有 7 天有效期。

**步骤**：

1. 用数据线把 iPad 连到 Mac，iPad 弹窗点「信任」，Mac 上允许。
2. Xcode 打开工程，选中项目 → **Signing & Capabilities**：
   - 勾选 **Automatically manage signing**
   - **Team** 选你的 Apple ID（没有就点 Add Account 登录，免费账号即可）
   - **Bundle Identifier** 改成唯一值（`com.mediamanager.ipad` 大概率被占用，改成 `com.你的名字.mediamanager` 之类）
3. Xcode 顶部设备选择器选你的 **iPad**（不是模拟器）。
4. 点 **Run（⌘R）**。
5. 首次运行提示「未受信任的开发者」：iPad → **设置 → 通用 → VPN 与设备管理** → 点你的开发者证书 → **信任**。

**免费签名限制**：7 天后失效，需重新连 Mac 再 Run 一次；最多同时装 3 个自签 app。

**想长期用 / 免电脑安装**：注册 Apple Developer Program（$99/年），即可真机调试 1 年有效、用 **TestFlight** 分发（测试设备点链接安装，不用每次连 Mac）。

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
