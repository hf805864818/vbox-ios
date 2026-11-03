/// 平台层：Node / NodeLX 桥接引擎（HTTP 协议）。
///
/// 对齐 iOS `NodeSpiderEngine`（`NodeSpiderEngine.swift`）的桥接协议：
///
/// - **node**（kstore bundle 常驻 spiders，统一挂载 `/spider/{key}/{type}`，
///   实测注册 `/3/play`；旧协议 `/3/player` 404 时自动回退兼容）：
///   ```
///   POST /spider/{nodeKey}/3/home       body {}
///   POST /spider/{nodeKey}/3/category   body {tid, pg, extend}
///   POST /spider/{nodeKey}/3/detail     body {id, ids}
///   POST /spider/{nodeKey}/3/search     body {wd, pg}
///   POST /spider/{nodeKey}/3/play       body {id, ids, flag, url}
///   ```
/// - **key 归一化**（对齐 iOS `normalizeNodeKey`，NodeSpiderEngine.swift:92-L102）：
///   订阅源 key（`nodejs_SoKaKa` 等）→ 去 `nodejs_`/`csp_` 前缀 → 显式映射表
///   （bundle 注册 key 与订阅源 key 不一致，如 `SoKaKa`→`sokaka`）→ 小写兜底；
///   中文 key 由 `Uri.pathSegments` 自动百分号编码（对齐 iOS
///   `addingPercentEncoding(.urlPathAllowed)`）。
/// - **nodeLX**：lx-music 插件协议（`/lx/{pluginKey}/{action}`）Flutter 端桥接
///   未交付（登记差异），五协议按 iOS `LXBridgeEngine`（NodeSpiderEngine.swift:354-L365）
///   同款语义返回空结果，不进入视频内容链。
///
/// 未覆盖（iOS 同语义，不静默兜底）：Node 未就绪 / 桥接失败抛明确错误，
/// 由调用侧（`ContentBrowseUseCases._runSpider`）收敛为 Failure。
library;

import 'dart:async';
import 'dart:convert';

import '../../domain/entities/spider/engine_type.dart';
import '../../domain/entities/spider/spider_engine.dart';
import '../../domain/entities/spider/spider_models.dart';
import 'node_http_client.dart';

/// Node / NodeLX 桥接引擎（实现 [SpiderEngine]）。
class NodeBridgeEngine implements SpiderEngine {
  /// [engineType] 须为 node / nodeLX；[client] 可注入（测试用 fake）。
  NodeBridgeEngine({
    required this.engineType,
    required NodeHttpClient client,
    this.siteKey,
    this.baseUrl,
    this.requestId,
  })  : assert(
          engineType == SpiderEngineType.node ||
              engineType == SpiderEngineType.nodeLX,
          'NodeBridgeEngine 仅支持 node / nodeLX',
        ),
        _client = client;

  @override
  final SpiderEngineType engineType;

  /// 站点键（`nodejs_xxx` / `csp_xxx`，含前缀；对齐 iOS `NodeSpiderEngine.siteKey`）。
  final String? siteKey;

  /// 站点脚本地址（node 源常为空；桥协议不依赖）。
  final String? baseUrl;

  /// 请求追踪号。
  final String? requestId;

  final NodeHttpClient _client;
  bool _ready = false;

  /// 播放动作名偏好缓存（对齐 iOS `playActionOverride`，NodeSpiderEngine.swift:41）：
  /// kstore bundle 实测注册 `/3/play`（`/3/player` 恒 404）；某蜘蛛只注册
  /// `player`（旧 TVBox 协议）时首次 404 后记住并复用，避免每次多一次 404 往返。
  String? _playActionOverride;

  @override
  void Function(String)? onLog;

  // ─────────────── key 归一化（对齐 iOS bundleKeyMap / normalizeNodeKey） ───────────────

