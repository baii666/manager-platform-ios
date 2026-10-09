import Foundation

// MARK: - SSE 客户端
// 后端通过 text/event-stream 推送任务进度（扫描/转码/人脸检测等）。
// 用 URLSession 的 bytes 流逐行解析：事件以空行分隔，data: 行是 JSON payload。
struct SSEClient {
    let url: URL
    var headers: [String: String] = [:]

    /// 持续读取事件流，每收到一个完整事件回调一次 data payload（JSON 字符串）
    func stream(onEvent: @escaping @Sendable (String) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        var buffer = ""
        for try await line in bytes.lines {
            buffer += line + "\n"
            if line.isEmpty {
                // 空行标志一个事件结束
                let event = buffer
                buffer = ""
                let data = extractData(from: event)
                if !data.isEmpty {
                    onEvent(data)
                }
            }
        }
    }

    private func extractData(from event: String) -> String {
        var payload = ""
        for raw in event.split(separator: "\n") {
            if raw.hasPrefix("data:") {
                var value = String(raw.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                payload += value
            }
        }
        return payload
    }
}
