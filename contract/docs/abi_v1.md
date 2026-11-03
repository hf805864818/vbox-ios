# Spider ABI 规范 v1.0

> **契约层文件** · `contract/docs/abi_v1.md`
> **来源**：从 `vboxapp/vbox/` iOS Swift 实现逆向提取
> **冻结日期**：2026-09-29
> **约束**：Flutter 端必须实现与此完全一致的 ABI，否则三端行为不一致

---

## 1. 引擎类型

从 `vbox/Services/SpiderEngineProtocol.swift` 提取：

```swift
enum SpiderEngineType: String, CaseIterable {
    case javaScriptCore = "JavaScriptCore"
    case quickJS        = "QuickJS"
    case node           = "Node"      // 桥接 127.0.0.1 Node 进程
    case nodeLX         = "NodeLX"    // lx-music 桥接插件
}
```

| 引擎 | 原始值 | 显示名 | 实现位置 | 用途 |
|------|--------|--------|---------|------|
| JavaScriptCore | `JavaScriptCore` | JSC (Apple) | 系统框架 | iOS 原生 JS |
| QuickJS | `QuickJS` | QuickJS | `QuickJSBridge` (C) | 嵌入式 JS |
| Node | `Node` | Node | 127.0.0.1:58080 | 常驻 Node 源 |
| NodeLX | `NodeLX` | Node-LX | 127.0.0.1:58083 | lx-music 插件 |
| Python | *(源码未定义枚举)* | — | `PythonSpiderEngine` | Python 蜘蛛 |

**⚠️ 注意**：`PythonSpiderEngine` 存在（见 `Services/PythonSpiderEngine.swift`），但**未纳入 `SpiderEngineType` 枚举**。Flutter 端需自行定义 Python 引擎标识（建议 `python`）。

### 1.1 引擎选择规则

从 `SpiderManager.resolveSiteMode(site:)` 提取：

```
判定优先级：
  ① isNodeSite(site) == true                      → .node
  ② type == 0 或 type == 1                        → .apiEndpoint（非引擎，直接 HTTP）
  ③ type == 2                                     → .zhanyuan（HTML 解析）
  ④ type == 3:
       api 含 ".jar"                              → .unsupported
       api 后缀 ".py"                             → pythonSpider
       api 前缀 http(s):// 且后缀 ".js"            → jsSpider
       api 前缀 http(s):// 且非 .js               → apiEndpoint
       api 后缀 ".js" 或前缀 "./"                  → jsSpider
       其他（纯类名）                              → .unsupported
  ⑤ 其他 type                                     → .unsupported

isNodeSite 判定（任一成立）：
  - site.group == "node"
  - key 前缀 "nodejs_"
  - key 前缀 "csp_" 且 type == 3
  - api 前缀 "nodejs_" 或（"csp_" 且 type==3）
  - api 含 "://127.0.0.1" 且含 "/spider/"
```

---

## 2. 统一接口签名

来自 `protocol SpiderEngineProtocol`（`SpiderEngineProtocol.swift` 第 4-31 行）：

```swift
protocol SpiderEngineProtocol: AnyObject {
    var onLog: ((String) -> Void)? { get set }

    func loadScript(_ script: String) throws
    func loadLibrary(_ script: String) throws
    func loadScriptFromURL(_ urlString: String) async throws

    var isSpiderReady: Bool { get }

    func registerSpider() throws

    func callHomeContent() throws -> HomeContentResult
    func callSearchContent(keyword: String, pg: Int) throws -> SearchContentResult
    func callCategoryContent(tid: String, pg: Int, extend: String) throws -> CategoryContentResult
    func callDetailContent(ids: String) throws -> DetailContentResult
    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult
}
```

### 2.1 操作签名表（精确）

| 操作 | 入参 | 返回类型 |
|------|------|---------|
| `homeContent` | 无 | `HomeContentResult` |
| `searchContent` | `keyword: String`, `pg: Int` | `SearchContentResult` |
| `categoryContent` | `tid: String`, `pg: Int`, `extend: String` | `CategoryContentResult` |
| `detailContent` | `ids: String` | `DetailContentResult` |
| `playerContent` | `vodId: String`, `flag: String`, `url: String` | `PlayerContentResult` |

**生命周期方法**：

| 方法 | 签名 | 说明 |
|------|------|------|
| `loadScript` | `(String) throws` | 加载蜘蛛脚本 |
| `loadLibrary` | `(String) throws` | 加载库（不检查注册） |
| `loadScriptFromURL` | `(String) async throws` | 远程加载 |
| `registerSpider` | `() throws` | 注册蜘蛛 |
| `isSpiderReady` | `Bool` (属性) | 是否已注册 |

