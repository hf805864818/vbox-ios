/// 平台层：腾讯视频原生 Spider（第 2 轮批次 B · B-11）。
///
/// 逆向来源：iOS `vbox/Services/TencentVideoNativeSpider.swift` —— 替代失效的
/// drpy JS 蜘蛛（drpy 版 `node.video.qq.com` 接口已失效），直接打腾讯
/// `pbaccess.video.qq.com` 原生 trpc 接口。本文件为其 Dart 移植：
/// - **搜索**：POST `MultiTerminalSearch/MbSearch`，解析 `normalList`
///   （排除 areaBoxList 推荐流），按类型白名单 + 去重 + 去除 HTML 标签；
/// - **详情**：双请求（详情页 + 剧集页）→ 基础信息 + 演员 + 剧集列表，
///   并按 `tabs` 的 `page_context` 分页拉取全部剧集；
/// - 请求/解码复用 B-09 [SpiderHttpBridge]（注入 fake transport 离线单测）。
library;

import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' show Random;

import '../../domain/entities/spider/spider_models.dart';
import 'spider_http_bridge.dart';

/// 腾讯视频原生 Spider。
class TencentVideoNativeSpider {
  TencentVideoNativeSpider({SpiderHttpBridge? bridge}) : _bridge = bridge ?? SpiderHttpBridge();

  static const String siteKey = 'drpy_js_腾云驾雾';

  final SpiderHttpBridge _bridge;

  static const String _apiHost = 'https://pbaccess.video.qq.com';

