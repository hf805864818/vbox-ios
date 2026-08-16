//
//  FuliCategoryNavigatorView.swift
//  vbox
//
//  福利平台分类导航 — 悬浮弹窗样式
//  - 半透明黑色背景 + 白色圆角卡片
//  - 4 列网格布局，上下滑动查看更多
//  - 点击分类自动关闭 + Tab 栏滚动定位
//  - 支持二级分类展开
//
//  使用方式：作为 .overlay 覆盖在页面上，通过 @Binding 控制显隐
//

import SwiftUI

// MARK: - 分类导航悬浮弹窗
struct FuliCategoryNavigatorView: View {
    let categories: [FuliCategory]
    @Binding var selectedIndex: Int
    var onSelect: (Int) -> Void
    var onSelectSub: ((Int, FuliCategory) -> Void)?
    var onDismiss: () -> Void = {}

    @State private var expandedIndex: Int? = nil
    @State private var searchText: String = ""

    /// 是否需要搜索框（分类 > 30 个时显示）
    private var showSearch: Bool {
        categories.count > 30
    }

    /// 过滤后的分类
    private var filteredCategories: [FuliCategory] {
        if searchText.isEmpty {
            return categories
        }
        return categories.filter {
            $0.typeName.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 4 列网格布局
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ZStack {
            // 半透明背景
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
                .transition(.opacity)

            // 弹窗卡片
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("全部分类")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                // 搜索框（分类 > 30 个时显示）
                if showSearch {
                    searchBar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }

                Divider()

                // 分类网格
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(filteredCategories.enumerated()), id: \.offset) { idx, cat in
                            gridItem(cat, index: originalIndex(of: cat))
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.55)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.systemBackground))
            )
            .padding(.horizontal, 16)
            .frame(maxWidth: 520)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .animation(.easeInOut(duration: 0.2), value: true)
    }

    // MARK: - 搜索框
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
            TextField("搜索分类", text: $searchText)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - 单个分类格子
    private func gridItem(_ category: FuliCategory, index: Int) -> some View {
        let hasSub = (category.subCategories?.count ?? 0) > 0
        let isSelected = selectedIndex == index

        return Button {
            if hasSub {
                // 有二级分类：展开/收起（用动画）
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedIndex = (expandedIndex == index) ? nil : index
                }
            } else {
                // 直接选中
                onSelect(index)
                onDismiss()
            }
        } label: {
            VStack(spacing: 4) {
                Text(category.typeName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if hasSub {
                    Text("\(category.subCategories!.count)子类")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.12)
                          : Color(UIColor.secondarySystemBackground))
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 辅助方法
    private func originalIndex(of category: FuliCategory) -> Int {
        categories.firstIndex(where: { $0.typeId == category.typeId }) ?? 0
    }
}

// MARK: - 横向分类 Tab 滚动定位辅助
/// 包装分类 Tab 栏，支持 ScrollViewReader 自动滚动到选中项
struct FuliCategoryTabBar: View {
    let categories: [FuliCategory]
    @Binding var selectedTab: Int
    var onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                        tabButton(title: cat.typeName, isSelected: selectedTab == idx) {
                            withAnimation {
                                selectedTab = idx
                                onSelect(idx)
                            }
                        }
                        .id(idx)  // 用于 ScrollViewReader 定位
                    }
                    // 搜索 Tab
                    tabButton(title: "搜索", isSelected: selectedTab == categories.count) {
                        withAnimation {
                            selectedTab = categories.count
                            onSelect(categories.count)
                        }
                    }
                    .id(categories.count)
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 44)
            .onChange(of: selectedTab) { newValue in
                // 选中变化时自动滚动到对应位置
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func tabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.horizontal, 12)
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 20, height: 3)
            }
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }
}
