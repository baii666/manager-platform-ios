import SwiftUI
import UIKit

// MARK: - 任务进度面板
// 展示后端推送的后台任务（扫描/转码/人脸检测）实时进度。
struct TaskProgressView: View {
    @ObservedObject var viewModel: TaskProgressViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if viewModel.tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(viewModel.tasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear { viewModel.simulateIfNeeded() }
    }

    private var header: some View {
        HStack {
            Label("后台任务", systemImage: "gearshape.2")
                .font(.headline)
            Spacer()
            if viewModel.isConnected {
                Label("实时", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂无进行中的任务")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func taskRow(_ task: TaskProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.taskType.isEmpty ? "任务" : task.taskType)
                    .font(.caption.weight(.semibold))
                Spacer()
                if task.isFinished {
                    Label("完成", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("\(Int(task.percent * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: task.percent)
            if !task.message.isEmpty {
                Text(task.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
