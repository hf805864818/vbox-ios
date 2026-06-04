import SwiftUI

struct SearchView: View {
    @State private var keyword = ""
    @State private var results: [VodItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    
    var body: some View {
        NavigationStack {
            VStack {
                // 搜索栏
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索视频...", text: $keyword)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { performSearch() }
                    if !keyword.isEmpty {
                        Button { keyword = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(.tertiary, in: .rect(cornerRadius: 10))
                .padding(.horizontal)
                
                if isSearching {
                    Spacer()
                    ProgressView("搜索中...")
                    Spacer()
                } else if results.isEmpty && hasSearched {
                    Spacer()
                    ContentUnavailableView("未找到结果", systemImage: "magnifyingglass",
                        description: Text("尝试其他关键词"))
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(results) { video in
                                NavigationLink(value: video) {
                                    SearchResultRow(video: video)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationDestination(for: VodItem.self) { video in
                DetailView(video: video)
            }
        }
    }
    
    private func performSearch() {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        isSearching = true
        hasSearched = true
        
        Task {
            let results = await SpiderManager.shared.repository.searchAll(keyword: keyword)
            DispatchQueue.main.async {
                self.results = results.flatMap { $0.results }
                self.isSearching = false
            }
        }
    }
}

struct SearchResultRow: View {
    let video: VodItem
    
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: video.vodPic)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(.tertiary)
                }
            }
            .frame(width: 80, height: 120)
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(video.vodName)
                    .font(.headline)
                    .lineLimit(2)
                
                if let year = video.vodYear {
                    Text(year)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let remark = video.vodRemarks {
                    Text(remark)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(.background, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4)
    }
}
