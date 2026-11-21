import Foundation
import AVFoundation
import SwiftUI
import UIKit

// MARK: - 人脸检测后台中心
// 后端 /api/video-face-probe 走常驻 Python 服务：传 frame_base64（当前帧截图）时
// 直接解码检测（1~2s），不传则回退按时间点读挂载盘抓帧（约 14s）。
// 播放器点击后绝不能 await 它 —— 按钮会一直停在「检测中」，正是用户反馈的卡顿感。
// 这里点击即返回：抓帧 + 请求都在后台 Task，结果走全局 toast，不阻塞 UI。
@MainActor
final class FaceProbeCenter {
    static let shared = FaceProbeCenter()

    /// 同一资源同一秒的重复点击只提交一次，避免连点把后端串行队列堵满。
    /// 后端本身也有 round(t) 幂等键，这里是前端侧的提前拦截。
    private var inFlight: Set<String> = []

    /// t 必须是源文件绝对时间（调用方负责把 HLS 切片偏移加好）。
    /// player 用于抓当前帧：抓到就走截图检测（1~2s，绕开挂载盘读 4K 帧），
    /// 抓不到（HLS 未解码 / seek 中）就传 nil，后端自动回退 t-only 抓帧。
    /// onStatus 把每一步状态回传给调用方自己的 UI —— 🔴 fullScreenCover 是独立
    /// window，RootView 的全局 toast 盖不住它，播放器必须用自己的 hud 显示反馈。
    func probe(medium: String, mediaID: Int, t: Double,
               player: AVPlayer? = nil,
               onStatus: (@MainActor (String) -> Void)? = nil) {
        // 全局 toast（RootView overlay 内，刷流等场景可见）+ 调用方本地 hud 同步报
        let report: @MainActor (String) -> Void = { text in
            FaceProbeToastCenter.shared.show(text)
            onStatus?(text)
        }
        let key = "\(medium):\(mediaID):\(Int(t.rounded()))"
        guard inFlight.insert(key).inserted else {
            report("这次人脸检测已提交，完成后会提示")
            return
        }
        report("人脸检测已提交，完成后会提示")
        Task { @MainActor in
            defer { inFlight.remove(key) }
            guard let client = AppSession.shared.client else { return }
            // 抓帧放后台：AVAssetImageGenerator 同步阻塞，别卡住控制条。
            // AVPlayer 非 Sendable，用 @unchecked 盒子跨到 detached 闭包。
            let box = player.map(FaceProbePlayerBox.init)
            let frame: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let box else { return nil }
                return captureFrame(from: box.player)
            }.value
            do {
                let result = try await client.probeFaceAtTime(
                    mediaID: mediaID, t: t, medium: medium, frameBase64: frame)
                let n = result.entities
                let names = result.matchedNames
                if n > 0 {
                    report(names.isEmpty
                        ? "已登记 \(n) 张人脸，人物页可见"
                        : "已登记 \(n) 张人脸：" + names.joined(separator: "、"))
                } else {
                    report("当前画面未检出可归入已有的人物人脸")
                }
            } catch {
                report("人脸检测失败：\(error.localizedDescription)")
            }
        }
    }
}

/// AVPlayer 的盒装：仅为跨 detached 闭包传引用，播放器的时间读取是线程安全的。
private final class FaceProbePlayerBox: @unchecked Sendable {
    let player: AVPlayer
    init(_ player: AVPlayer) { self.player = player }
}

/// 抓当前画面一帧 → JPEG data URI（与 Web captureVideoFrame 同口径：
/// 最长边 1920、quality 0.85）。失败返回 nil，让后端回退 t-only 抓帧。
/// 🔴 抓帧用 player.currentTime()（播放器时间轴当前位置），与传给后端的
/// 绝对时间 t 分开：HLS 从 -ss 切片时二者差一个 offset，用错就检到错误帧。
/// 放在类型外（非 actor 隔离），才能在 Task.detached 里调用。
private func captureFrame(from player: AVPlayer) -> String? {
    guard let item = player.currentItem, item.status == .readyToPlay else { return nil }
    let generator = AVAssetImageGenerator(asset: item.asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1920, height: 1920)
    // 精确取当前帧，别让系统吸附到最近关键帧（人脸可能已经转过去）
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let cg = try? generator.copyCGImage(at: player.currentTime(), actualTime: nil),
          let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return nil }
    return "data:image/jpeg;base64," + data.base64EncodedString()
}

// MARK: - 全局提示（挂在 RootView 最外层，z 高于刷流 / 看图器）
@MainActor
final class FaceProbeToastCenter: ObservableObject {
    static let shared = FaceProbeToastCenter()
    @Published var message: String?
    private var clearTask: Task<Void, Never>?

    func show(_ text: String) {
        clearTask?.cancel()
        message = text
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            message = nil
        }
    }
}

struct FaceProbeToastView: View {
    @ObservedObject private var center = FaceProbeToastCenter.shared

    var body: some View {
        Group {
            if let text = center.message {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
        // 撑满的容器不能吃掉底层手势（刷流还要上下滑）
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: center.message)
    }
}
