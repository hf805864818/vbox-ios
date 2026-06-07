import SwiftUI

// MARK: - 豆瓣首页视图
struct DoubanHomeView: View {
    @StateObject private var doubanService = DoubanService.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var isLoading = true
    @State private var bannerSubjects: [DoubanSubject] = []
    @State private var hotMovies: [DoubanSubject] = []
    @State private var hotTV: [DoubanSubject] = []
    @State private var hotVariety: [DoubanSubject] = []
    @State private var top250: [DoubanSubject] = []
    @State private var currentIndex = 0
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                // Banner轮播
                if !bannerSubjects.isEmpty {
                    BannerCarousel(subjects: bannerSubjects, currentIndex: $currentIndex)
                }
                
                // 分类磁贴 - 1行横向滚动
                CategoryTilesView()
                
                // 热门推荐
                if !hotMovies.isEmpty {
                    SectionHeader(title: "热门电影", icon: "flame.fill")
                    HorizontalSubjectRow(subjects: hotMovies)
                }
                
                // TOP250
                if !top250.isEmpty {
                    SectionHeader(title: "TOP250", icon: "crown.fill")
                    HorizontalSubjectRow(subjects: top250)
                }
                
                // 热门剧集
                if !hotTV.isEmpty {
                    SectionHeader(title: "热门剧集", icon: "tv.fill")
                    HorizontalSubjectRow(subjects: hotTV)
                }
                
                // 热门综艺
                if !hotVariety.isEmpty {
                    SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                    HorizontalSubjectRow(subjects: hotVariety)
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color(hex: "000000"))
        .onAppear { loadData() }
    }
    
    private func loadData() {
        isLoading = true
        Task {
            do {
                async let banner = doubanService.fetchTop250(start: 0, count: 10)
                async let movies = doubanService.fetchHotMovies(start: 0, count: 10)
                async let tv = doubanService.fetchHotTV(start: 0, count: 10)
                async let variety = doubanService.fetchHotVariety(start: 0, count: 10)
                async let top = doubanService.fetchTop250(start: 0, count: 10)
                
                bannerSubjects = try await banner
                hotMovies = try await movies
                hotTV = try await tv
                hotVariety = try await variety
                top250 = try await top
            } catch {
                print("Douban API error: \(error)")
            }
            isLoading = false
        }
    }
}

