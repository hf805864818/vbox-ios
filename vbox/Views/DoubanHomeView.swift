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
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5).padding(.top, 100)
                    }
                } else {
                    if !bannerSubjects.isEmpty {
                        BannerCarousel(subjects: bannerSubjects, currentIndex: $currentIndex, settings: settings)
                    }
                    CategoryTilesView()
                    if !hotMovies.isEmpty {
                        SectionHeader(title: "热门电影", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotMovies, settings: settings)
                    }
                    if !top250.isEmpty {
                        SectionHeader(title: "TOP250", icon: "crown.fill")
                        HorizontalSubjectRow(subjects: top250, settings: settings)
                    }
                    if !hotTV.isEmpty {
                        SectionHeader(title: "热门剧集", icon: "tv.fill")
                        HorizontalSubjectRow(subjects: hotTV, settings: settings)
                    }
                    if !hotVariety.isEmpty {
                        SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                        HorizontalSubjectRow(subjects: hotVariety, settings: settings)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.white)
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
    let settings: AppSettings
    
    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<min(10, subjects.count), id: \.self) { index in
                BannerCard(subject: subjects[index], settings: settings)
                    .tag(index)
            }
        }
        .frame(height: 200)
        .tabViewStyle(.page(indexDisplayMode: .never))
        
        HStack(spacing: 8) {
            ForEach(0..<min(10, subjects.count), id: \.self) { index in
                Circle()
                    .fill(currentIndex == index ? Color(hex: "E11D48") : Color.gray.opacity(0.3))
                    .frame(width: currentIndex == index ? 8 : 6, height: currentIndex == index ? 8 : 6)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Banner卡片
struct BannerCard: View {
    let subject: DoubanSubject
    let settings: AppSettings
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: subject.cover_url ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure(_):
                    Rectangle().fill(Color.gray.opacity(0.1))
                case .empty:
                    Rectangle().fill(Color.gray.opacity(0.05))
                @unknown default:
                    Rectangle().fill(Color.gray.opacity(0.1))
                }
            }
            .frame(width: UIScreen.main.bounds.width, height: 200)
            .clipped()
            
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.5), Color.black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(subject.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    if subject.ratingValue > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", subject.ratingValue))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }
                }
                if let year = subject.year {
                    Text(year)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(12)
        }
        .onTapGesture {
            settings.triggerSearch(subject.title)
        }
    }
}

// MARK: - 分类磁贴
struct CategoryTilesView: View {
    let categories = [
        ("movie", "🎬", "电影"), ("tv", "📺", "剧集"), ("variety", "🎭", "综艺"),
        ("top250", "🏆", "榜单"), ("animation", "🎨", "动漫"), ("hot", "🔥", "热门")
    ]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.0) { item in
                    CategoryTile(icon: item.1, title: item.2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.white)
    }
}

struct CategoryTile: View {
    let icon: String
    let title: String
    @State private var showList = false
    
    var body: some View {
        Button(action: { showList = true }) {
            VStack(spacing: 6) {
                Text(icon)
                    .font(.system(size: 28))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.black)
            }
            .frame(width: 80, height: 70)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
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
    let settings: AppSettings
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(subjects) { subject in
                    SubjectCard(subject: subject, settings: settings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 主题卡片
struct SubjectCard: View {
    let subject: DoubanSubject
    let settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: subject.cover_url ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure(_):
                        Rectangle().fill(Color.gray.opacity(0.08))
                    case .empty:
                        Rectangle().fill(Color.gray.opacity(0.05))
                    @unknown default:
                        Rectangle().fill(Color.gray.opacity(0.08))
                    }
                }
                .frame(width: 120, height: 160)
                .clipped()
                
                if subject.ratingValue > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", subject.ratingValue))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(4)
                    .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Text(subject.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.black)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
        .onTapGesture {
            settings.triggerSearch(subject.title)
        }
    }
}

// MARK: - 分类列表页
struct DoubanCategoryListView: View {
    let category: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var doubanService = DoubanService.shared
    @State private var subjects: [DoubanSubject] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            ScrollView {
                if isLoading {
                    ProgressView().padding(.top, 100)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                        ForEach(subjects) { subject in
                            SubjectCard(subject: subject, settings: settings)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.white)
            .navigationTitle(category)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark").foregroundColor(.black)
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
                case "电影": subjects = try await doubanService.fetchHotMovies(start: 0, count: 40)
                case "剧集": subjects = try await doubanService.fetchHotTV(start: 0, count: 40)
                case "综艺": subjects = try await doubanService.fetchHotVariety(start: 0, count: 40)
                case "榜单": subjects = try await doubanService.fetchTop250(start: 0, count: 40)
                case "动漫": subjects = try await doubanService.fetchHotAnimation(start: 0, count: 40)
                case "热门": subjects = try await doubanService.fetchHotMovies(start: 0, count: 40)
                default: subjects = try await doubanService.fetchTop250(start: 0, count: 40)
                }
            } catch {
                print("Error: \(error)")
            }
            isLoading = false
        }
    }
}

// SectionHeader 使用 MainViews.swift 中的定义
