import Foundation

// MARK: - 任务进度状态
// 订阅 SSE 事件流，把 JSON payload 解析成 TaskProgress 并更新。
// 支持离线 simulate（无后端时演示 UI）；接后端时改调 connect(to:)。
final class TaskProgressViewModel: ObservableObject {
    @Published var tasks: [TaskProgress] = []
    @Published var isConnected = false

    private var streamTask: Task<Void, Never>?

    var hasActiveTasks: Bool {
        tasks.contains { !$0.isFinished }
    }

    // MARK: SSE 连接

    func connect(to url: URL) {
        streamTask?.cancel()
        isConnected = true
        streamTask = Task {
            do {
                try await SSEClient(url: url).stream { [weak self] data in
                    self?.handle(data)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isConnected = false
                }
            }
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        isConnected = false
    }

    // MARK: 解析与合并

    private func handle(_ data: String) {
        guard let progress = Self.parse(data) else { return }
        Task { @MainActor [weak self] in
            self?.upsert(progress)
        }
    }

    private func upsert(_ progress: TaskProgress) {
        if let idx = tasks.firstIndex(where: { $0.id == progress.id }) {
            tasks[idx] = progress
        } else {
            tasks.append(progress)
        }
    }

    /// 宽松解析：字段名兼容后端可能的不同命名，避免一个字段对不上就整体失败
    static func parse(_ data: String) -> TaskProgress? {
        guard let d = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let id = (obj["task_id"] as? String)
            ?? (obj["id"] as? String)
            ?? (obj["task_type"] as? String)
            ?? "task"
        let type = (obj["task_type"] as? String) ?? (obj["type"] as? String) ?? ""
        let message = (obj["message"] as? String) ?? (obj["status"] as? String) ?? ""
        let done = (obj["done"] as? NSNumber)?.intValue ?? (obj["progress"] as? NSNumber)?.intValue ?? 0
        let total = (obj["total"] as? NSNumber)?.intValue ?? (obj["total_count"] as? NSNumber)?.intValue ?? 0
        let finished = (obj["finished"] as? NSNumber)?.boolValue ?? (obj["is_done"] as? NSNumber)?.boolValue ?? false
        return TaskProgress(id: id, taskType: type, message: message, done: done, total: total, isFinished: finished)
    }

    // MARK: 离线模拟（无后端时演示 UI）

    func simulateIfNeeded() {
        guard tasks.isEmpty else { return }
        let specs: [(String, Int)] = [("扫描照片", 120), ("生成缩略图", 80), ("人脸检测", 200)]
        for (i, spec) in specs.enumerated() {
            let id = "mock-\(i)"
            let (type, total) = spec
            tasks.append(TaskProgress(id: id, taskType: type, message: "初始化…", done: 0, total: total))
            Task { @MainActor [weak self] in
                var done = 0
                while done < total {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    done += Int.random(in: 1...14)
                    done = min(done, total)
                    let finished = done >= total
                    self?.upsert(TaskProgress(
                        id: id,
                        taskType: type,
                        message: finished ? "完成" : "处理中…",
                        done: done,
                        total: total,
                        isFinished: finished
                    ))
                }
            }
        }
    }
}
