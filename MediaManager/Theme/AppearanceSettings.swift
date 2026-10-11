import SwiftUI
import UIKit

// MARK: - 深浅模式
enum AppThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// 给 .preferredColorScheme 用。⚠️ nil 才表示「跟随系统」——
    /// 传 .light/.dark 会把 App 锁死在该模式，系统切换时不再跟着变。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 外观设置（全局单例）
// 主题要作用在 App 根上（preferredColorScheme 只有挂在根才对整个 window 生效），
// 所以做成单例由 App / 各页面直接读，不走 environmentObject，省得每个页面传。
//
// 存储：模式 + 压暗程度进 UserDefaults；背景图是二进制，单独存磁盘文件
//（UserDefaults 不该塞图片 data，几 MB 的图会把 plist 读写拖慢）。
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    private enum Keys {
        static let mode = "appearance.mode"
        static let dim = "appearance.dim"
    }

    /// 背景图最长边上限：4K 原图解码后常驻内存几十 MB，压到 1600 足够铺满屏幕
    private static let maxImageSide: CGFloat = 1600
    private static let fileName = "theme-background.jpg"

    @Published var mode: AppThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// 背景图压暗程度：0 = 完全不压（亮图上文字可能看不清），1 = 全黑看不见图
    @Published var dim: Double {
        didSet { UserDefaults.standard.set(dim, forKey: Keys.dim) }
    }

    /// 自定义背景图。nil = 用系统底色。
    /// ⚠️ 只在内存里保留一份缩放后的图（1600 长边），不是原始大图。
    @Published var backgroundImage: UIImage?

    var hasBackground: Bool { backgroundImage != nil }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.mode) ?? AppThemeMode.system.rawValue
        self.mode = AppThemeMode(rawValue: raw) ?? .system
        let saved = UserDefaults.standard.object(forKey: Keys.dim) as? Double
        // 默认压暗调低（0.35 → 0.22）：面板已全面毛玻璃化，文字可读性由面板保证，
        // 图可以透得更亮（对齐网页版效果）。已存过设置的用户不受影响。
        self.dim = saved ?? 0.22
        // 冷启动时同步读一次磁盘。图不大（几百 KB），主线程读不卡。
        self.backgroundImage = Self.loadImageFromDisk()
    }

    // MARK: 背景图读写

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        // ⚠️ 首次安装时目录可能还不存在，写入前先建
        _ = try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func loadImageFromDisk() -> UIImage? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 设置 / 替换背景图。原图先等比压到 1600 长边再存 JPEG。
    @MainActor
    func setBackground(_ image: UIImage?) {
        guard let image else { clearBackground(); return }
        let scaled = image.scaledToFit(maxSide: Self.maxImageSide)
        backgroundImage = scaled
        guard let url = Self.fileURL, let data = scaled.jpegData(compressionQuality: 0.82) else { return }
        _ = try? data.write(to: url, options: .atomic)
    }

    @MainActor
    func clearBackground() {
        backgroundImage = nil
        guard let url = Self.fileURL else { return }
        _ = try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 图片等比缩放
private extension UIImage {
    /// 等比缩放，使最长边不超过 maxSide（已是小图就原样返回）
    func scaledToFit(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
