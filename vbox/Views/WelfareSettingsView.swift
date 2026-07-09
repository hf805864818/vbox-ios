import SwiftUI

// MARK: - 福利平台域名设置页面

struct WelfareSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = WelfareDomainStore.shared
    @State private var editingPlatform: String? = nil
    @State private var editDomain: String = ""
    @State private var savedToast: String? = nil
    @FocusState private var isFocused: Bool

    /// 所有支持域名自定义的平台
    private let platforms: [(name: String, icon: String, defaultHosts: [String])] = [
        ("每日大乱斗", "flame.fill", ["https://border.bshzjjgq.cc", "https://blood.bshzjjgq.cc"]),
        ("每日大赛", "trophy.fill", ["https://www.ercwvciks.cc"]),
        ("神秘电影", "theatermasks.fill", ["https://h4ivs.sm431.vip"]),
        ("香蕉秀", "heart.fill", [])
    ]

    var body: some View {
        ZStack {
            List {
                Section {
                    Text("如果某个平台的域名失效，可以在这里自定义新的域名。自定义域名会优先于默认域名使用。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Section {
                    ForEach(platforms, id: \.name) { platform in
                        VStack(alignment: .leading, spacing: 8) {
                            // 平台名称 + 当前域名 + 编辑按钮
                            HStack {
                                Image(systemName: platform.icon)
                                    .foregroundColor(.accentColor)
                                Text(platform.name)
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()

                                if store.domain(for: platform.name) != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 14))
                                }
                            }

                            // 当前域名
                            HStack {
                                Text("当前域名：")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text(currentDisplay(for: platform.name, defaults: platform.defaultHosts))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(store.domain(for: platform.name) != nil ? .accentColor : .secondary)
                                    .lineLimit(1)
                                Spacer()

                                Button(action: {
                                    editingPlatform = platform.name
                                    editDomain = store.domain(for: platform.name) ?? ""
                                    isFocused = true
                                }) {
                                    Text("编辑")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing) {
                            if store.domain(for: platform.name) != nil {
                                Button("重置", role: .destructive) {
                                    store.setDomain(for: platform.name, nil)
                                    resetService(for: platform.name)
                                    showToast("已恢复默认域名")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            // 编辑弹窗
            if let platform = editingPlatform {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        editingPlatform = nil
                    }

                VStack(spacing: 20) {
                    Text("编辑 \(platform) 域名")
                        .font(.system(size: 17, weight: .semibold))

                    TextField("输入新域名，如 https://example.com", text: $editDomain)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { doSave() }

                    HStack(spacing: 16) {
                        Button(action: {
                            editingPlatform = nil
                        }) {
                            Text("取消")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            doSave()
                        }) {
                            Text("保存")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .shadow(radius: 20)
                .padding(.horizontal, 30)
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.3), value: editingPlatform)
                .zIndex(10)
            }
        }
        .navigationTitle("福利平台域名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .overlay(alignment: .top) {
            if let toast = savedToast {
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.green, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .zIndex(20)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { savedToast = nil }
                        }
                    }
            }
        }
    }

    // MARK: - 辅助方法

    private func currentDisplay(for name: String, defaults: [String]) -> String {
        if let custom = store.domain(for: name) {
            return custom
        }
        return defaults.first ?? "—"
    }

    private func doSave() {
        guard let platform = editingPlatform else { return }
        let trimmed = editDomain.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.setDomain(for: platform, nil)
            showToast("已恢复默认域名")
        } else {
            store.setDomain(for: platform, trimmed)
            showToast("\(platform) 域名已保存")
        }
        editingPlatform = nil
        resetService(for: platform)
    }

    private func showToast(_ message: String) {
        withAnimation { savedToast = message }
    }

    private func resetService(for name: String) {
        switch name {
        case "每日大乱斗":
            DailyBattleService.shared.resetDomain()
        case "每日大赛":
            DailyBattleService.contest.resetDomain()
        default:
            break
        }
    }
}