  /// 固定请求头（对齐 iOS `URLSessionConfiguration.httpAdditionalHeaders`）。
  static const Map<String, String> _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5410.0 Safari/537.36',
    'Origin': 'https://v.qq.com',
    'Referer': 'https://v.qq.com/',
    'Content-Type': 'application/json',
  };

  static final Random _rng = Random();

  /// 生成 v4 风格 UUID（对应 iOS `UUID().uuidString`，仅作客户端标识）。
  static String _uuid() {
    final String rand = List<String>.generate(
      32,
      (_) => _rng.nextInt(16).toRadixString(16),
    ).join();
    return '${rand.substring(0, 8)}-${rand.substring(8, 12)}-'
        '${rand.substring(12, 16)}-${rand.substring(16, 20)}-${rand.substring(20)}';
  }

  // ─────────────── 搜索 ───────────────

  /// 搜索（对齐 iOS `search(keyword:pg:)`）。
  Future<List<VodItem>> search(String keyword, {int pg = 1}) async {
    final Map<String, Object?> body = <String, Object?>{
      'version': '25021101',
      'clientType': 1,
      'filterValue': '',
      'uuid': _uuid(),
      'retry': 0,
      'query': keyword,
      'pagenum': pg - 1,
      'pagesize': 30,
      'queryFrom': 0,
      'searchDatakey': '',
      'transInfo': '',
      'isneedQc': true,
      'preQid': '',
      'adClientInfo': '',
      'extraInfo': <String, String>{
        'isNewMarkLabel': '1',
        'multi_terminal_pc': '1',
        'themeType': '1',
      },
    };

    final String? json = await _post(
      '/trpc.videosearch.mobile_search.MultiTerminalSearch/MbSearch?vplatform=2',
      body,
    );
    if (json == null) return <VodItem>[];

    final Map<String, Object?>? root = _asMap(jsonDecode(json));
    if (root == null) return <VodItem>[];

    const Set<String> validTypes = <String>{
      '电视剧', '电影', '综艺', '纪录片', '动漫', '少儿', '短剧',
    };
    final List<VodItem> items = <VodItem>[];
    final Set<String> seenCids = <String>{};

    final Object? normalList = _deep(root, <String>[
      'data', 'normalList', 'itemList',
    ]);
    if (normalList is List) {
      for (final Object? k in normalList) {
        final Map<String, Object?>? item = _asMap(k);
        if (item == null) continue;
        final Map<String, Object?>? doc = _asMap(item['doc']);
        final String? docId = doc == null ? null : _asString(doc['id']);
        final Map<String, Object?>? videoInfo = _asMap(item['videoInfo']);
        if (docId == null || docId.isEmpty || videoInfo == null) continue;

        final String? title = _asString(videoInfo['title']);
        final String? typeName = _asString(videoInfo['typeName']);
        if (title == null || typeName == null || !validTypes.contains(typeName)) {
          continue;
        }
        final String subTitle = _asString(videoInfo['subTitle']) ?? '';
        if (subTitle.contains('外站')) continue;
        if (seenCids.contains(docId)) continue;
        seenCids.add(docId);

        items.add(VodItem(
          vodId: docId,
          vodName: removeHtmlTags(title),
          vodPic: _asString(videoInfo['imgUrl']) ?? '',
          vodRemarks: '$typeName ⭐${_asString(videoInfo['year']) ?? ''}',
        ));
      }
    }
    return items;
  }

  // ─────────────── 详情 ───────────────

  /// 详情（对齐 iOS `detail(ids:)`）。
  Future<VodItem?> detail(String ids) async {
    final String cid = ids;

    final Map<String, Object?> detailBody = <String, Object?>{
      'page_params': <String, Object?>{
        'req_from': 'web',
        'cid': cid,
        'vid': '',
        'lid': '',
        'page_type': 'detail_operation',
        'page_id': 'detail_page_introduction',
      },
      'has_cache': 1,
    };
    final Map<String, Object?> episodeBody = <String, Object?>{
      'page_params': <String, Object?>{
        'req_from': 'web_vsite',
        'page_id': 'vsite_episode_list',
        'page_type': 'detail_operation',
        'id_type': '1',
        'page_size': '',
        'cid': cid,
        'vid': '',
        'lid': '',
        'page_num': '',
        'page_context': '',
        'detail_page_type': '1',
      },
      'has_cache': 1,
    };

    const String detailPath =
        '/trpc.universal_backend_service.page_server_rpc.PageServer/GetPageData'
        '?video_appid=3000010&vplatform=2&vversion_name=8.2.96';

    final String? dJson = await _post(detailPath, detailBody);
    final String? eJson = await _post(detailPath, episodeBody);
    if (dJson == null || eJson == null) return null;

    final Map<String, Object?>? vdata = _asMap(jsonDecode(dJson));
    final Map<String, Object?>? edata = _asMap(jsonDecode(eJson));
    if (vdata == null || edata == null) return null;

    final Map<String, Object?>? itemParams =
        _asMap(_deep(vdata, const <String>[
      'data', 'module_list_datas', '0', 'module_datas', '0',
      'item_data_lists', 'item_datas', '0', 'item_params',
    ]));
    if (itemParams == null) return null;

    final String title = _asString(itemParams['title']) ?? '';
    final String pic = _asString(itemParams['new_pic_hz']) ?? '';
    final String year = _asString(itemParams['year']) ?? '';
    final String area = _asString(itemParams['area_name']) ?? '';
    final String desc = _asString(itemParams['cover_description']) ?? '';
    final String typeName = _asString(itemParams['sub_genre']) ?? '';

    // 演员
    final List<String> actors = <String>[];
    final Object? starList = _deep(vdata, const <String>[
      'data', 'module_list_datas', '0', 'module_datas', '0',
      'item_data_lists', 'item_datas', '0', 'sub_items',
      'star_list', 'item_datas',
    ]);
    if (starList is List) {
      for (final Object? star in starList) {
        final Map<String, Object?>? s = _asMap(star);
        if (s == null) continue;
        final String? name = _asString(_asMap(s['item_params'])?['name']);
        if (name != null) actors.add(name);
      }
    }

    // 剧集
    final (List<String> plist, List<String> ylist) =
        await processEpisodes(edata, episodeBody, cid);
    if (plist.isEmpty && ylist.isEmpty) return null;

    final List<String> names = <String>['腾讯视频'];
    final List<String> urls = <String>[];
    if (plist.isNotEmpty) {
      urls.add(plist.join('#'));
    } else {
      names.clear();
    }
    if (ylist.isNotEmpty) {
      urls.add(ylist.join('#'));
    } else if (names.isNotEmpty) {
      names.removeLast();
    }

    return VodItem(
      vodId: ids,
      vodName: title,
      vodPic: pic,
      vodRemarks: '$typeName $year',
      vodYear: year,
      vodArea: area,
      vodActor: actors.join(','),
      vodContent: desc,
      vodPlayFrom: names.join(r'$$$'),
      vodPlayUrl: urls.join(r'$$$'),
    );
  }

  // ─────────────── 剧集分页 ───────────────

  Future<(List<String>, List<String>)> processEpisodes(
    Map<String, Object?> edata,
    Map<String, Object?> episodeBody,
    String cid,
  ) async {
    final List<String> plist = <String>[];
    final List<String> ylist = <String>[];

    final Object? modules = _deep(edata, const <String>[
      'data', 'module_list_datas',
    ]);
    final Object? lastModule =
        modules is List && modules.isNotEmpty ? modules.last : null;
    final Object? mDatas = _asMap(lastModule)?['module_datas'];
    final Object? lastMData = mDatas is List && mDatas.isNotEmpty ? mDatas.last : null;
    final Object? itemDatas =
        _asMap(_asMap(lastMData)?['item_data_lists'])?['item_datas'];

    if (itemDatas is List) {
      _collectEpisodes(itemDatas, cid, plist, ylist);
    }

    // 其它 tab 分页
    final Map<String, Object?>? lastM = _asMap(lastMData);
    final String? tabsStr = _asString(_asMap(lastM?['module_params'])?['tabs']);
    if (tabsStr != null) {
      final Object? tabsObj = jsonDecode(tabsStr);
      if (tabsObj is List && tabsObj.length > 1) {
        const String detailPath =
            '/trpc.universal_backend_service.page_server_rpc.PageServer/GetPageData'
            '?video_appid=3000010&vplatform=2&vversion_name=8.2.96';
        final List<Object?> remainingTabs = tabsObj.sublist(1);
        for (final Object? tab in remainingTabs) {
          final Map<String, Object?>? tabMap = _asMap(tab);
          final String? pageCtx = tabMap == null ? null : _asString(tabMap['page_context']);
          if (pageCtx == null) continue;

          final Map<String, Object?> newBody =
              _cloneBody(episodeBody, pageCtx);
          final String? json = await _post(detailPath, newBody);
          if (json == null) continue;
          final Map<String, Object?>? jmap = _asMap(jsonDecode(json));
          if (jmap == null) continue;
          final Object? moreItems = _deep(jmap, const <String>[
            'data', 'module_list_datas', 'last', 'module_datas', 'last',
            'item_data_lists', 'item_datas',
          ]);
          if (moreItems is List) {
            _collectEpisodes(moreItems, cid, plist, ylist);
          }
        }
      }
    }

    return (plist, ylist);
  }

  void _collectEpisodes(
    List<Object?> itemDatas,
    String cid,
    List<String> plist,
    List<String> ylist,
  ) {
    for (final Object? item in itemDatas) {
      final Map<String, Object?>? m = _asMap(item);
      if (m == null) continue;
      final String? itemId = _asString(m['item_id']);
      if (itemId == null) continue;
      final String title = _asString(_asMap(m['item_params'])?['union_title']) ?? '';
      final String entry = '$title\$https://v.qq.com/x/cover/$cid/$itemId.html';
      if (title.contains('预告')) {
        ylist.add(entry);
      } else {
        plist.add(entry);
      }
    }
  }

  Map<String, Object?> _cloneBody(
    Map<String, Object?> episodeBody,
    String pageCtx,
  ) {
    final Map<String, Object?> newBody =
        <String, Object?>{...episodeBody};
    final Map<String, Object?> pageParams = <String, Object?>{
      ...?_asMap(episodeBody['page_params']),
    };
    pageParams['page_context'] = pageCtx;
    newBody['page_params'] = pageParams;
    return newBody;
  }

  // ─────────────── 请求辅助 ───────────────

  /// POST JSON；网络失败/非 2xx 返回 null（对齐 iOS `session.data` 失败分支）。
  Future<String?> _post(String path, Map<String, Object?> body) async {
    final SpiderHttpResult res = await _bridge.request(
      '$_apiHost$path',
      options: SpiderHttpOptions(
        method: 'POST',
        headers: _headers,
        data: jsonEncode(body),
        timeout: const Duration(seconds: 12),
      ),
    );
    if (!res.ok) return null;
    return res.content;
  }

  // ─────────────── 深取值 ───────────────

  /// 安全按 key 链访问嵌套结构，数字字符串 key 作为 list 索引，`last` 取末元素。
  static Object? _deep(Object? root, List<String> keys) {
    Object? current = root;
    for (final String key in keys) {
      if (current == null) return null;
      if (current is Map<String, Object?>) {
        current = current[key];
      } else if (current is List) {
        if (key == 'last') {
          current = current.isEmpty ? null : current.last;
        } else {
          final int? idx = int.tryParse(key);
          if (idx == null || idx < 0 || idx >= current.length) return null;
          current = current[idx];
        }
      } else {
        return null;
      }
    }
    return current;
  }

  static Map<String, Object?>? _asMap(Object? v) {
    if (v is Map<String, Object?>) return v;
    if (v is Map) {
      return v.map((Object? k, Object? v_) => MapEntry(k.toString(), v_));
    }
    return null;
  }

  static String? _asString(Object? v) => v is String ? v : null;

  /// 去除 HTML 标签（对齐 iOS `removeHtmlTags`）。
  static String removeHtmlTags(String html) =>
      html.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}