import SwiftUI

// MARK: - 更新弹窗
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isPresented: Bool
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isOpening = false

    init(isPresented: Binding<Bool>? = nil) {
        self._isPresented = isPresented ?? .constant(true)
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// 把 Release body 解析成更新条目列表
    private var notes: [String] {
        updateManager.releaseNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                // 去掉行首的 "1、" / "1." / "1．" 等序号前缀
                let pattern = #"^\d+[、.．]\\s*"#
                if let range = line.range(of: pattern, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                return line
            }
    }

    private func close() {
        dismiss()
        isPresented = false
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                // 顶部关闭按钮
                HStack {
                    Spacer()
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.gray)
                        .frame(width: 32, height: 32)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Circle())
                        .onTapGesture { close() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // 火箭图标
                Image(systemName: "paperplane.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .foregroundColor(Color(hex: "00A8FF"))
                    .rotationEffect(.degrees(-30))
                    .padding(.top, 8)

                // 标题
                Text("发现新版本")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.top, 12)

                // 最新版本号
                Text(updateManager.latestVersion)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(.top, 4)

                // 更新内容（可滚动）
                if !notes.isEmpty {
                    ScrollView(showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(index + 1)、")
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                    Text(note)
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .frame(height: min(CGFloat(notes.count * 30) + 24, 200))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                Spacer(minLength: 16)

                // 马上升级按钮
                Button(action: {
                    isOpening = true
                    updateManager.openReleasePage()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isOpening = false
                    }
                }) {
                    HStack {
                        if isOpening { ProgressView().tint(.white) }
                        Text(isOpening ? "正在打开..." : "马上升级")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: "00A8FF"))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                // 当前版本
                Text("当前版本 \(currentVersion)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
            .frame(width: 320, height: 460)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(uiColor: .systemBackground))
            )
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        }
    }
}

#Preview {
    UpdateSheet()
}