---

## 3. 返回结构（逐字段，从源码提取）

来源：`vbox/Models/SpiderModels.swift`

### 3.1 HomeContentResult

```swift
struct HomeContentResult: Codable {
    let `class`: [VodCategory]?    // JSON key 为 "class"
    let list: [VodItem]?
}
```

| 字段 | JSON key | 类型 | 可空 |
|------|---------|------|------|
| class | `class` | `[VodCategory]` | ✅ |
| list | `list` | `[VodItem]` | ✅ |

### 3.2 CategoryContentResult

```swift
struct CategoryContentResult: Codable {
    let page: Int?
    let pagecount: Int?
    let limit: Int?
    let total: Int?
    let list: [VodItem]?
}
```

| 字段 | 类型 | 可空 |
|------|------|------|
| page | `Int` | ✅ |
| pagecount | `Int` | ✅ |
| limit | `Int` | ✅ |
| total | `Int` | ✅ |
| list | `[VodItem]` | ✅ |

### 3.3 SearchContentResult

```swift
struct SearchContentResult: Codable {
    let page: Int?
    let pagecount: Int?
    let list: [VodItem]?
}
```

| 字段 | 类型 | 可空 |
|------|------|------|
| page | `Int` | ✅ |
| pagecount | `Int` | ✅ |
| list | `[VodItem]` | ✅ |

### 3.4 DetailContentResult

```swift
struct DetailContentResult: Codable {
    let list: [VodItem]?
}
```

### 3.5 PlayerContentResult（最复杂）

```swift
struct PlayerContentResult: Codable {
    let parse: Int?
    let playUrl: String?
    let url: String?
    let urls: [String]?            // 多音质/多线路
    let header: [String: String]?

    enum CodingKeys: String, CodingKey {
        case parse, playUrl, url, urls, header
    }
}
```

| 字段 | 类型 | 可空 | 说明 |
|------|------|------|------|
| parse | `Int` | ✅ | 是否需二次解析（0/1） |
| playUrl | `String` | ✅ | 播放地址（旧字段） |
| url | `String` | ✅ | 播放地址（主字段） |
| urls | `[String]` | ✅ | 多音质/多线路（酷狗/酷我/网易/QQ） |
| header | `[String: String]` | ✅ | 自定义请求头 |

**回填规则**（源码 `init` 中）：
```swift
self.urls = urls ?? url.flatMap { $0.isEmpty ? nil : [$0] }
```
即：若 `urls` 为 nil 且 `url` 非空，则 `urls = [url]`。

**url 数组形态**（源码 `init(from:)` 中，B-10 三端对齐）：
```swift
if let arr = try? c.decode([String].self, forKey: .url) {
    urls = arr; url = arr.first
} else if let s = try? c.decode(String.self, forKey: .url) {
    url = s; urls = s.isEmpty ? nil : [s]
}
```
即：蜘蛛 play 可能返回 `url` 为**字符串数组**（多线路/多音质：酷狗/酷我/网易/QQ）。
数组形态下 `urls` = 全列表、`url` = 首元素，且 `urls` 键不再参与；
空数组 → `urls = []`、`url = nil`。

### 3.6 VodCategory

```swift
struct VodCategory: Codable, Identifiable, Equatable {
    let typeId: String      // JSON key: "type_id"
    let typeName: String    // JSON key: "type_name"
}
```

**容错解码规则**（源码 `init(from:)`）：`type_id` / `type_name` 支持 **String / Int / Double**，数字自动转字符串。

### 3.7 VodItem（完整字段）

```swift
struct VodItem: Codable, Identifiable {
    let vodId: String               // "vod_id"
    let vodName: String             // "vod_name"
    let vodPic: String              // "vod_pic"
    var vodRemarks: String?         // "vod_remarks"
    let vodYear: String?            // "vod_year"
    let vodArea: String?            // "vod_area"
    let vodDirector: String?        // "vod_director"
    let vodActor: String?           // "vod_actor"
    let vodContent: String?         // "vod_content"
    let vodPlayFrom: String?        // "vod_play_from"
    var vodPlayUrl: String?         // "vod_play_url"
    let customHeaders: [String: String]?
    var engineKey: String?
    var metaDuration: Int?
    var albumName: String?
    var availQualities: [String]    // 默认 []
    var musicPlatform: String?
    var lxMusicInfo: String?
    var musicEntryType: String?
}
```

