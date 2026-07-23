//
// TencentVideoNativeSpider.swift
// 腾讯视频原生实现 — 替代 drpy JS 蜘蛛（drpy 版的 node.video.qq.com 接口已失效）
//

import Foundation

final class TencentVideoNativeSpider {

    static let shared = TencentVideoNativeSpider()
    static let siteKey = "drpy_js_腾云驾雾"

    private let apiHost = "https://pbaccess.video.qq.com"
    private let webHost = "https://v.qq.com"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5410.0 Safari/537.36",
            "Origin": "https://v.qq.com",
            "Referer": "https://v.qq.com/",
            "Content-Type": "application/json"
        ]
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - 搜索

    func search(keyword: String, pg: Int = 1) async -> [VodItem] {
        let body: [String: Any] = [
            "version": "25021101",
            "clientType": 1,
            "filterValue": "",
            "uuid": UUID().uuidString,
            "retry": 0,
            "query": keyword,
            "pagenum": pg - 1,
            "pagesize": 30,
            "queryFrom": 0,
            "searchDatakey": "",
            "transInfo": "",
            "isneedQc": true,
            "preQid": "",
            "adClientInfo": "",
            "extraInfo": [
                "isNewMarkLabel": "1",
                "multi_terminal_pc": "1",
                "themeType": "1"
            ]
        ]

        let urlStr = "\(apiHost)/trpc.videosearch.mobile_search.MultiTerminalSearch/MbSearch?vplatform=2"
        guard let url = URL(string: urlStr) else { return [] }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = httpBody

        do {
            let (data, _) = try await session.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

            let validTypes: Set<String> = ["电视剧", "电影", "综艺", "纪录片", "动漫", "少儿", "短剧"]
            var items: [VodItem] = []

            // 解析 normalList + areaBoxList
            var allList: [[String: Any]] = []
            if let normalList = json.value(forKeyPath: "data.normalList.itemList") as? [[String: Any]] {
                allList.append(contentsOf: normalList)
            }
            if let areaList = json.value(forKeyPath: "data.areaBoxList") as? [[String: Any]],
               let areaItemList = areaList.first?["itemList"] as? [[String: Any]] {
                allList.append(contentsOf: areaItemList)
            }

            for k in allList {
                guard let doc = k["doc"] as? [String: Any],
                      let docId = doc["id"] as? String, !docId.isEmpty,
                      let videoInfo = k["videoInfo"] as? [String: Any],
                      let title = videoInfo["title"] as? String,
                      let typeName = videoInfo["typeName"] as? String,
                      validTypes.contains(typeName)
                else { continue }

                // 排除外站
                let subTitle = videoInfo["subTitle"] as? String ?? ""
                if subTitle.contains("外站") {
                    continue
                }

                let pic = videoInfo["imgUrl"] as? String ?? ""
                let remarks = videoInfo["year"] as? String ?? ""

                items.append(VodItem(
                    vodId: docId,
                    vodName: TencentVideoNativeSpider.removeHtmlTags(title),
                    vodPic: pic,
                    vodRemarks: "\(typeName) ⭐\(remarks)"
                ))
            }

            return items
        } catch {
            print("[TencentNative] 搜索失败: \(error)")
            return []
        }
    }

    // MARK: - 详情

    func detail(ids: String) async -> VodItem? {
        // ids 就是 cid (例如 mzc00200abcdefgh)
        let cid = ids

        // 并发请求详情基础信息 + 剧集列表
        let detailBody: [String: Any] = [
            "page_params": [
                "req_from": "web",
                "cid": cid,
                "vid": "",
                "lid": "",
                "page_type": "detail_operation",
                "page_id": "detail_page_introduction"
            ],
            "has_cache": 1
        ] as [String: Any]

        let episodeBody: [String: Any] = [
            "page_params": [
                "req_from": "web_vsite",
                "page_id": "vsite_episode_list",
                "page_type": "detail_operation",
                "id_type": "1",
                "page_size": "",
                "cid": cid,
                "vid": "",
                "lid": "",
                "page_num": "",
                "page_context": "",
                "detail_page_type": "1"
            ],
            "has_cache": 1
        ] as [String: Any]

        let detailURL = "\(apiHost)/trpc.universal_backend_service.page_server_rpc.PageServer/GetPageData?video_appid=3000010&vplatform=2&vversion_name=8.2.96"
        guard let dURL = URL(string: detailURL) else { return nil }

        var dReq = URLRequest(url: dURL)
        dReq.httpMethod = "POST"
        dReq.httpBody = try? JSONSerialization.data(withJSONObject: detailBody)

        let eURL = URL(string: detailURL)!
        var eReq = URLRequest(url: eURL)
        eReq.httpMethod = "POST"
        eReq.httpBody = try? JSONSerialization.data(withJSONObject: episodeBody)

        do {
            let (dData, _) = try await session.data(for: dReq)
            let (eData, _) = try await session.data(for: eReq)

            guard let vdata = try? JSONSerialization.jsonObject(with: dData) as? [String: Any],
                  let edata = try? JSONSerialization.jsonObject(with: eData) as? [String: Any]
            else {
                print("[TencentNative] 详情JSON解析失败"); return nil
            }

            // 提取基础信息
            let title = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.item_params.title") as? String ?? ""
            let pic = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.item_params.new_pic_hz") as? String ?? ""
            let year = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.item_params.year") as? String ?? ""
            let area = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.item_params.area_name") as? String ?? ""
            let desc = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.item_params.cover_description") as? String ?? ""
            let typeName = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.item_params.sub_genre") as? String ?? ""

            // 提取演员
            var actors: [String] = []
            if let starList = vdata.value(forKeyPath: "data.module_list_datas.0.module_datas.0.item_data_lists.item_datas.0.sub_items.star_list.item_datas") as? [[String: Any]] {
                for star in starList {
                    if let name = star.value(forKeyPath: "item_params.name") as? String {
                        actors.append(name)
                    }
                }
            }

            // 提取剧集列表
            let allEpisodes = await self.processEpisodes(edata: edata, episodeBody: episodeBody, cid: cid)

            if allEpisodes.plist.isEmpty && allEpisodes.ylist.isEmpty {
                print("[TencentNative] 无剧集数据"); return nil
            }

            var names = ["腾讯视频"]
            var urls: [String] = []

            if !allEpisodes.plist.isEmpty {
                urls.append(allEpisodes.plist.joined(separator: "#"))
            } else {
                names.removeAll()
            }

            if !allEpisodes.ylist.isEmpty {
                urls.append(allEpisodes.ylist.joined(separator: "#"))
            } else if names.count > 1 {
                names.removeLast()
            }

            let vodPlayFrom = names.joined(separator: "$$$")
            let vodPlayUrl = urls.joined(separator: "$$$")

            return VodItem(
                vodId: ids,
                vodName: title,
                vodPic: pic,
                vodRemarks: "\(typeName) \(year)",
                vodYear: year,
                vodArea: area,
                vodActor: actors.joined(separator: ","),
                vodContent: desc,
                vodPlayFrom: vodPlayFrom,
                vodPlayUrl: vodPlayUrl
            )
        } catch {
            print("[TencentNative] 详情请求失败: \(error)"); return nil
        }
    }

    // MARK: - 播放

    func playerContent(vodId: String, flag: String, url: String) -> PlayerContentResult? {
        // url 格式: "标题$cid@vid" 或 "标题$cid@vid"
        let parts = url.components(separatedBy: "$")
        guard parts.count >= 2 else { return nil }

        let ids = parts[1]
        let idParts = ids.components(separatedBy: "@")
        guard idParts.count >= 2 else { return nil }

        let cid = idParts[0]
        let vid = idParts[1]

        let playURL = "\(webHost)/x/cover/\(cid)/\(vid).html"

        return PlayerContentResult(parse: 1, playUrl: nil, url: playURL, header: nil)
    }

    // MARK: - Private

    private func processEpisodes(edata: [String: Any], episodeBody: [String: Any], cid: String) async -> (plist: [String], ylist: [String]) {
        var plist: [String] = []
        var ylist: [String] = []

        guard let modules = edata.value(forKeyPath: "data.module_list_datas") as? [[String: Any]],
              let lastModule = modules.last,
              let mDatas = lastModule["module_datas"] as? [[String: Any]],
              let lastMData = mDatas.last,
              let itemLists = lastMData["item_data_lists"] as? [String: Any],
              let itemDatas = itemLists["item_datas"] as? [[String: Any]]
        else {
            return (plist, ylist)
        }

        // 第一页剧集
        for item in itemDatas {
            guard let itemId = item["item_id"] as? String else { continue }
            guard let params = item["item_params"] as? [String: Any] else { continue }

            let title = params["union_title"] as? String ?? ""
            let entry = "\(title)$\(cid)@\(itemId)"

            if title.contains("预告") {
                ylist.append(entry)
            } else {
                plist.append(entry)
            }
        }

        // 获取其他 tab 的剧集
        if let tabsStr = lastMData["module_params"] as? [String: Any],
           let tabs = tabsStr["tabs"] as? String,
           let tabsData = try? JSONSerialization.jsonObject(with: tabs.data) as? [[String: Any]],
           tabsData.count > 1 {

            let remainingTabs = Array(tabsData.dropFirst())
            // 不用多线程，顺序请求即可
            for tab in remainingTabs {
                guard let pageCtx = tab["page_context"] as? String else { continue }

                var newBody = episodeBody
                guard var pageParams = newBody["page_params"] as? [String: Any] else { continue }
                pageParams["page_context"] = pageCtx
                newBody["page_params"] = pageParams

                guard let url = URL(string: "\(apiHost)/trpc.universal_backend_service.page_server_rpc.PageServer/GetPageData?video_appid=3000010&vplatform=2&vversion_name=8.2.96") else { continue }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.httpBody = try? JSONSerialization.data(withJSONObject: newBody)

                if let (data, _) = try? await session.data(for: req),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let moreItems = json.value(forKeyPath: "data.module_list_datas.last.module_datas.last.item_data_lists.item_datas") as? [[String: Any]] {

                    for item in moreItems {
                        guard let itemId = item["item_id"] as? String else { continue }
                        guard let params = item["item_params"] as? [String: Any] else { continue }

                        let title = params["union_title"] as? String ?? ""
                        let entry = "\(title)$\(cid)@\(itemId)"

                        if title.contains("预告") {
                            ylist.append(entry)
                        } else {
                            plist.append(entry)
                        }
                    }
                }
            }
        }

        return (plist, ylist)
    }

    private static func removeHtmlTags(_ html: String) -> String {
        return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
