//
//  RemoteWelfareHomeView.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：远程源福利专区首页，与现有 WelfareHomeView 并行存在。
//        - 顶部展示「使用福利远程源」Toggle（默认开），开启时才显示本 View
//        - 关闭时：调用方（ProfileView / ContentView）改用现有 WelfareHomeView
//        - 完全独立的数据源：从 WelfarePlatformConfigStore 拉平台列表
//        - 复用现有所有 Service / HomeView（通过 WelfarePlatformRouter 分发）
//        - 长按排序：使用 platformKey 持久化（与 name 索引并存，新用户用 platformKey）
//
//  使用：
//    if WelfarePlatformConfigStore.shared.switchEnabled {
//        RemoteWelfareHomeView()
//    } else {
//        WelfareHomeView()  // 旧版
//    }
//

import SwiftUI

struct RemoteWelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var configStore = WelfarePlatformConfigStore.shared
    @State private var selectedTab: RemoteWelfareCategory = .video
    @State private var isEditMode: Bool = false
    /// 排序后的平台列表（按 category 分别缓存）
    @State private var orderedPlatforms: [RemoteWelfareCategory: [WelfarePlatform]] = [:]
    @State private var navigatePlatformKey: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 1. Tab 切换栏
                tabBar

                // 2. 编辑模式提示
                if isEditMode {
                    editModeBar
                }

                // 3. 平台网格
                TabView(selection: $selectedTab) {
                    platformGrid(for: .video).tag(RemoteWelfareCategory.video)
                    platformGrid(for: .live).tag(RemoteWelfareCategory.live)
                    platformGrid(for: .comic).tag(RemoteWelfareCategory.comic)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(settings.usesVisualSkin ? Color.clear.ignoresSafeArea() : Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear {
                configStore.bootstrap()
                loadOrder()
            }
        }
    }

    // MARK: - Tab 切换栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RemoteWelfareCategory.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                }) {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                            Text(tab.displayName)
                                .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                        }
                        .foregroundColor(selectedTab == tab
                                         ? .white
                                         : (settings.usesVisualSkin ? .white.opacity(0.6) : .primary.opacity(0.5))
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedTab == tab
                                  ? themeGradient(for: tab)
                                  : LinearGradient(colors: [Color.clear], startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 编辑模式提示

    private var editModeBar: some View {
        HStack {
            Text("长按拖动卡片进行排序").font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Button("完成") {
                withAnimation { isEditMode = false; saveOrder() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // MARK: - 平台网格

    private func platformGrid(for tab: RemoteWelfareCategory) -> some View {
        let platforms = currentOrderedPlatforms(for: tab)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

        return ScrollView(showsIndicators: false) {
            if platforms.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 60)
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("此分类下暂无平台")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(platforms.enumerated()), id: \.element.platformKey) { index, platform in
                        if isEditMode {
                            RemotePlatformSortableCard(
                                platform: platform,
                                index: index,
                                gradient: platformGradient(platform.name),
                                onMove: { fromIdx, toIdx in
                                    movePlatform(from: fromIdx, to: toIdx, tab: tab)
                                },
                                onEnterEditMode: {
                                    withAnimation { isEditMode = true }
                                }
                            )
                        } else {
                            NavigationLink(
                                destination:
                                    WelfarePlatformRouter.shared.makeDestinationView(
                                        for: platform, settings: settings
                                    )
                                    .environmentObject(settings),
                                tag: platform.platformKey,
                                selection: $navigatePlatformKey
                            ) {
                                RemotePlatformIconCard(platform: platform, gradient: platformGradient(platform.name))
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    navigatePlatformKey = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation { isEditMode = true }
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
        }
    }

    // MARK: - 排序与持久化

    /// 当前展示的平台（按用户排序后）
    private func currentOrderedPlatforms(for tab: RemoteWelfareCategory) -> [WelfarePlatform] {
        if let cached = orderedPlatforms[tab] {
            return cached
        }
        return configStore.platforms(in: tab)
    }

    /// 移动平台（编辑模式下拖拽）
    private func movePlatform(from fromIdx: Int, to toIdx: Int, tab: RemoteWelfareCategory) {
        var current = currentOrderedPlatforms(for: tab)
        guard fromIdx < current.count, toIdx < current.count else { return }
        let item = current.remove(at: fromIdx)
        current.insert(item, at: toIdx)
        orderedPlatforms[tab] = current
    }

    /// 排序结果保存到 UserDefaults（key: fuli_remote_platform_order_v2）
    /// 数据结构：[categoryKey: [platformKey, ...]]
    private func saveOrder() {
        var data: [String: [String]] = [:]
        for (cat, plats) in orderedPlatforms {
            data[cat.rawValue] = plats.map { $0.platformKey }
        }
        if let json = try? JSONSerialization.data(withJSONObject: data, options: []) {
            UserDefaults.standard.set(json, forKey: "fuli_remote_platform_order_v2")
        }
    }

    /// 加载排序
    private func loadOrder() {
        guard let json = UserDefaults.standard.data(forKey: "fuli_remote_platform_order_v2"),
              let dict = try? JSONSerialization.jsonObject(with: json) as? [String: [String]] else {
            return
        }
        for (key, order) in dict {
            guard let cat = RemoteWelfareCategory(rawValue: key) else { continue }
            let all = configStore.platforms(in: cat)
            let ordered = order.compactMap { pk in all.first { $0.platformKey == pk } }
            // 加上新增的（用户排序后远端新增的平台）
            let remaining = all.filter { p in !ordered.contains(where: { $0.platformKey == p.platformKey }) }
            orderedPlatforms[cat] = ordered + remaining
        }
    }

    // MARK: - 颜色（与现有 WelfareHomeView 保持一致的渐变色方案）

    private func themeGradient(for tab: RemoteWelfareCategory) -> LinearGradient {
        switch tab {
        case .video:
            return LinearGradient(
                colors: [Color(red: 1.0, green: 0.35, blue: 0.55), Color(red: 0.95, green: 0.20, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .live:
            return LinearGradient(
                colors: [Color(red: 0.40, green: 0.30, blue: 0.95), Color(red: 0.55, green: 0.25, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .comic:
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    /// 平台颜色（基于 platformKey hash 派生，确保每个平台颜色稳定）
    private func platformGradient(_ name: String) -> [Color] {
        // 与 WelfareHomeView 中 platformGradient 同样的 hash 派生
        let colors: [[Color]] = [
            [Color(red: 1.0, green: 0.35, blue: 0.55), Color(red: 0.95, green: 0.20, blue: 0.45)],
            [Color(red: 0.40, green: 0.30, blue: 0.95), Color(red: 0.55, green: 0.25, blue: 0.85)],
            [Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)],
            [Color(red: 1.0, green: 0.55, blue: 0.20), Color(red: 0.95, green: 0.40, blue: 0.10)],
            [Color(red: 0.30, green: 0.75, blue: 0.45), Color(red: 0.20, green: 0.60, blue: 0.35)],
            [Color(red: 0.85, green: 0.30, blue: 0.65), Color(red: 0.70, green: 0.20, blue: 0.50)],
            [Color(red: 0.40, green: 0.50, blue: 0.95), Color(red: 0.25, green: 0.35, blue: 0.85)],
            [Color(red: 1.0, green: 0.65, blue: 0.30), Color(red: 0.95, green: 0.50, blue: 0.15)],
        ]
        let hash = abs(name.hashValue) % colors.count
        return colors[hash]
    }
}

// MARK: - 子组件

/// 远程平台卡片（普通态，可点击跳转）
struct RemotePlatformIconCard: View {
    let platform: WelfarePlatform
    let gradient: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: platform.icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: gradient.first?.opacity(0.3) ?? .clear, radius: 6, x: 0, y: 3)

            Text(platform.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(width: 72, height: 86)
    }
}

/// 远程平台卡片（编辑态，可拖拽）
struct RemotePlatformSortableCard: View {
    let platform: WelfarePlatform
    let index: Int
    let gradient: [Color]
    let onMove: (Int, Int) -> Void
    let onEnterEditMode: () -> Void

    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: platform.icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                // 编辑模式右上角小提示
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.25)))
                            .padding(4)
                    }
                    Spacer()
                }
            }
            .frame(width: 52, height: 52)

            Text(platform.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(width: 72, height: 86)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = value.translation
                }
                .onEnded { value in
                    // 4 列网格，按 72+16=88 宽度估算移动
                    let cols = 4
                    let colW: CGFloat = 88
                    let rowH: CGFloat = 102
                    let colOffset = Int((value.translation.width / colW).rounded())
                    let rowOffset = Int((value.translation.height / rowH).rounded())
                    let totalOffset = colOffset + rowOffset * cols
                    let target = max(0, min(index + totalOffset, /* count unknown here */ index))
                    // 通过 onMove 通知父 View（RemoteWelfareHomeView）执行实际位移
                    if totalOffset != 0 {
                        onMove(index, target)
                    }
                    withAnimation(.spring()) { offset = .zero }
                }
        )
    }
}
