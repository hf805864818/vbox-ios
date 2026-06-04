import SwiftUI

struct HomeView: View {
    @State private var categories: [VodCategory] = []
    @State private var videos: [VodItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("加载失败")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { loadHome() }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 12) {
                            ForEach(videos) { video in
                                NavigationLink(value: video) {
                                    VideoCard(video: video)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("vbox")
            .navigationDestination(for: VodItem.self) { video in
                DetailView(video: video)
            }
        }
        .onAppear { loadHome() }
    }
    
    private func loadHome() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let engine = SpiderManager.shared.repository.getEngine(for: "test_site")
                let result = try await Task { @MainActor in
                    try engine?.callHomeContent()
                }.value
                
                if let result = result {
                    videos = result.list ?? []
                    categories = result.class ?? []
                }
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

struct VideoCard: View {
    let video: VodItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: video.vodPic)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(.secondary)
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay { Image(systemName: "film") }
                case .empty:
                    Rectangle()
                        .fill(.tertiary)
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay { ProgressView() }
                @unknown default:
                    EmptyView()
                }
            }
            .clipped()
            .cornerRadius(8)
            
            Text(video.vodName)
                .font(.caption)
                .lineLimit(1)
            
            if let remark = video.vodRemarks {
                Text(remark)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
}