// MARK: - Banner轮播
struct BannerCarousel: View {
    let subjects: [DoubanSubject]
    @Binding var currentIndex: Int
    
    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<min(10, subjects.count), id: \.self) { index in
                BannerCard(subject: subjects[index])
                    .tag(index)
            }
        }
        .frame(height: 320)
        .tabViewStyle(.page(indexDisplayMode: .never))
        
        // 指示点
        HStack(spacing: 8) {
            ForEach(0..<min(10, subjects.count), id: \.self) { index in
                Circle()
                    .fill(currentIndex == index ? Color(hex: "E11D48") : Color.white.opacity(0.3))
                    .frame(width: currentIndex == index ? 8 : 6, height: currentIndex == index ? 8 : 6)
                    .animation(.spring(response: 0.3), value: currentIndex)
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Banner卡片
struct BannerCard: View {
    let subject: DoubanSubject
    @State private var showDetail = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图片
            AsyncImage(url: URL(string: subject.images?.large ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure(_):
                    Rectangle().fill(Color.gray.opacity(0.3))
                case .empty:
                    Rectangle().fill(Color.gray.opacity(0.2))
                @unknown default:
                    Rectangle().fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: UIScreen.main.bounds.width, height: 320)
            .clipped()
            
            // 渐变遮罩
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.5),
                    Color.black.opacity(0.9)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // 信息内容
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(subject.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // 评分
                    if let rating = subject.rating?.ratingValue, rating > 0 {
                        ZStack {
                            Circle()
                                .fill(Color.yellow.opacity(0.9))
                                .frame(width: 40, height: 40)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                        }
                    }
                }
                
                HStack(spacing: 12) {
                    if let year = subject.year {
                        Label(year, systemImage: "calendar")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    if let genres = subject.genres, !genres.isEmpty {
                        Label(genres.joined(separator: "/"), systemImage: "film")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .padding(16)
        }
        .onTapGesture { showDetail = true }
        .fullScreenCover(isPresented: $showDetail) {
            DoubanDetailView(subject: subject)
        }
    }
}

// MARK: - 分类磁贴视图
struct CategoryTilesView: View {
    let categories = [
        ("movie", "🎬", "电影"),
        ("tv", "📺", "剧集"),
        ("variety", "🎭", "综艺"),
        ("top250", "🏆", "榜单"),
        ("animation", "🎨", "动漫"),
        ("hot", "🔥", "热门")
    ]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.0) { item in
                    CategoryTile(icon: item.1, title: item.2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(hex: "0F0F23"))
    }
}

// MARK: - 分类磁贴
struct CategoryTile: View {
    let icon: String
    let title: String
    @State private var showList = false
    
    var body: some View {
        Button(action: { showList = true }) {
            VStack(spacing: 8) {
                Text(icon)
                    .font(.system(size: 32))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: "1A1A2E"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .fullScreenCover(isPresented: $showList) {
            DoubanCategoryListView(category: title)
        }
    }
}

// MARK: - 横向主题行
struct HorizontalSubjectRow: View {
    let subjects: [DoubanSubject]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(subjects) { subject in
                    SubjectCard(subject: subject)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - 主题卡片
struct SubjectCard: View {
    let subject: DoubanSubject
    @State private var showDetail = false
    
    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(alignment: .leading, spacing: 8) {
                // 封面
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: URL(string: subject.images?.large ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure(_):
                            Rectangle().fill(Color.gray.opacity(0.25))
                        case .empty:
                            Rectangle().fill(Color.gray.opacity(0.15))
                        @unknown default:
                            Rectangle().fill(Color.gray.opacity(0.25))
                        }
                    }
                    .frame(width: 120, height: 180)
                    .clipped()
                    
                    // 评分
                    if let rating = subject.rating?.ratingValue, rating > 0 {
                        ZStack {
                            Circle()
                                .fill(Color.yellow.opacity(0.9))
                                .frame(width: 32, height: 32)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.black)
                        }
                        .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // 标题
                Text(subject.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .fullScreenCover(isPresented: $showDetail) {
            DoubanDetailView(subject: subject)
        }
    }
}

// MARK: - 分类列表页
struct DoubanCategoryListView: View {
    let category: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var doubanService = DoubanService.shared
    @State private var subjects: [DoubanSubject] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(subjects) { subject in
                        SubjectCard(subject: subject)
                    }
                }
                .padding(16)
            }
            .navigationTitle(category)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .onAppear { loadData() }
        }
    }
    
    private func loadData() {
        isLoading = true
        Task {
            do {
                switch category {
                case "电影":
                    subjects = try await doubanService.fetchHotMovies(start: 0, count: 40)
                case "剧集":
                    subjects = try await doubanService.fetchHotTV(start: 0, count: 40)
                case "综艺":
                    subjects = try await doubanService.fetchHotVariety(start: 0, count: 40)
                case "榜单":
                    subjects = try await doubanService.fetchTop250(start: 0, count: 40)
                case "动漫":
                    subjects = try await doubanService.fetchHotAnimation(start: 0, count: 40)
                case "热门":
                    subjects = try await doubanService.fetchHotMovies(start: 0, count: 40)
                default:
                    subjects = try await doubanService.fetchTop250(start: 0, count: 40)
                }
            } catch {
                print("Error loading category: \(error)")
            }
            isLoading = false
        }
    }
}

// MARK: - 详情页
struct DoubanDetailView: View {
    let subject: DoubanSubject
    @Environment(\.dismiss) private var dismiss
    @State private var showSearch = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 封面
                AsyncImage(url: URL(string: subject.images?.large ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure(_):
                        Rectangle().fill(Color.gray.opacity(0.3))
                    case .empty:
                        Rectangle().fill(Color.gray.opacity(0.2))
                    @unknown default:
                        Rectangle().fill(Color.gray.opacity(0.3))
                    }
                }
                .frame(height: 300)
                
                // 标题和评分
                VStack(spacing: 12) {
                    Text(subject.title)
                        .font(.system(size: 24, weight: .bold))
                        .multilineTextAlignment(.center)
                    
                    if let rating = subject.rating?.ratingValue, rating > 0 {
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                    
                    HStack(spacing: 16) {
                        if let year = subject.year {
                            Text(year)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        if let genres = subject.genres {
                            Text(genres.joined(separator: "/"))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                // 操作按钮
                HStack(spacing: 16) {
                    Spacer()
                    Button(action: { showSearch = true }) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("搜索播放")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color(hex: "E11D48"))
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                
                // 简介
                if let intro = subject.intro, !intro.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("简介")
                            .font(.system(size: 18, weight: .bold))
                        Text(intro)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(Color(hex: "000000"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView()
        }
    }
}

// MARK: - SectionHeader (复用MainViews.swift中的定义)
