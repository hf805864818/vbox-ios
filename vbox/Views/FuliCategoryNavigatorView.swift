//
//  FuliCategoryNavigatorView.swift
//  vbox
//
//  福利平台分类导航弹窗 — 三步合一：
//  1. 基础版：Popover + 网格/列表自适应布局
//  2. 二级分类：点击含子分类的项后展开/进入二级选择
//  3. 智能切换：分类数量自动选择展示方式（≤12 列表 / 13-30 网格 / >30 Sheet+搜索）
//
//  由 FuliPlatformMainView 通过 popover 或 sheet 调用，
//  点击分类后通过 onSelect 回调通知父视图切换 Tab。
//

import SwiftUI

// MARK: - 展示模式
enum FuliCategoryNavMode {
    case list       // 单列列表（≤12 个分类）
    case grid       // 三列网格（13-30 个分类）
    case searchSheet // 底部 Sheet + 搜索框（>30 个分类）
}

// MARK: - 分类导航弹窗（主入口）
/// 福利平台分类导航视图
/// - Parameters:
///   - categories: 全部分类（一级）
///   - selectedIndex: 当前选中的一级分类索引（Binding）
///   - onSelect: 选中一级分类后的回调（参数为索引）
///   - onSelectSub: 选中二级分类后的回调（可选，参数为 一级索引 + 二级分类）
///   - onDismiss: 关闭弹窗的回调
struct FuliCategoryNavigatorView: View {
    let categories: [FuliCategory]
    @Binding var selectedIndex: Int
    var onSelect: (Int) -> Void
    var onSelectSub: ((Int, FuliCategory) -> Void)?
    var onDismiss: () -> Void = {}

    // 二级分类展开状态
    @State private var expandedIndex: Int? = nil
    // 搜索关键字（searchSheet 模式用）
    @State private var searchText: String = ""

    /// 根据分类数量自动选择展示模式
    private var mode: FuliCategoryNavMode {
        let count = categories.count
        if count <= 12 {
            return .list
        } else if count <= 30 {
            return .grid
        } else {
            return .searchSheet
        }
    }

    /// 过滤后的分类列表（搜索模式用）
    private var filteredCategories: [FuliCategory] {
        if searchText.isEmpty {
            return categories
        }
        return categories.filter {
            $0.typeName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索框（仅 searchSheet 模式显示）
                if mode == .searchSheet {
                    searchBar
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }

                // 列表/网格内容
                switch mode {
                case .list, .searchSheet:
                    listContent
                case .grid:
                    gridContent
                }
            }
            .navigationTitle("全部分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        onDismiss()
                    }
                    .font(.system(size: 15))
                }
            }
        }
        .frame(
            width: mode == .searchSheet ? nil : 320,
            height: navigatorHeight
        )
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - 列表内容（list + searchSheet 模式共用）
    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(filteredCategories.enumerated()), id: \.offset) { idx, cat in
                    categoryRow(cat, index: idx, originalIndex: originalIndex(of: cat))
                }
                if filteredCategories.isEmpty {
                    Text("未找到相关分类")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(12)
        }
    }

    // MARK: - 网格内容（grid 模式）
    private var gridContent: some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                    gridItem(cat, index: idx)
                }
            }
            .padding(12)
        }
    }

    private func gridItem(_ category: FuliCategory, index: Int) -> some View {
        let hasSub = (category.subCategories?.count ?? 0) > 0
        let isSelected = selectedIndex == index

        return Button {
            if hasSub {
                // 有二级分类：切换到列表模式展开（通过状态切换）
                // 简化：有子分类的网格项点击直接选中一级，二级在下方 Tab 栏选择
                onSelect(index)
                onDismiss()
            } else {
                onSelect(index)
                onDismiss()
            }
        } label: {
            VStack(spacing: 2) {
                Text(category.typeName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if hasSub {
                    Text("\(category.subCategories!.count) 个子类")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.12)
                          : Color(UIColor.secondarySystemBackground))
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 单行分类（列表模式）
    private func categoryRow(_ category: FuliCategory, index: Int, originalIndex: Int) -> some View {
        let hasSub = (category.subCategories?.count ?? 0) > 0
        let isExpanded = expandedIndex == originalIndex
        let isSelected = selectedIndex == originalIndex

        return VStack(spacing: 0) {
            Button {
                if hasSub {
                    // 有二级分类：展开/收起
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedIndex = isExpanded ? nil : originalIndex
                    }
                } else {
                    // 无二级分类：直接选中
                    onSelect(originalIndex)
                    onDismiss()
                }
            } label: {
                HStack(spacing: 10) {
                    // 选中指示器
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(width: 6, height: 6)

                    Text(category.typeName)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .accentColor : .primary)
                        .lineLimit(1)

                    Spacer()

                    // 子分类数量 / 展开箭头
                    if hasSub {
                        HStack(spacing: 4) {
                            Text("\(category.subCategories!.count)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)

            // 展开的二级分类
            if hasSub && isExpanded {
                subCategoryList(category, parentIndex: originalIndex)
                    .padding(.leading, 20)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - 二级分类列表
    private func subCategoryList(_ parent: FuliCategory, parentIndex: Int) -> some View {
        let subs = parent.subCategories ?? []
        return VStack(spacing: 2) {
            // "全部" 选项
            Button {
                onSelect(parentIndex)
                onDismiss()
            } label: {
                HStack(spacing: 8) {
                    Text("全部")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)

            ForEach(subs) { sub in
                Button {
                    onSelect(parentIndex)
                    onSelectSub?(parentIndex, sub)
                    onDismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text(sub.typeName)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 辅助方法
    /// 根据分类查找原始索引（搜索过滤后用）
    private func originalIndex(of category: FuliCategory) -> Int {
        categories.firstIndex(where: { $0.typeId == category.typeId }) ?? 0
    }

    /// 弹窗高度自适应
    private var navigatorHeight: CGFloat {
        let count = categories.count
        switch mode {
        case .list:
            return min(CGFloat(count) * 44 + 24 + 40, 400)
        case .grid:
            let rows = ceil(Double(count) / 3.0)
            return min(rows * 50 + 60 + 24, 420)
        case .searchSheet:
            return 500 // searchSheet 模式由外部 sheet 的 detents 控制
        }
    }
}

// MARK: - 对外扩展：判断是否应该用 sheet 展示
extension FuliCategory {
    /// 分类数量是否超过 popover 适用范围
    static func shouldUseSheet(for categories: [FuliCategory]) -> Bool {
        categories.count > 30
    }
}
