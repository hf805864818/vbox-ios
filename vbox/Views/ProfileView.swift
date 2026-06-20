import SwiftUI
import PhotosUI

// MARK: - ProfileView

struct ProfileView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var isLoggedIn: Bool = false
    @State private var username: String = ""
    @State private var avatarImage: Image? = nil
    @State private var showLoginSheet: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var historyRecords: [HistoryRecord] = []
    @State private var showWatchHistory: Bool = false
    @State private var showFavorites: Bool = false
    @State private var showDownloads: Bool = false

    var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }

    var backgroundColor: some View {
        if settings.usesVisualSkin {
            return Color.clear.background(.ultraThinMaterial)
        } else {
            return Color(uiColor: .systemBackground)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: 头部登录区
                loginSection

                // MARK: 观看记录模块
                watchHistorySection

                // MARK: 三大功能入口
                featureEntriesSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(backgroundColor)
        .onAppear {
            loadInitialState()
            reloadHistory()
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginSheetView(
                isLoggedIn: $isLoggedIn,
                username: $username,
                isPresented: $showLoginSheet
            )
        }
        .sheet(isPresented: $showWatchHistory) {
            NavigationView {
                WatchHistoryView()
            }
        }
        .sheet(isPresented: $showFavorites) {
            NavigationView {
                FavoriteView()
            }
        }
        .sheet(isPresented: $showDownloads) {
            NavigationView {
                DownloadView()
            }
        }
        .onChange(of: selectedPhotoItem) { _ in
            handlePhotoSelection()
        }
    }

    // MARK: - 头部登录区

    private var loginSection: some View {
        VStack(spacing: 12) {
            // 头像
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                ZStack {
                    if let avatarImage = avatarImage {
                        avatarImage
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                    } else if isLoggedIn && !username.isEmpty {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 80, height: 80)
                            .overlay(
                                Text(String(username.prefix(1)))
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.white)
                            )
                    } else {
                        Image(systemName: "person.crop.circle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .foregroundColor(.gray)
                    }
                }
            }

            // 用户名
            Text(isLoggedIn ? username : "未登录")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(textColor)

            // 登录按钮
            if !isLoggedIn {
                Button(action: {
                    showLoginSheet = true
                }) {
                    Text("点击登录")
                        .font(.system(size: 15))
                        .foregroundColor(accentColor)
                        .frame(width: 200, height: 44)
                        .background(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                        .cornerRadius(22)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    // MARK: - 观看记录模块

    private var watchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 3, height: 16)
                        .cornerRadius(2)
                    Text("观看记录")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(textColor)
                }

                Spacer()

                Button(action: {
                    showWatchHistory = true
                }) {
                    Text("查看更多 >")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }

            // 横向滚动封面列表
            if historyRecords.isEmpty {
                Text("暂无观看记录")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(historyRecords) { record in
                            VStack(spacing: 4) {
                                coverImage(urlString: record.imgurl)
                                    .frame(width: 100, height: 140)
                                    .cornerRadius(8)
                                    .clipped()

                                Text(record.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(textColor)
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 三大功能入口

    private var featureEntriesSection: some View {
        HStack(spacing: 12) {
            // 我的收藏
            Button(action: {
                showFavorites = true
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 24))
                        .foregroundColor(accentColor)
                    Text("我的收藏")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(settings.usesVisualSkin ? 0.12 : 0.08))
                )
            }

            // 分享免广告
            Button(action: {
                print("[ProfileView] 分享免广告功能暂未开放")
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 24))
                        .foregroundColor(accentColor)
                    Text("分享免广告")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(settings.usesVisualSkin ? 0.12 : 0.08))
                )
            }

            // 下载管理
            Button(action: {
                showDownloads = true
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(accentColor)
                    Text("下载管理")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(settings.usesVisualSkin ? 0.12 : 0.08))
                )
            }
        }
    }

    // MARK: - Helper Methods

    private func coverImage(urlString: String) -> some View {
        Group {
            if urlString.isEmpty {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            } else {
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                }
            }
        }
    }

    private func loadInitialState() {
        if let savedUsername = DatabaseManager.shared.getSetting(key: "username"),
           !savedUsername.isEmpty {
            username = savedUsername
        }
        if let savedLoggedIn = DatabaseManager.shared.getSetting(key: "isLoggedIn"),
           savedLoggedIn == "true" {
            isLoggedIn = true
        }
    }

    private func reloadHistory() {
        let allHistory = DatabaseManager.shared.queryHistory()
        historyRecords = Array(allHistory.prefix(20))
    }

    private func handlePhotoSelection() {
        guard let item = selectedPhotoItem else { return }
        item.loadTransferable(type: Data.self) { result in
            DispatchQueue.main.async {
                if case .success(let data) = result, let data = data, let uiImage = UIImage(data: data) {
                    avatarImage = Image(uiImage: uiImage)
                }
            }
        }
    }
}