**⚠️ 关键容错规则（必须复刻）**：
- `vod_id` / `vod_name` / `vod_pic` 支持 **String / Int / Double**（Node/WEX 源会返回数字）
- 其余字段用 `decodeIfPresent`
- `availQualities` 缺省为 `[]`

---

## 4. HTTP 回调协议

来源：`vbox/Services/JSHTTPBridge.swift`

蜘蛛脚本中的 `http(url, options)` 调用宿主桥接。

### 4.1 请求参数

| 参数 | 类型 | 说明 |
|------|------|------|
| url | `String` | 请求地址 |
| options.headers | `[String: String]` | 请求头 |
| options.method | `String` | GET / POST |
| options.data | `String` | POST body |
| options.timeout | `Double` | 超时（默认 15s） |

### 4.2 编码处理（必须复刻）

解码优先级（源码 `decodeText`）：
```
① 响应头 Content-Type 的 charset
② UTF-8 尝试 → 若 meta 声明非 UTF-8，用 meta charset 重新解码
③ 前 4096 字节 ASCII 探测 meta charset
④ 兜底链：GBK → GB2312 → Big5 → ISO-8859-1
⑤ 全部失败 → base64 编码返回
```

**字符集映射**：
| 输入 | 映射编码 |
|------|---------|
| utf-8 / utf8 | UTF-8 |
| gbk / gb2312 / gb-2312 / gb18030 / gb-18030 / gb18030-2000 | GBK |
| big5 / big-5 | Big5 |
| iso-8859-1 / latin1 / latin-1 | ISO Latin1 |
| 其他 | CFStringConvertIANACharSetNameToEncoding |

### 4.3 SSL 绕过

`sslBypass` 开关（福利 JS Spider 用）→ 使用 `WelfareSSLBypassDelegate` 接受任意服务器证书。

⚠️ **Flutter 端需实现等效能力**（`badCertificateCallback` 返回 true），但应仅在福利模块启用。

### 4.4 Cookie 存储

```swift
private var cookieStore: [String: [String: String]] = [:]
```
按域名分组存储。**源码未定义持久化方式**（建议内存 + 可选持久化）。

---

## 5. 错误处理

**源码中的错误类型**（`SpiderEngineProtocol.swift`）：

```swift
throw QJSError(message: "QuickJS 蜘蛛注册失败: 未找到 __JS_SPIDER__")
throw QJSError(message: "加载库失败: \(trimmed)")
throw QJSError(message: "无效的URL: \(urlString)")
throw QJSError(message: "无法解码脚本: \(urlString)")
throw QJSError(message: "JS 返回 nil")
throw QJSError(message: "结果编码无效")
```

**错误检测规则**（QuickJS `loadLibrary`）：
```swift
if trimmed.hasPrefix("Error") || trimmed.hasPrefix("TypeError")
   || trimmed.hasPrefix("ReferenceError") || trimmed.hasPrefix("SyntaxError") {
    throw QJSError(...)
}
```

**蜘蛛注册检测**：
```swift
let result = evaluateJS("typeof globalThis.__JS_SPIDER__")
// 判定为已注册：result == "object" || result == "\"object\"" || 含 "object"
```

### 5.1 Flutter 端错误码映射（建议）

| 源码错误场景 | 建议错误码 |
|-------------|-----------|
| 注册失败（未找到 `__JS_SPIDER__`） | `E_REGISTER` |
| 加载库失败 | `E_SCRIPT_LOAD` |
| 无效 URL | `E_SCRIPT_LOAD` |
| 无法解码脚本 | `E_SCRIPT_LOAD` |
| JS 返回 nil | `E_PROTOCOL` |
| 结果编码无效 | `E_PROTOCOL` |
| 超时（源码用 15s 超时） | `E_TIMEOUT` |
| 运行时崩溃 | `E_RUNTIME` |

⚠️ 上述错误码为**建议值**，源码中仅有 `QJSError(message:)`，无结构化错误码。

---

## 6. 超时 / 取消 / 日志

| 项 | 源码值 | 位置 |
|----|--------|------|
| HTTP 默认超时 | **15 秒** | `JSHTTPBridge.timeout = 15` |
| HTTP 资源超时 | timeout + 10 秒 | `createSession()` |
| 日志回调 | `onLog: ((String) -> Void)?` | `SpiderEngineProtocol` |

**⚠️ 源码未定义**：
- 引擎级超时（仅 HTTP 层有超时）
- 取消机制
- 结构化日志（仅字符串）

---

## 7. ABI 消息示例

### 7.1 请求（客户端 → 引擎）

