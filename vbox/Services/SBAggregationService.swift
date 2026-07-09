import Foundation

// MARK: - 色播聚合 API 服务
// 对应 Python 脚本: SB聚合[成人].py
// API: http://api.hclyz.com:81/mf

// MARK: - 数据模型

struct SBAggregationVideo: Identifiable {
    var id: String { address }
    let title: String      // 对应 vod_name
    let cover: String      // 对应 vod_pic (xinimg)
    let remarks: String    // 对应 vod_remarks (Number, 排序用)
    let address: String    // 对应 vod_id 去掉前导 /
}

struct SBAggregationPlayItem: Identifiable {
    var id: String { address }
    let title: String      // 主播名
    let address: String    // 播放地址（直接 URL）
}

// MARK: - 服务

@MainActor
class SBAggregationService: ObservableObject {
    static let shared = SBAggregationService()

    private let baseURL = "http://api.hclyz.com:81/mf"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "Accept": "application/json, text/plain, */*",
        ]
        return URLSession(configuration: config)
    }()

    // MARK: - 列表（对应 categoryContent）

    /// 获取平台列表，按 Number 降序排列
    func fetchList() async -> [SBAggregationVideo] {
        do {
            let url = URL(string: "\(baseURL)/json.txt")!
            let (data, response) = try await session.data(from: url)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                print("[SBAggregation] fetchList HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pingtai = json["pingtai"] as? [[String: Any]] else {
                print("[SBAggregation] fetchList parse error: unexpected JSON structure")
                return []
            }
            // 跳过第一个元素（对应 Python [1:]）
            let items = pingtai.dropFirst()
            let videos: [SBAggregationVideo] = items.compactMap { item in
                guard let title = item["title"] as? String,
                      let address = item["address"] as? String,
                      let cover = item["xinimg"] as? String else {
                    return nil
                }
                let number = item["Number"] as? String ?? "0"
                return SBAggregationVideo(
                    title: title,
                    cover: cover,
                    remarks: number,
                    address: address
                )
            }
            // 按 Number 降序排列（对应 Python sorted by int(Number) reverse=True）
            let sorted = videos.sorted { a, b in
                (Int(a.remarks) ?? 0) > (Int(b.remarks) ?? 0)
            }
            print("[SBAggregation] fetchList: \(sorted.count) 个平台")
            return sorted
        } catch {
            print("[SBAggregation] fetchList error: \(error)")
            return []
        }
    }

    // MARK: - 详情（对应 detailContent）

    /// 获取某个平台的播放地址列表
    func fetchDetail(address: String) async -> [SBAggregationPlayItem] {
        do {
            let url = URL(string: "\(baseURL)/\(address)")!
            let (data, response) = try await session.data(from: url)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                print("[SBAggregation] fetchDetail HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let zhubo = json["zhubo"] as? [[String: Any]] else {
                print("[SBAggregation] fetchDetail parse error: missing zhubo")
                return []
            }
            let items: [SBAggregationPlayItem] = zhubo.compactMap { item in
                guard let title = item["title"] as? String,
                      let playAddress = item["address"] as? String else {
                    return nil
                }
                return SBAggregationPlayItem(title: title, address: playAddress)
            }
            print("[SBAggregation] fetchDetail(\(address)): \(items.count) 个播放源")
            return items
        } catch {
            print("[SBAggregation] fetchDetail error: \(error)")
            return []
        }
    }
}