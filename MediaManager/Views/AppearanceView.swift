import SwiftUI
import PhotosUI
import UIKit

// MARK: - 外观设置（主题模式 + 背景图）
// 挂在「我的 → 设置 → 外观」。所有改动即时生效：
// 深浅模式由 App 根的 .preferredColorScheme 接管，背景图由 AppBackgroundView 读取。
struct AppearanceView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    @State private var pickedItem: PhotosPickerItem?
    @State private var isLoadingImage = false
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                modeCard

                backgroundCard

                if appearance.hasBackground { dimCard }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
        }
        .appBackground()
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ iOS 17 起 onChange(of:) 用零参闭包
        .onChange(of: pickedItem) {
            Task { await loadPickedImage() }
        }
        // alert 挂最外层（本页只有一个 alert，不存在同层多个只认一个的问题）
        .alert("移除背景图", isPresented: $confirmingClear) {
            Button("移除", role: .destructive) { appearance.clearBackground() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后各页面回到系统底色。")
        }
    }

    // MARK: 主题模式

    private var modeCard: some View {
        card("circle.lefthalf.filled", "主题") {
            Picker("主题", selection: $appearance.mode) {
                ForEach(AppThemeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .tint(Theme.brand)

            Text("选择「跟随系统」时，App 会随系统的深色模式自动切换。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 背景图

    private var backgroundCard: some View {
        card("photo.fill", "背景图") {
            // 当前背景预览
            Group {
                if let image = appearance.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        // 预览也按实际效果压暗，所见即所得
                        .overlay(
                            Color.black.opacity(appearance.dim),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemBackground))
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                            Text("未设置 · 使用系统底色")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(height: 140)
                }
            }

            HStack(spacing: 12) {
                // ⚠️ PhotosPicker 不需要「相册权限」：它是系统选择器，
                // 只在用户选中后才把那一张图交给 App（Info.plist 不用加权限说明）
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    HStack(spacing: 6) {
                        if isLoadingImage { ProgressView().controlSize(.small) }
                        Text(appearance.hasBackground ? "更换图片" : "选择图片")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)

                if appearance.hasBackground {
                    Button {
                        confirmingClear = true
                    } label: {
                        Text("移除")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            Text("图片会铺满整个 App（顶到安全区），并自动压暗以保证文字可读。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 压暗程度

    private var dimCard: some View {
        card("moon.fill", "背景压暗") {
            HStack {
                Text("浅")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $appearance.dim, in: 0.1...0.75)
                    .tint(Theme.brand)
                Text("深")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("当前 \(Int(appearance.dim * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 通用卡片

    /// 与「我的 → 设置」里的卡片同一套样式：品牌色图标 + 标题 + 内容
    @ViewBuilder
    private func card<Content: View>(_ icon: String,
                                     _ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 选图

    @MainActor
    private func loadPickedImage() async {
        guard let item = pickedItem else { return }
        isLoadingImage = true
        defer {
            isLoadingImage = false
            // 清空选中项，下次选同一张也能触发 onChange
            pickedItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            appearance.setBackground(image)
        } catch {
            // 选图失败（iCloud 没下载完等）就维持原样，不打断用户
        }
    }
}
