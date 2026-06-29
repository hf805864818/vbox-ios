import SwiftUI

struct ShortDramaView: View {
    @StateObject private var dramaService = ShortDramaService.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [VodItem] = []
    @State private var selectedDrama: VodItem?
    @State private var showDetail = false
    @State private var showSourcePicker = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("搜索短剧", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .onSubmit { performSearch() }
                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                                isSearching = false
                                searchResults = []
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    
                    // 源选择
                    Button(action: { showSourcePicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 14))
                            Text(selectedSourceName)
                                .font(.system(size: 13))
                        }
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(accentColor.opacity(0.12))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                // 源标签滚动条
                if !dramaService.shortDramaSources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(dramaService.shortDramaSources) { source in
                                Button(action: {
                                    dramaService.selectedSourceId = source.id
                                    Task { await dramaService.fetchDramas(refresh: true) }
                                }) {
                                    Text("\(source.name)(\(source.categoryName))")
                                        .font(.system(size: 12))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(dramaService.selectedSourceId == source.id ? accentColor : Color.gray.opacity(0.12))
                                        .foregroundColor(dramaService.selectedSourceId == source.id ? .white : .primary)
                                        .cornerRadius(14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                
                // 内容区
                ZStack {
                    if dramaService.isLoading && dramaService.dramas.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("正在加载短剧...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    } else if dramaService.shortDramaSources.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "play.slash")
                                .font(.system(size: 50))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("未检测到短剧源")
                                .font(.system(size: 16))
                            Text("请在设置中添加包含短剧的订阅源")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 80)
                    } else if isSearching {
                        searchResultsView
                    } else {
                        dramaGridView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
            .navigationTitle("短剧")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSourcePicker) {
                sourcePickerSheet
            }
            .sheet(item: $selectedDrama) { drama in
                ShortDramaDetailView(drama: drama)
            }
            .onAppear {
                if dramaService.shortDramaSources.isEmpty {
                    Task {
                        await dramaService.scanShortDramaSources(from: SpiderManager.shared.allSites)
                        await dramaService.fetchDramas()
                    }
                } else if dramaService.dramas.isEmpty {
                    Task { await dramaService.fetchDramas() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .spiderSitesDidUpdate)) { _ in
                Task {
                    await dramaService.scanShortDramaSources(from: SpiderManager.shared.allSites)
                    if dramaService.dramas.isEmpty {
                        await dramaService.fetchDramas()
                    }
                }
            }
        }
    }
    
    // MARK: - 短剧网格视图
    
    private var dramaGridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 16) {
                ForEach(dramaService.dramas) { drama in
                    DramaCardView(drama: drama)
                        .onTapGesture {
                            selectedDrama = drama
                        }
                        .onAppear {
                            if drama.id == dramaService.dramas.last?.id, dramaService.hasMore {
                                Task { await dramaService.fetchDramas(page: dramaService.currentPage + 1) }
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 90)
            
            if dramaService.isLoading {
                ProgressView()
                    .padding()
            }
            
            if let count = dramaService.shortDramaSources.first?.totalCount {
                Text("共 \(count) 部短剧")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .refreshable {
            await dramaService.fetchDramas(refresh: true)
        }
    }
    
    // MARK: - 搜索结果视图
    
    private var searchResultsView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 16) {
                ForEach(searchResults) { drama in
                    DramaCardView(drama: drama)
                        .onTapGesture {
                            selectedDrama = drama
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 90)
            
            if searchResults.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("未找到相关短剧")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 60)
            }
        }
    }
    
    // MARK: - 源选择弹窗
    
    private var sourcePickerSheet: some View {
        NavigationStack {
            List {
                Button(action: {
                    dramaService.selectedSourceId = nil
                    Task { await dramaService.fetchDramas(refresh: true) }
                    showSourcePicker = false
                }) {
                    HStack {
                        Text("全部源")
                            .foregroundColor(.primary)
                        Spacer()
                        if dramaService.selectedSourceId == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(accentColor)
                        }
                    }
                }
                
                ForEach(dramaService.shortDramaSources) { source in
                    Button(action: {
                        dramaService.selectedSourceId = source.id
                        Task { await dramaService.fetchDramas(refresh: true) }
                        showSourcePicker = false
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(source.name) (\(source.categoryName))")
                                    .foregroundColor(.primary)
                                Text("ID: \(source.categoryId) · \(source.totalCount)部")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if dramaService.selectedSourceId == source.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择短剧源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { showSourcePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    // MARK: - 搜索
    
    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        Task {
            searchResults = await dramaService.search(keyword: searchText)
        }
    }
    
    // MARK: - 辅助
    
    private var selectedSourceName: String {
        guard let id = dramaService.selectedSourceId,
              let source = dramaService.shortDramaSources.first(where: { $0.id == id }) else {
            return "全部(\(dramaService.shortDramaSources.count)源)"
        }
        return "\(source.name)"
    }
    
    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }
}

// MARK: - 短剧卡片

struct DramaCardView: View {
    let drama: VodItem
    @EnvironmentObject private var settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 封面图
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: drama.vodPic)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(2.0/3.0, contentMode: .fill)
                    case .failure:
                        ZStack {
                            Color.gray.opacity(0.2)
                            VStack(spacing: 4) {
                                Image(systemName: "play.slash")
                                    .foregroundColor(.gray)
                                Text("加载失败")
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                            }
                        }
                    case .empty:
                        ZStack {
                            Color.gray.opacity(0.1)
                            ProgressView()
                        }
                    @unknown default:
                        Color.gray.opacity(0.2)
                    }
                }
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let remarks = drama.vodRemarks, !remarks.isEmpty {
                    Text(remarks.replacingOccurrences(of: "^.*?· ", with: "", options: .regularExpression))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            
            Text(drama.vodName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundColor(textColor)
            
            if let remarks = drama.vodRemarks {
                Text(remarks)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }
}

// MARK: - 预览

#Preview {
    ShortDramaView()
        .environmentObject(AppSettings())
}
