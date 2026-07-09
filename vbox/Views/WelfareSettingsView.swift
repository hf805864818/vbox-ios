import SwiftUI

// MARK: - 福利平台域名设置页面

struct WelfareSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = WelfareDomainStore.shared
    @State private var editingPlatform: String? = nil
    @State private var newDomain: String = ""
    @FocusState private var isFocused: Bool

    /// 所有支持域名自定义的平台
    private let platforms: [(name: String, icon: String, defaultHosts: [String])] = [
        ("每日大乱斗", "flame.fill", ["https://border.bshzjjgq.cc", "https://blood.bshzjjgq.cc"]),
        ("每日大赛", "trophy.fill", ["https://mrdsa1.com"]),
        ("神秘电影", "theatermasks.fill", ["https://h4ivs.sm431.vip"]),
        ("香蕉秀", "heart.fill", [])
    ]

    var body: some View {
        List {
            Section {
                Text("如果某个平台的域名失效，可以在这里自定义新的域名。自定义域名会优先于默认域名使用。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Section {
                ForEach(platforms, id: \.name) { platform in
                    VStack(alignment: .leading, spacing: 8) {
                        // 平台名称行
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
                        // 点击标题行展开编辑
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editingPlatform == platform.name {
                                editingPlatform = nil  // 再次点击收起
                            } else {
                                editingPlatform = platform.name
                                newDomain = store.domain(for: platform.name) ?? ""
                                isFocused = true
                            }
                        }

                        // 当前域名展示
                        HStack {
                            Text("当前域名：")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text(currentDisplay(for: platform.name, defaults: platform.defaultHosts))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(store.domain(for: platform.name) != nil ? .accentColor : .secondary)
                                .lineLimit(1)
                        }

                        // 编辑区域
                        if editingPlatform == platform.name {
                            HStack(spacing: 8) {
                                TextField("输入新域名，如 https://example.com", text: $newDomain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .focused($isFocused)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        saveDomain(for: platform.name)
                                    }

                                Button(action: {
                                    saveDomain(for: platform.name)
                                }) {
                                    Text("保存")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    editingPlatform = nil
                                }) {
                                    Text("取消")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button("编辑") {
                            editingPlatform = platform.name
                            newDomain = store.domain(for: platform.name) ?? ""
                            isFocused = true
                        }
                        .tint(.accentColor)

                        if store.domain(for: platform.name) != nil {
                            Button("重置", role: .destructive) {
                                store.setDomain(for: platform.name, nil)
                                resetService(for: platform.name)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("福利平台域名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
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

    private func saveDomain(for name: String) {
        let trimmed = newDomain.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.setDomain(for: name, nil)
        } else {
            store.setDomain(for: name, trimmed)
        }
        editingPlatform = nil
        resetService(for: name)
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