/// 数据层：订阅配置加载器（批次 G · G-07）。
///
/// 唯一真相源：iOS `vbox/Services/SubscriptionManager.swift` 的 `loadConfig(from:)`
/// （L61-L281）+ `SpiderManager.loadSubscribeConfig` 的落库链路：
///   · 请求 UA：桌面 Chrome（L76）+ HTML 兜底 App UA `okhttp/4.9.3`（L77）；
///   · 2xx 校验 → HTML 前缀探测 → App UA 重试（L93-L113）；
///   · 清洗：逐行去 `//` / `#` 注释（L122-L131）→ 截取首个 `{` / `[`（L134）；
///   · 二次 HTML 检测（L140-L143）→ JSON 解析（L150-L171）；
///   · 站点合成 `SubscribeConfig.buildFromSource`（L186-L253）；
///   · 无站点 → 「该订阅源未包含任何可用站点」（L224-L231）；
///   · SQLite 落库 `persistToDatabase`（L295-L454）：subscription / zhanyuan /
///     apiyuan / jiexisetting。
///
/// 差异登记：Dart `jsonDecode` 无 `fragmentsAllowed` 开关，故 iOS 的「strict 失败
/// → 非严格重试」合并为一次解析，失败统一报「无效JSON格式」；其余错误文案逐字对齐。
library;

import 'dart:convert';

import '../../../core/network/http_client.dart';
import '../../../domain/entities/library/library.dart';
import '../../../domain/entities/spider/site_config.dart';
import '../../../domain/entities/subscribe/subscribe.dart';
import '../../models/apiyuan.dart';
import '../../models/jiexisetting.dart';
import '../../models/zhanyuan.dart';
import '../local/database_manager.dart';
import '../local/subscribe_config_store.dart';

/// 桌面 Chrome UA（对齐 iOS L76）。
const String kSubscribeDesktopUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// App UA（对齐 iOS L77，部分站点需此 UA 才返回 JSON）。
const String kSubscribeAppUA = 'okhttp/4.9.3';

/// 订阅配置加载器。
class SubscribeConfigLoader {
  /// 构造（[client] / [database] / [store] / [nowSeconds] 均可注入，便于单测）。
  SubscribeConfigLoader({
    HttpClient? client,
    DatabaseManager? database,
    SubscribeConfigStore? store,
    int Function()? nowSeconds,
  })  : _client = client ?? HttpClient(),
        _db = database ?? DatabaseManager.instance,
        _store = store ?? SubscribeConfigStore.shared,
        _now = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final HttpClient _client;
  final DatabaseManager _db;
  final SubscribeConfigStore _store;
  final int Function() _now;

  /// 拉取并加载订阅源。
  ///
  /// 返回 null 表示成功；非 null 为错误消息（同步写入 [store] 的加载/错误态）。
  Future<String?> load(String urlString) async {
    final SubscribeConfigStore store = _store;
    store.setLoading(true);

    final String trimmed = urlString.trim();
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      store.setError('无效的URL');
      return '无效的URL';
    }

