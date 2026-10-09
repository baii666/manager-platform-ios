import SwiftUI

// MARK: - 搜索框
struct SearchBar: View {
    @Binding var text: String
    @Binding var semantic: Bool
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索片名、演员、文件名…", text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                semantic.toggle()
            } label: {
                Image(systemName: "sparkles")
                    .foregroundStyle(semantic ? Color.purple : .secondary)
                    .padding(11)
                    .background(
                        semantic ? Color.purple.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onSubmit) {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