  /// 订阅源 key → bundle 注册 key（对齐 iOS `bundleKeyMap`，
  /// NodeSpiderEngine.swift:61-L89：来自 node-spider-key-map.json，84 条）。
  static const Map<String, String> bundleKeyMap = <String, String>{
    'Douban': 'douban',
    'Doubanaaaa': 'gengxin',
    'Wexconfig': 'baseset',
    'MyPan': 'mypan',
    '玩偶': 'wogg',
    'AiNewGuanYing': 'guanying',
    'AiQwMkv': 'qwmkv',
    'AiNewPianKu': 'pianku',
    'AiNewHuBan': 'huban',
    'AiNewMuOu': 'muou',
    'AiNewDuoDuo': 'duoduo',
    'AiNewJuTou': 'jutou',
    'AiNewLibvio': 'libvio',
    '原盘': 'zhinan4k',
    '蜗牛': 'woniu4k',
    'AiPan1Me': 'pan123ziyuan',
    'AiNewYiDong4K': 'yidong4k',
    'WexHanXiaoQuan': 'hanxiaoquan',
    'WexAiGuaZi': 'guazi',
    'WexAiDuBoKu': 'wexDuBoKu',
    'WexAiYueYue': 'wexYueYue',
    'WexAiWenCai': 'wencai',
    'WexFengYe4K': 'wexfengye4k',
    'AppV7 | 大师兄': 'appv7dashixiong',
    'AppV7 | 粉猪追剧': 'appv7fenzhu',
    'AppV7 | 咸鱼': 'appv7xianyu',
    'AppV7 | 追剧达人': 'appv7zhuijudaren',
    'AppV7 | 小柚子': 'appv7xiaoyouzi',
    'AppV7 | 小柠檬': 'appv7xiaoningmeng',
    'AppV7 | 蒙太奇': 'appv7mengtaiqi',
    'AppV7 | 零零七影视': 'appv7linglingqi',
    'AppV7 | 小柿子': 'appv7xiaoshizi',
    'AppV7 | 小黄人': 'appv7xiaohuangren',
    'WexAiYiYs': 'yiyingshi',
    'WexAiReBo': 'rebo',
    'WexAiBoBo': 'bobo',
    'WexAiIkanBot': 'ikanbot',
    'LiveAiHuYa': 'huya',
    'LiveAiDouYu': 'douyu',
    'LiveAiBiLi': 'bililive',
    'ManJuAiHongGuo': 'manjuhongguo',
    'ManJuAiHuoLong': 'manjuhuolong',
    'ManJuAiQiMao': 'manjuqimao',
    'ManJuAiXiFan': 'manjuxifan',
    'ManJuAiHeMa': 'hema',
    'DuanJuAiHaoKan': 'baiduduanju',
    'DuanJuAiQiMiao': 'duanjuqimiao',
    'DuanJuAiXingYa': 'duanjuxingya',
    'DuanJuAiWeiGuan': 'duanjuweiguan',
    'AnimeXiFan': 'animexifan',
    'AnimeCiYuanCheng': 'animeciyuancheng',
    'AnimeAiMoDu': 'animemodu',
    'BookHongGuo': 'bookhongguo',
    'BookHeMa': 'bookhema',
    'BookAiShiJie': 'bookaishijie',
    'BookAiYueTing': 'bookaiyueting',
    'ChildrenAiBaoBao': 'childrenaibaobao',
    'ChildrenAiBeiWa': 'childrenaibeiwa',
    'ChildrenAiTuTu': 'childrenaitutu',
    'MusicAiQingTing': 'musicaiqingting',
    'MusicAiIKtv': 'musicaikg',
    'MusicAiKuWoa': 'musicaikuwoa',
    'MusicAi163': 'musicai163',
    'MusicAiKuWo': 'musicaikuwo',
    'MusicAiLunHui': 'musicailunhui',
    'SportAiFeiQiu': 'sportaifeiqiu',
    'SportAiGuaZi': 'sportaiguazi',
    'SportAiKanQiuTong': 'sportaikanqiutong',
    'SportAiKanqiu': 'sportaikanqiu',
    'SportAiKaFei': 'sportaikafei',
    'SportAiWwe': 'sportaiwwe',
    'FakeAi115Share': 'fake115share',
    'biliys': 'biliys',
    'bilibili': 'bilibili',
    'bilixiqu': 'bilixiqu',
    'biliych': 'biliych',
    '少儿教育': '少儿教育',
    '小学课堂': '小学课堂',
    '初中课堂': '初中课堂',
    '高中教育': '高中教育',
    'SoAiHaiYin': 'soaihaiyin',
    'SoAiPanSoo': 'soaipansoo',
    'SoAiQuPanShe': 'soaiqupanshe',
    'SoKaKa': 'sokaka',
  };

  /// 归一化：去前缀 → 映射表 → 小写兜底 → 原样（对齐 iOS `normalizeNodeKey`）。
  static String normalizeNodeKey(String key) {
    String stripped = key;
    const List<String> prefixes = <String>['nodejs_', 'csp_'];
    for (final String prefix in prefixes) {
      if (stripped.startsWith(prefix)) {
        stripped = stripped.substring(prefix.length);
        break;
      }
    }
    final String? mapped = bundleKeyMap[stripped];
    if (mapped != null) return mapped;
    final String lowered = stripped.toLowerCase();
    if (lowered != stripped) return lowered;
    return stripped;
  }

  // ─────────────── 生命周期（node：远端常驻 no-op；nodeLX：同 iOS 空语义） ───────────────

  @override
  Future<void> loadScript(String script) async {
    onLog?.call('Node 桥：蜘蛛脚本常驻远端进程（loadScript no-op，对齐 iOS）');
  }

  @override
  Future<void> loadLibrary(String script) async {}

  @override
  Future<void> loadScriptFromURL(String urlString) async {
    onLog?.call('Node 桥：蜘蛛脚本常驻远端进程（loadScriptFromURL no-op）');
  }

  @override
  Future<void> registerSpider() async {
    _ready = true;
    onLog?.call('Node 桥：registerSpider → ready（可用性由 NodeRuntimeManager 决定）');
  }

  @override
  bool get isSpiderReady => _ready;

  // ─────────────── 5 个操作 ───────────────