// MARK: - LoginSheetView

struct LoginSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var isLoggedIn: Bool
    @Binding var username: String
    @Binding var isPresented: Bool
    @State private var inputUsername: String = ""

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
        VStack(spacing: 24) {
            Text("登录")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(textColor)
                .padding(.top, 20)

            TextField("请输入用户名", text: $inputUsername)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button(action: {
                    isPresented = false
                }) {
                    Text("取消")
                        .font(.system(size: 16))
                        .foregroundColor(textColor)
                        .frame(width: 120, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(Color.gray.opacity(0.2))
                        )
                }

                Button(action: {
                    performLogin()
                }) {
                    Text("确认")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 120, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(accentColor)
                        )
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(settings.usesVisualSkin ? Color(UIColor.systemGray6) : Color(uiColor: .secondarySystemBackground))
        .cornerRadius(16)
    }

    private func performLogin() {
        let trimmed = inputUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        username = trimmed
        isLoggedIn = true
        DatabaseManager.shared.setSetting(key: "username", value: trimmed)
        DatabaseManager.shared.setSetting(key: "isLoggedIn", value: "true")
        isPresented = false
    }
}

// MARK: - WatchHistoryView

struct WatchHistoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode
    @State private var historyRecords: [HistoryRecord] = []

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
        List {
            if historyRecords.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text("暂无观看记录")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(historyRecords) { record in
                    HStack(spacing: 12) {
                        coverThumbnail(urlString: record.imgurl)
                            .frame(width: 60, height: 80)
                            .cornerRadius(6)
                            .clipped()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(textColor)
                                .lineLimit(1)

                            if !record.laiyuan.isEmpty {
                                Text(record.laiyuan)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }

                            Text(formatDate(record.lastPlayedAt))
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle("观看记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(settings.usesVisualSkin ? .dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(textColor)
                }
            }

            if !historyRecords.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        DatabaseManager.shared.clearHistory()
                        historyRecords = []
                    }) {
                        Text("清空")
                            .foregroundColor(accentColor)
                    }
                }
            }
        }
        .onAppear {
            historyRecords = DatabaseManager.shared.queryHistory()
        }
    }

    private func coverThumbnail(urlString: String) -> some View {
        Group {
            if urlString.isEmpty {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            } else {
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                }
            }
        }
    }

    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - FavoriteView

struct FavoriteView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode
    @State private var favorites: [FavoriteRecord] = []

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
        List {
            if favorites.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text("暂无收藏")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(favorites) { record in
                    HStack(spacing: 12) {
                        coverThumbnail(urlString: record.imgurl)
                            .frame(width: 60, height: 80)
                            .cornerRadius(6)
                            .clipped()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(textColor)
                                .lineLimit(1)

                            if !record.laiyuan.isEmpty {
                                Text(record.laiyuan)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(settings.usesVisualSkin ? .dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(textColor)
                }
            }

            if !favorites.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        for record in favorites {
                            if let id = record.id {
                                DatabaseManager.shared.removeFavorite(id: id)
                            }
                        }
                        favorites = []
                    }) {
                        Text("清空")
                            .foregroundColor(accentColor)
                    }
                }
            }
        }
        .onAppear {
            favorites = DatabaseManager.shared.queryFavorites()
        }
    }

    private func coverThumbnail(urlString: String) -> some View {
        Group {
            if urlString.isEmpty {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            } else {
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                }
            }
        }
    }
}

// MARK: - DownloadView

struct DownloadView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode

    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("暂无下载内容")
                .font(.system(size: 14))
                .foregroundColor(.gray)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(settings.usesVisualSkin ? .dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(textColor)
                }
            }
        }
    }
}
