import Foundation
import SwiftUI

// MARK: - 人脸检测后台中心
// 后端 /api/video-face-probe 是同步脚本（模型加载 + 检测约 10s，且服务端串行）。
// 播放器点击后绝不能再 await 它 —— 按钮会一直停在「检测中」，正是用户反馈的卡顿感。
// 这里点击即返回：请求丢进后台 Task，结果走全局 toast，
// 任何页面（含刷流 / 播放器 / 看图器）都能看到，不阻塞 UI。
@MainActor
final class FaceProbeCenter {
    static let shared = FaceProbeCenter()

    /// 同一资源同一秒的重复点击只提交一次，避免连点把后端串行队列堵满。
    /// 后端本身也有 round(t) 幂等键，这里是前端侧的提前拦截。
    private var inFlight: Set<String> = []

    /// t 必须是源文件绝对时间（调用方负责把 HLS 切片偏移加好）。
    func probe(medium: String, mediaID: Int, t: Double) {
        let key = "\(medium):\(mediaID):\(Int(t.rounded()))"
        guard inFlight.insert(key).inserted else {
            FaceProbeToastCenter.shared.show("这次人脸检测已提交，完成后会提示")
            return
        }
        FaceProbeToastCenter.shared.show("人脸检测已提交，完成后会提示")
        Task { @MainActor in
            defer { inFlight.remove(key) }
            guard let client = AppSession.shared.client else { return }
            do {
                let result = try await client.probeFaceAtTime(
                    mediaID: mediaID, t: t, medium: medium)
                let n = result.entities
                let names = result.matchedNames
                if n > 0 {
                    FaceProbeToastCenter.shared.show(names.isEmpty
                        ? "已登记 \(n) 张人脸，人物页可见"
                        : "已登记 \(n) 张人脸：" + names.joined(separator: "、"))
                } else {
                    FaceProbeToastCenter.shared.show("当前画面未检出可归入已有的人物人脸")
                }
            } catch {
                FaceProbeToastCenter.shared.show("人脸检测失败：\(error.localizedDescription)")
            }
        }
    }
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