  @override
  Future<HomeContentResult> callHomeContent() async {
    if (engineType == SpiderEngineType.nodeLX) {
      // 对齐 iOS LXBridgeEngine：lx 无首页，空返回（不进入视频内容链）。
      return const HomeContentResult();
    }
    return _call<HomeContentResult>(
      action: 'home',
      body: const <String, Object?>{},
      parse: HomeContentResult.fromJson,
    );
  }

  @override
  Future<SearchContentResult> callSearchContent(String keyword, int pg) async {
    if (engineType == SpiderEngineType.nodeLX) {
      // 对齐 iOS LXBridgeEngine：lx 的 search 不进入视频搜索返回集。
      return SearchContentResult(page: pg, pagecount: 1);
    }
    return _call<SearchContentResult>(
      action: 'search',
      body: <String, Object?>{'wd': keyword, 'pg': pg},
      parse: SearchContentResult.fromJson,
    );
  }

  @override
  Future<CategoryContentResult> callCategoryContent(
      String tid, int pg, String extend) async {
    if (engineType == SpiderEngineType.nodeLX) {
      return const CategoryContentResult(page: 1, pagecount: 1);
    }
    return _call<CategoryContentResult>(
      action: 'category',
      body: <String, Object?>{'tid': tid, 'pg': pg, 'extend': extend},
      parse: CategoryContentResult.fromJson,
    );
  }

  @override
  Future<DetailContentResult> callDetailContent(String ids) async {
    if (engineType == SpiderEngineType.nodeLX) {
      return const DetailContentResult();
    }
    // 对齐 iOS：bundle 蜘蛛 detail 统一读 body.id（kstore 258 处 body?.id、
    // 0 处读 ids）；同时携带 ids 兼容未来读取多数的实现。
    return _call<DetailContentResult>(
      action: 'detail',
      body: <String, Object?>{'id': ids, 'ids': ids},
      parse: DetailContentResult.fromJson,
    );
  }

  @override
  Future<PlayerContentResult> callPlayerContent(
      String vodId, String flag, String url) async {
    if (engineType == SpiderEngineType.nodeLX) {
      return PlayerContentResult(parse: 0);
    }
    // 对齐 iOS：bundle 蜘蛛 play 统一读 body.id 作为播放地址（如枫叶
    // `bqt(r5(t.body.id))`、AppV7 读 c.id），必须传 url 而非 vodId。
    final Map<String, Object?> body = <String, Object?>{
      'id': url,
      'ids': url,
      'flag': flag,
      'url': url,
    };
    if (_playActionOverride != null) {
      return _call<PlayerContentResult>(
        action: _playActionOverride!,
        body: body,
        parse: PlayerContentResult.fromJson,
      );
    }
    try {
      final PlayerContentResult r = await _call<PlayerContentResult>(
        action: 'play',
        body: body,
        parse: PlayerContentResult.fromJson,
      );
      _playActionOverride = 'play';
      return r;
    } on SpiderException catch (e) {
      // 对齐 iOS：仅 HTTP 404 回退旧协议 player（其余错误原样抛出）。
      if (e.message.contains('HTTP 404')) {
        _playActionOverride = 'player';
        onLog?.call('Node 桥：/3/play 404，回退旧协议 /3/player');
        return _call<PlayerContentResult>(
          action: 'player',
          body: body,
          parse: PlayerContentResult.fromJson,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    await _client.close();
    _ready = false;
  }

  // ─────────────── 桥接实现（对齐 iOS perform，NodeSpiderEngine.swift:163-L260） ───────────────

  Future<T> _call<T>({
    required String action,
    required Map<String, Object?> body,
    required T Function(Map<String, Object?>) parse,
  }) async {
    final String key = siteKey ?? '';
    if (key.isEmpty) {
      throw const SpiderException(SpiderErrorCode.runtime, '站点 key 缺失，无法桥接 Node 蜘蛛');
    }
    final String nodeKey = normalizeNodeKey(key);
    // pathSegments 自动百分号编码（中文源 key：少儿教育等，对齐 iOS
    // addingPercentEncoding(.urlPathAllowed)，否则无效 URL 桥接恒失败）。
    // Uri(pathSegments:) 生成相对路径（无前导斜杠），补齐后为
    // `/spider/{nodeKey}/3/{action}`。
    final String path =
        '/${Uri(pathSegments: <String>['spider', nodeKey, '3', action]).toString()}';
    final String rawBody = jsonEncode(body);
    final NodeHttpResponse res;
    try {
      res = await _client.post(path, rawBody);
    } on TimeoutException {
      throw SpiderException(SpiderErrorCode.timeout, '桥接蜘蛛 $key $action 超时');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SpiderException(
        SpiderErrorCode.runtime,
        'POST $path → HTTP ${res.statusCode}',
      );
    }
    if (res.body.trim().isEmpty) {
      throw const SpiderException(SpiderErrorCode.protocol, '返回空数据');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } on FormatException {
      throw const SpiderException(SpiderErrorCode.protocol, '响应解码失败（非 JSON）');
    }
    if (decoded is! Map<String, Object?>) {
      if (decoded is Map) {
        return parse(decoded.cast<String, Object?>());
      }
      throw const SpiderException(SpiderErrorCode.protocol, '响应解码失败（非对象）');
    }
    return parse(decoded);
  }
}
