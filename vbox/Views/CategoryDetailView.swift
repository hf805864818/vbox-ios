import SwiftUI

// MARK: - Category Detail View
struct CategoryDetailView: View {
    let categoryType: String
    let categoryName: String
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var doubanService = DoubanService.shared
    @State private var subjects: [DoubanSubject] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var currentPage = 0
    @State private var hasMoreData = true
    private let pageSize = 20
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                if isLoading && subjects.isEmpty {
                    CategoryLoadingView()
                } else if let error = errorMessage {
                    CategoryErrorView(message: error, retryAction: loadData)
                } else if subjects.isEmpty {
                    CategoryEmptyView(categoryName: categoryName)
                } else {
                    SubjectGridView(
                        subjects: subjects,
                        settings: settings,
                        onLoadMore: loadMoreData
                    )
                    
                    if isLoading && !subjects.isEmpty {
                        ProgressView()
                            .padding()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.white)
        .navigationTitle(categoryName)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if subjects.isEmpty {
                loadData()
            }
        }
    }
    
    private func loadData() {
        isLoading = true
        errorMessage = nil
        currentPage = 0
        hasMoreData = true
        subjects = []
        
        Task {
            do {
                let newSubjects = try await fetchDataForCategory(start: 0, count: pageSize)
                await MainActor.run {
                    subjects = newSubjects
                    hasMoreData = newSubjects.count == pageSize
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    
    private func loadMoreData() {
        guard !isLoading && hasMoreData else { return }
        
        isLoading = true
        currentPage += 1
        let start = currentPage * pageSize
        
        Task {
            do {
                let newSubjects = try await fetchDataForCategory(start: start, count: pageSize)
                await MainActor.run {
                    subjects.append(contentsOf: newSubjects)
                    hasMoreData = newSubjects.count == pageSize
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
    
    private func fetchDataForCategory(start: Int, count: Int) async throws -> [DoubanSubject] {
        switch categoryType {
        case "movie", "电影":
            return try await doubanService.fetchHotMovies(start: start, count: count)
        case "tv", "电视剧", "剧集":
            return try await doubanService.fetchHotTV(start: start, count: count)
        case "variety", "综艺":
            return try await doubanService.fetchHotVariety(start: start, count: count)
        case "top250", "榜单":
            return try await doubanService.fetchTop250(start: start, count: count)
        case "animation", "动漫":
            return try await doubanService.fetchHotAnimation(start: start, count: count)
        case "hot", "热门":
            return try await doubanService.fetchRecommendFeed(start: start, count: count)
        case "documentary", "纪录片":
            return try await doubanService.fetchHotMovies(start: start, count: count)
        case "live", "直播":
            return try await doubanService.fetchHotMovies(start: start, count: count)
        case "music", "音乐":
            return try await doubanService.fetchHotMovies(start: start, count: count)
        case "sports", "体育":
            return try await doubanService.fetchHotMovies(start: start, count: count)
        default:
            return []
        }
    }
}

// MARK: - Loading View
struct CategoryLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(.top, 100)
    }
}

// MARK: - Error View
struct CategoryErrorView: View {
    let message: String
    let retryAction: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            Text("Load Failed")
                .font(.system(size: 16, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            Button(action: retryAction) {
                Text("Retry")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
        }
        .padding(.top, 80)
    }
}

// MARK: - Empty View
struct CategoryEmptyView: View {
    let categoryName: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))
            Text("No \(categoryName) content")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(.top, 100)
    }
}

// MARK: - Subject Grid View
struct SubjectGridView: View {
    let subjects: [DoubanSubject]
    let settings: AppSettings
    let onLoadMore: () -> Void
    
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(subjects) { subject in
                GridSubjectCard(subject: subject, settings: settings)
                    .onAppear {
                        if subject.id == subjects.last?.id {
                            onLoadMore()
                        }
                    }
            }
        }
    }
}

// MARK: - Grid Subject Card
struct GridSubjectCard: View {
    let subject: DoubanSubject
    let settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverImageView(subject: subject)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                if subject.ratingValue > 0 {
                    RatingBadge(rating: subject.ratingValue)
                        .padding(4)
                }
            }
            
            Text(subject.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.black)
                .lineLimit(1)
            
            if let year = subject.year {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
        }
        .onTapGesture {
            settings.triggerSearch(subject.title)
        }
    }
}

// MARK: - Cover Image View
struct CoverImageView: View {
    let subject: DoubanSubject
    
    var body: some View {
        Group {
            if let url = DoubanImageProxyServer.shared.proxiedURL(for: subject.coverImageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(ProgressView().scaleEffect(0.8))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(Image(systemName: "photo").foregroundColor(.gray))
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
            }
        }
    }
}

// MARK: - Rating Badge
struct RatingBadge: View {
    let rating: Double
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundColor(.yellow)
            Text(String(format: "%.1f", rating))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.yellow)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
    }
}
