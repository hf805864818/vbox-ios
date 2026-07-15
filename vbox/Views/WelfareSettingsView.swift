import SwiftUI

// MARK: - 福利平台域名设置页面（多域名管理）

struct WelfareSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WelfareDomainStore.shared
    @State private var editingPlatform: String? = nil
    @State private var editDomain: String = ""
    @State private var savedToast: String? = nil
    @State private var refreshID = UUID()
    @FocusState private var isFocused: Bool

    private let platforms: [(name: String, icon: String, defaultHosts: [String])] = [
        ("每日大乱斗", "flame.fill", ["https://border.bshzjjgq.cc", "https://blood.bshzjjgq.cc"]),
        ("每日大赛", "trophy.fill", ["https://www.ercwvciks.cc"]),
        ("神秘电影", "theatermasks.fill", ["https://h4ivs.sm431.vip"]),
        ("四虎视频", "film.fill", ["https://www.sihuhu.xyz"]),
        ("香肠派对", "party.popper.fill", ["https://xiang512.xiang.party/xcpd"]),
        ("香蕉秀", "heart.fill", []),
        ("萝莉AV", "heart.circle.fill", ["https://212602.luoliav.cc"]),
        ("麻豆免费", "play.tv.fill", ["https://c-you.hair"]),
        ("久久網", "film.stack.fill", ["https://ww.jiujiu.one"]),
        ("韩国色情电影", "flag.fill", ["https://koreanpornmovie.com"]),
        ("今日看料", "eye.fill", ["https://kanliao2.one"]),
        ("黑料不打烊", "flame.circle.fill", ["https://heiliao.com"]),
        ("通用吸瓜", "flame.fill", ["https://advise.nlwkmsv.cc"]),
    ]

    var body: some View {
        ZStack {
            List {
                Section {
                    Text("添加自定义域名后，系统会按顺序轮询。第一个可用的域名将被使用。左滑可删除已保存的域名。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Section {
                    ForEach(platforms, id: \.name) { platform in
                        platformRow(platform)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .id(refreshID)

            // 添加域名弹窗
            if let platform = editingPlatform {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { editingPlatform = nil }

                VStack(spacing: 20) {
                    Text("添加 \(platform) 域名")
                        .font(.system(size: 17, weight: .semibold))

                    TextField("输入新域名，如 https://example.com", text: $editDomain)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { doAdd() }

                    HStack(spacing: 16) {
                        Button(action: { editingPlatform = nil }) {
                            Text("取消").font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color(UIColor.secondarySystemBackground)).cornerRadius(10)
                        }
                        .buttonStyle(.plain)

                        Button(action: { doAdd() }) {
                            Text("添加").font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.accentColor).cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16).shadow(radius: 20)
                .padding(.horizontal, 30)
                .animation(.spring(response: 0.3), value: editingPlatform)
                .zIndex(10)
            }
        }
        .navigationTitle("福利平台域名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }.font(.system(size: 15, weight: .semibold))
            }
        }
        .overlay(alignment: .top) {
            if let toast = savedToast {
                Text(toast).font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.green, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8).zIndex(20)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { savedToast = nil }
                        }
                    }
            }
        }
    }

    // MARK: - 平台行

    @ViewBuilder
    private func platformRow(_ platform: (name: String, icon: String, defaultHosts: [String])) -> some View {
        let customs = store.domains(for: platform.name)

        VStack(alignment: .leading, spacing: 8) {
            // 平台名称 + 添加按钮
            HStack {
                Image(systemName: platform.icon).foregroundColor(.accentColor)
                Text(platform.name).font(.system(size: 15, weight: .medium))
                Spacer()
                Button(action: {
                    editingPlatform = platform.name
                    editDomain = ""
                    isFocused = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
            }

            // 默认域名
            if !platform.defaultHosts.isEmpty {
                HStack(spacing: 4) {
                    Text("默认：").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(platform.defaultHosts[0])
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary).lineLimit(1)
                }
            }

            // 自定义域名列表（每个单独一行 + 删除按钮）
            ForEach(customs, id: \.self) { domain in
                HStack {
                    Image(systemName: "link").font(.system(size: 10)).foregroundColor(.accentColor)
                    Text(domain).font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.accentColor).lineLimit(1)
                    Spacer()
                    Button(action: {
                        store.removeDomain(for: platform.name, domain)
                        resetService(for: platform.name)
                        refreshID = UUID()
                        showToast("已删除域名")
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.06))
                .cornerRadius(6)
            }

            // 全部重置按钮
            if !customs.isEmpty {
                Button(action: {
                    store.clearDomains(for: platform.name)
                    clearAndReset(for: platform.name)
                    refreshID = UUID()
                    showToast("已恢复默认域名")
                }) {
                    Text("全部重置为默认")
                        .font(.system(size: 12)).foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }

            // 统计
            let total = customs.count + platform.defaultHosts.count
            if total > 0 {
                Text("共 \(total) 个域名，按顺序轮询")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 辅助方法

    private func doAdd() {
        guard let platform = editingPlatform else { return }
        let trimmed = editDomain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addDomain(for: platform, trimmed)
        showToast("域名已添加")
        editingPlatform = nil
        refreshID = UUID()
        resetService(for: platform)
    }

    private func showToast(_ msg: String) {
        withAnimation { savedToast = msg }
    }

    private func resetService(for name: String) {
        // 添加/删除域名后只需重新探测，不清除域名
        switch name {
        case "每日大乱斗": DailyBattleService.shared.reprobe()
        case "每日大赛": DailyBattleService.contest.reprobe()
        case "萝莉AV": LuoliAVService.shared.reprobe()
        case "麻豆免费": MadouFreeService.shared.reprobe()
        case "久久網": JiujiuService.shared.reprobe()
        case "韩国色情电影": KoreanPornService.shared.reprobe()
        case "今日看料": KanliaoService.shared.reprobe()
        case "黑料不打烊": HeiliaoService.shared.reprobe()
        case "通用吸瓜": XiguaService.shared.reprobe()
        default: break
        }
    }

    private func clearAndReset(for name: String) {
        // 全部重置时清除域名并重新探测
        switch name {
        case "每日大乱斗": DailyBattleService.shared.resetDomain()
        case "每日大赛": DailyBattleService.contest.resetDomain()
        case "萝莉AV": LuoliAVService.shared.resetDomain()
        case "麻豆免费": MadouFreeService.shared.resetDomain()
        case "久久網": JiujiuService.shared.resetDomain()
        case "韩国色情电影": KoreanPornService.shared.resetDomain()
        case "今日看料": KanliaoService.shared.resetDomain()
        case "黑料不打烊": HeiliaoService.shared.resetDomain()
        case "通用吸瓜": XiguaService.shared.resetDomain()
        default: break
        }
    }
}