import SwiftUI

// MARK: - 推送播放主视图
struct PushPlayView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PushPlayStore.shared
    
    @State private var showAddSheet = false
    @State private var selectedVideo: VodItem? = nil
    
    var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }
    
    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                if store.items.isEmpty {
                    emptyStateView
                } else {
                    listView
                }
            }
            .navigationTitle("推送播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundColor(accentColor)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showAddSheet = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(accentColor)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddPushPlayLinkView(accentColor: accentColor)
                    .environmentObject(store)
            }
            .fullScreenCover(item: $selectedVideo) { video in
                VideoDetailView(video: video)
            }
        }
    }
    
    // MARK: - 空状态
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            
            Text("暂无推送链接")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(textColor)
            
            Text("点击右上角 + 添加网盘或播放链接")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            Button(action: {
                showAddSheet = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加链接")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(accentColor)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 列表视图
    
    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.items) { item in
                    itemCard(for: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
    
    private func itemCard(for item: PushPlayItem) -> some View {
        HStack(spacing: 12) {
            // 类型图标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Image(systemName: item.type.iconName)
                    .font(.system(size: 22))
                    .foregroundColor(accentColor)
            }
            
            // 信息区
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                
                Text(item.url)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(item.type.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(0.15))
                        .cornerRadius(4)
                    
                    if let episodes = item.episodes, !episodes.isEmpty {
                        Text("\(episodes.count) 集")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 播放按钮
            Button(action: {
                playItem(item)
            }) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
        .contextMenu {
            Button(role: .destructive, action: {
                store.removeItem(item)
            }) {
                Label("删除", systemImage: "trash")
            }
        }
    }
    
    // MARK: - 播放逻辑
    
    private func playItem(_ item: PushPlayItem) {
        let vodItem = makeVodItem(from: item)
        selectedVideo = vodItem
    }
    
    private func makeVodItem(from item: PushPlayItem) -> VodItem {
        let remarks: String
        switch item.type {
        case .cloudDrive:
            remarks = "☁️网盘 - \(item.title)"
        case .directPlay:
            remarks = "🎬 直链播放"
        case .webParse:
            remarks = "🌐 网页解析"
        }
        
        // 如果有解析好的剧集，构造包含剧集信息的 playUrl
        var playUrl: String? = nil
        if let episodes = item.episodes, !episodes.isEmpty {
            // 格式: 集名$URL#集名$URL$$$线路名
            let episodeStr = episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
            playUrl = episodeStr
        }
        
        return VodItem(
            vodId: item.url,
            vodName: item.title,
            vodPic: "",
            vodRemarks: remarks,
            vodPlayFrom: item.type.displayName,
            vodPlayUrl: playUrl
        )
    }
}

// MARK: - 添加链接弹窗

struct AddPushPlayLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: PushPlayStore
    
    let accentColor: Color
    
    @State private var titleInput: String = ""
    @State private var urlInput: String = ""
    @State private var selectedType: PushPlayLinkType = .cloudDrive
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 头部提示
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(accentColor)
                        Text("支持网盘链接、直链播放地址、网页视频地址")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    
                    // 链接类型选择
                    VStack(alignment: .leading, spacing: 8) {
                        Text("链接类型")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 8) {
                            ForEach(PushPlayLinkType.allCases, id: \.self) { type in
                                Button(action: {
                                    selectedType = type
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: type.iconName)
                                            .font(.system(size: 12))
                                        Text(type.displayName)
                                            .font(.system(size: 13))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedType == type ? accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                    )
                                    .foregroundColor(selectedType == type ? accentColor : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // 标题输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("标题（可选）")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                        
                        TextField("自动识别，可自定义", text: $titleInput)
                            .font(.system(size: 15))
                            .padding()
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(10)
                    }
                    
                    // URL输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("链接地址")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                        
                        TextEditor(text: $urlInput)
                            .font(.system(size: 14))
                            .frame(minHeight: 100)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(10)
                        
                        if showError {
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .transition(.opacity)
                        }
                        
                        // 自动识别按钮
                        Button(action: {
                            autoDetectType()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "wand.and.stars")
                                Text("自动识别类型")
                            }
                            .font(.system(size: 13))
                            .foregroundColor(accentColor)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        
                        // 快捷示例
                        VStack(alignment: .leading, spacing: 6) {
                            Text("支持格式示例：")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            
                            Text("• 网盘：阿里云盘、夸克、百度网盘、115等分享链接")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("• 直链：.m3u8 / .mp4 / .flv 等视频地址")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("• 网页：视频详情页URL（将自动解析）")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("添加推送链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        saveAndDismiss()
                    }) {
                        Text("添加")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(accentColor)
                    }
                }
            }
        }
    }
    
    private func autoDetectType() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        selectedType = PushPlayStore.detectType(for: url)
    }
    
    private func saveAndDismiss() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !url.isEmpty else {
            errorMessage = "请输入链接地址"
            showError = true
            return
        }
        
        guard URL(string: url) != nil else {
            errorMessage = "链接格式不正确"
            showError = true
            return
        }
        
        store.addItem(title: title, url: url, type: selectedType)
        dismiss()
    }
}