```json
{
  "op": "searchContent",
  "params": {
    "keyword": "庆余年",
    "pg": 1
  },
  "ctx": {
    "siteKey": "js_剧迷",
    "engineType": "JavaScriptCore",
    "baseUrl": "https://example.com/js/jumi.js",
    "timeoutMs": 15000,
    "requestId": "req-0001"
  }
}
```

### 7.2 响应（引擎 → 客户端）

```json
{
  "ok": true,
  "data": {
    "page": 1,
    "pagecount": 120,
    "list": [
      {
        "vod_id": "12345",
        "vod_name": "庆余年第二季",
        "vod_pic": "https://cdn.example.com/pic.jpg",
        "vod_remarks": "更新至36集",
        "vod_year": "2024",
        "vod_play_from": "线路1$$$线路2",
        "vod_play_url": "第1集$url1#第2集$url2$$$第1集$url3"
      }
    ]
  },
  "logs": ["[SPIDER] search start", "[SPIDER] got 20 items"],
  "elapsedMs": 1234
}
```

### 7.3 错误响应

```json
{
  "ok": false,
  "error": {
    "code": "E_REGISTER",
    "message": "QuickJS 蜘蛛注册失败: 未找到 __JS_SPIDER__"
  },
  "logs": ["[SPIDER] register failed"],
  "elapsedMs": 45
}
```

### 7.4 HTTP 回调（引擎 → 宿主）

```json
{
  "cb": "http",
  "id": "http-001",
  "method": "GET",
  "url": "https://api.example.com/search?wd=test",
  "headers": {
    "User-Agent": "Mozilla/5.0 ...",
    "Referer": "https://example.com/"
  },
  "timeoutMs": 15000
}
```

**宿主回传**：
```json
{
  "id": "http-001",
  "status": 200,
  "headers": { "Content-Type": "text/html; charset=gbk" },
  "body": "<html>...</html>"
}
```

---

## 8. 站点配置字段（SiteConfig）

来源：`vbox/Models/SpiderModels.swift` `struct SiteConfig`

| 字段 | 类型 | 可空 | 说明 |
|------|------|------|------|
| key | `String` | ❌ | 站点唯一键 |
| name | `String` | ❌ | 站点名 |
| type | `Int` | ❌ | 0/1=API, 2=站源, 3=蜘蛛 |
| api | `String` | ✅ | 脚本路径或 API 地址 |
| searchable | `Int` | ✅ | |
| quickSearch | `Int` | ✅ | |
| filterable | `Int` | ✅ | |
| ext | `String` | ✅ | |
| playerType | `Int` | ✅ | |
| jar | `String` | ✅ | |
| changeable | `Int` | ✅ | |
| playStrategy | `String` | ✅ | |
| playMode | `String` | ✅ | normal / pan / hybrid |
| panHosts | `[String]` | ✅ | 网盘宿主列表 |
| group | `String` | ✅ | video/music/node/cloud/api |
| engineType | `String` | ✅ | lxMusic / node / 空 |
| pluginPath | `String` | ✅ | lx 插件路径 |
| version | `String` | ✅ | 插件版本 |
| md5 | `String` | ✅ | 插件完整性校验 |

---

## 9. Flutter 端实现要点

| 项 | 要求 |
|----|------|
| 接口形状 | 5 个操作 + 5 个生命周期方法，签名一致 |
| 容错解码 | `vod_id`/`vod_name`/`vod_pic`/`type_id`/`type_name` 必须支持 String/Int/Double |
| 编码处理 | 复刻 5 级解码链（含 GBK/Big5 兜底） |
| `urls` 回填 | `urls ?? [url]`（url 非空时） |
| `url` 数组形态 | `url` 兼容 String / `[String]`（数组 → urls=全列表、url=首元素，`urls` 键不再参与） |
| 错误检测 | 检查返回字符串前缀 `Error`/`TypeError`/`ReferenceError`/`SyntaxError` |
| 注册检测 | 检查 `typeof globalThis.__JS_SPIDER__` == object |
| HTTP 超时 | 默认 15s |
| 日志 | 字符串流式回调 |

---

## 10. 源码未定义项（Flutter 端需自行设计）

| 项 | 状态 |
|----|------|
| Python 引擎的 `SpiderEngineType` 枚举值 | 未定义（建议 `python`） |
| 引擎级超时 | 未定义 |
| 取消机制 | 未定义 |
| 结构化错误码 | 未定义（仅有 message） |
| Cookie 持久化 | 未定义 |
| 并发限制 | 未定义 |
| 内存上限 | 未定义 |

**建议**：Flutter 端在上述项上采用 E.4 所述「统一 ABI」设计，将差异收敛到适配层。