    try {
      // ① 桌面 UA 请求。
      HttpClientResponse res = await _client.get(
        uri,
        headers: const <String, String>{'User-Agent': kSubscribeDesktopUA},
      );
      if (!res.isOk) {
        final String msg = '服务器返回错误: ${res.statusCode}';
        store.setError(msg);
        return msg;
      }

      // ② 收到 HTML → App UA 重试（对齐 L93-L113）。
      String text = res.text;
      if (_looksLikeHtmlPrefix(text)) {
        final HttpClientResponse retry = await _client.get(
          uri,
          headers: const <String, String>{'User-Agent': kSubscribeAppUA},
        );
        if (retry.isOk && !_looksLikeHtmlPrefix(retry.text)) {
          text = retry.text;
        }
      }

      // ③ 清洗注释与非 JSON 前缀。
      text = _stripCommentsAndPrologue(text);

      // ④ 二次 HTML 检测（含 `<!`）。
      if (_looksLikeHtmlPrefix(text) ||
          text.trimLeft().toLowerCase().startsWith('<!')) {
        const String msg = '该地址返回的是网页，不是JSON配置';
        store.setError(msg);
        return msg;
      }

      // ⑤ JSON 解析。
      final Map<String, Object?>? json = _decodeJsonObject(text);
      if (json == null) {
        const String msg = '无效JSON格式';
        store.setError(msg);
        return msg;
      }

      // ⑥ 站点合成。
      final SubscribeConfig config = SubscribeConfig.buildFromSource(json);
      if (!config.hasSites) {
        const String msg = '该订阅源未包含任何可用站点';
        store.setError(msg);
        return msg;
      }

      // ⑦ SQLite 落库 + ⑧ 缓存与 URL 追加。
      await _persist(urlString: trimmed, json: json, config: config);
      await store.applyLoaded(trimmed, config);
      return null;
    } catch (e) {
      final String msg = '$e';
      store.setError(msg);
      return msg;
    }
  }

  // ─────────────── 文本清洗 / 解析 ───────────────

  static bool _looksLikeHtmlPrefix(String text) {
    final String t = text.trimLeft().toLowerCase();
    return t.startsWith('<!doctype') || t.startsWith('<html');
  }

  static String _stripCommentsAndPrologue(String text) {
    final List<String> lines = text.split('\n').where((String line) {
      final String t = line.trim();
      return !(t.startsWith('//') || t.startsWith('#'));
    }).toList();
    final String joined = lines.join('\n');
    final int brace = joined.indexOf(RegExp(r'[{\[]'));
    return brace > 0 ? joined.substring(brace) : joined;
  }

  static Map<String, Object?>? _decodeJsonObject(String text) {
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      // 落到统一失败口径。
    }
    return null;
  }

  // ─────────────── SQLite 落库（对齐 persistToDatabase）───────────────

  Future<void> _persist({
    required String urlString,
    required Map<String, Object?> json,
    required SubscribeConfig config,
  }) async {
    final int now = _now();

    // 1. 订阅源记录（对齐 L319-L324）。
    final Object? rawName = json['dyname'];
    final String dyname = (rawName?.toString().isNotEmpty ?? false)
        ? rawName!.toString()
        : '未知订阅';
    final String dyzz = json['dyzuozhe']?.toString() ?? '';
    await _db.upsert(
      SubscriptionItem.table,
      SubscriptionItem(
        dyname: dyname,
        dyurl: urlString,
        dyzz: dyzz,
        lastSyncAt: now,
      ).toRow(),
      primaryKey: 'id',
    );

    // 2. zhanyuan（对齐 L328-L420：先读 `zhanyuan` 字段，空则从 sites type=2 提取）。
    final List<Zhanyuan> zhanyuanSites = <Zhanyuan>[];
    final Object? rawZhanyuan = json['zhanyuan'];
    if (rawZhanyuan is List) {
      for (final Object? e in rawZhanyuan) {
        if (e is! Map) continue;
        final Zhanyuan? site = _zhanyuanFromItem(
          e.cast<String, Object?>(),
          urlString,
          now,
          defaultUA: Zhanyuan.defaultUA,
        );
        if (site != null) zhanyuanSites.add(site);
      }
    }
    if (zhanyuanSites.isEmpty) {
      for (final SiteConfig site in config.sites) {
        if (site.type != 2) continue;
        final Zhanyuan? built = _zhanyuanFromSite(site, urlString, now);
        if (built != null) zhanyuanSites.add(built);
      }
    }
    for (final Zhanyuan site in zhanyuanSites) {
      await _db.upsert(Zhanyuan.table, site.toMap(), primaryKey: 'id');
    }

    // 3. apiyuan（对齐 L422-L438）。
    final Object? rawApiyuan = json['apiyuan'];
    if (rawApiyuan is List) {
      for (final Object? e in rawApiyuan) {
        if (e is! Map) continue;
        final Map<String, Object?> item = e.cast<String, Object?>();
        final String name = (item['name'] ?? '').toString();
        final String searchurl = (item['searchurl'] ?? '').toString();
        if (name.isEmpty || searchurl.isEmpty) continue;
        await _db.upsert(
          Apiyuan.table,
          Apiyuan(
            name: name,
            searchurl: searchurl,
            searchua: item['searchua']?.toString() ?? '',
            detailurl: item['detailurl']?.toString() ?? '',
            detailua: item['detailua']?.toString() ?? '',
            isActive: true,
            dyurl: urlString,
          ).toMap(),
          primaryKey: 'id',
        );
      }
    }

    // 4. jiexisetting（对齐 L440-L451）。
    final Object? rawJiexi = json['jiexisetting'];
    if (rawJiexi is List) {
      for (final Object? e in rawJiexi) {
        if (e is! Map) continue;
        final Map<String, Object?> item = e.cast<String, Object?>();
        final String bianma = (item['bianma'] ?? '').toString();
        if (bianma.isEmpty) continue;
        await _db.upsert(
          Jiexisetting.table,
          Jiexisetting(
            bianma: bianma,
            zhuurl: item['zhuurl']?.toString() ?? '',
            beiurl: item['beiurl']?.toString() ?? '',
          ).toMap(),
          primaryKey: 'bianma',
        );
      }
    }
  }

  /// 由 zhanyuan JSON 条目构建（兼容 name/siteName/title 与
  /// searchUrl/search_url/url 字段名，对齐 L331-L341）。
  static Zhanyuan? _zhanyuanFromItem(
    Map<String, Object?> item,
    String urlString,
    int now, {
    required String defaultUA,
  }) {
    final String name = (item['name'] ??
            item['siteName'] ??
            item['title'] ??
            '')
        .toString();
    final String searchUrl = (item['searchUrl'] ??
            item['search_url'] ??
            item['url'] ??
            '')
        .toString();
    if (name.isEmpty || searchUrl.isEmpty) return null;
    return Zhanyuan(
      name: name,
      searchUrl: searchUrl,
      searchUA: item['searchUA']?.toString() ?? defaultUA,
      playUA: item['playUA']?.toString() ?? '',
      websearchurl: item['websearchurl']?.toString() ?? '',
      searchname: item['searchname']?.toString() ?? '',
      searchid: item['searchid']?.toString() ?? '',
      searchpic: item['searchpic']?.toString() ?? '',
      searchstarr: item['searchstarr']?.toString() ?? '',
      detaillist: item['detaillist']?.toString() ?? '',
      detailxl: item['detailxl']?.toString() ?? '',
      detailjs: item['detailjs']?.toString() ?? '',
      detailjsurl: item['detailjsurl']?.toString() ?? '',
      isActive: true,
      updatedAt: now,
      dyurl: urlString,
    );
  }

  /// 由 `sites` 中 type=2 的站点提取（解析 `ext` JSON，对齐 L369-L414）。
  static Zhanyuan? _zhanyuanFromSite(SiteConfig site, String urlString, int now) {
    final String api = site.api ?? '';
    if (api.isEmpty) return null;
    Map<String, Object?> ext = const <String, Object?>{};
    final String extJson = site.ext ?? '{}';
    try {
      final Object? decoded = jsonDecode(extJson);
      if (decoded is Map) ext = decoded.cast<String, Object?>();
    } catch (_) {
      // ext 非有效 JSON → 用 api 兜底。
    }
    final Object? extName = ext['name'];
    final Object? extSearch = ext['searchUrl'];
    final Map<String, Object?> merged = <String, Object?>{
      ...ext,
      'name': (extName?.toString().isNotEmpty ?? false) ? extName : site.name,
      'searchUrl':
          (extSearch?.toString().isNotEmpty ?? false) ? extSearch : api,
    };
    return _zhanyuanFromItem(merged, urlString, now, defaultUA: '');
  }
}