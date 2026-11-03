/// 领域层：Spider 引擎类型与站点模式解析。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §1「引擎类型」+ §1.1「引擎选择规则」
/// 逆向来源：iOS `vbox/Services/SpiderEngineProtocol.swift`
library;

/// Spider 引擎类型。
///
/// 对齐 iOS `enum SpiderEngineType`（4 个）+ Flutter 补充的 Python 引擎
/// （iOS 中 `PythonSpiderEngine` 存在但未入枚举，此处按契约 §1 建议值补充）。
enum SpiderEngineType {
  /// Apple JavaScriptCore（iOS 原生）。
  javaScriptCore,

  /// 嵌入式 QuickJS。
  quickJS,

  /// 常驻 Node 进程（127.0.0.1:58080）。
  node,

  /// lx-music 桥接插件（127.0.0.1:58083）。
  nodeLX,

  /// Python 蜘蛛（iOS 未入枚举，Flutter 补充）。
  python;

  /// 契约原始值（与 iOS `rawValue` 一致；python 为契约 §1 建议值）。
  String get rawValue => switch (this) {
        SpiderEngineType.javaScriptCore => 'JavaScriptCore',
        SpiderEngineType.quickJS => 'QuickJS',
        SpiderEngineType.node => 'Node',
        SpiderEngineType.nodeLX => 'NodeLX',
        SpiderEngineType.python => 'python',
      };

  /// 显示名。
  String get displayName => switch (this) {
        SpiderEngineType.javaScriptCore => 'JSC (Apple)',
        SpiderEngineType.quickJS => 'QuickJS',
        SpiderEngineType.node => 'Node',
        SpiderEngineType.nodeLX => 'Node-LX',
        SpiderEngineType.python => 'Python',
      };

  /// 从契约原始值解析（大小写敏感，与 iOS rawValue 对齐）。
  static SpiderEngineType? fromRawValue(String v) {
    for (final SpiderEngineType t in SpiderEngineType.values) {
      if (t.rawValue == v) return t;
    }
    // 契约 §1 允许 python 的小写变体
    if (v.toLowerCase() == 'python') return SpiderEngineType.python;
    return null;
  }
}

/// 站点解析模式（对齐 iOS `resolveSiteMode` 的返回语义）。
enum SiteMode {
  /// Node 常驻源（127.0.0.1 /spider/）。
  node,

  /// API 端点（直接 HTTP，非脚本引擎）。
  apiEndpoint,

  /// 站源（HTML 解析，type == 2）。
  zhanyuan,

  /// JS 蜘蛛（本地/远程 .js）。
  jsSpider,

  /// Python 蜘蛛（.py）。
  pythonSpider,

  /// 不支持（.jar 等）。
  unsupported,
}
