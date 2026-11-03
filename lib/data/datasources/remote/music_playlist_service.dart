/// 数据层：网络音乐歌单 / 榜单远程服务（批次 G · G-音1）。
///
/// 唯一真相源：[MusicPlaylistService.swift](../../../vbox/Services/MusicPlaylistService.swift)
/// （iOS `MusicPlaylistService` + 5 个平台实现：netease / qq / kugou / kuwo / migu）。
///
/// 职责：按平台聚合歌单分类、歌单广场、歌单详情、榜单列表、榜单详情、歌单搜索；
/// 逐平台对齐 iOS 的接口地址、请求头、查询参数、JSON 字段路径与兜底逻辑。
///
/// 对齐口径：
/// - 模型复用领域层 `music_playlist.dart`，本层只负责请求与解析。
/// - 传输走项目 [HttpClient]（GET / postForm），UA 由客户端统一注入；
///   平台差异只体现在 `Referer` 等业务头（对齐 iOS `*Headers()`）。
/// - 网络/解析失败一律吞掉异常并返回空列表 / null（对齐 iOS `guard ... else { return [] }`）。
/// - 字段提取沿用 iOS 容错 helper（safeString/safeInt/...），行为一致。
///
/// 不做的事：音源解析、播放地址获取、歌单缓存 —— 分别属 lx 桥接层与仓库层。
library;

import 'dart:async';
import 'dart:convert';

import '../../../core/network/http_client.dart';
import '../../../domain/entities/music/music_playlist.dart';

/// 网络音乐歌单 / 榜单服务。
class MusicPlaylistService {
  /// 构造（[client] 便于测试注入 MockClient）。
  MusicPlaylistService({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  // MARK: - HTTP Helpers

  /// GET 并解析 JSON。
  ///
  /// 对齐 iOS `httpGet(url:headers:)`：不校验状态码，直接尝试 JSON 反序列化，
  /// 任何网络/解析异常返回 `null`。
  Future<Object?> _httpGet(String url, Map<String, String> headers) async {
    try {
      final HttpClientResponse res =
          await _client.get(Uri.parse(url), headers: headers);
      return jsonDecode(res.text);
    } catch (_) {
      return null;
    }
  }

  /// POST 表单并解析 JSON。
  ///
  /// 对齐 iOS `httpPost(url:body:headers:)`：`body` 为已编码的
  /// `application/x-www-form-urlencoded` 字符串（由 [_formEncode] 生成），
  /// 这里借助项目客户端 [HttpClient.postForm] 发送（内容类型对齐）。
  /// 任何网络/解析异常返回 `null`。
  Future<Object?> _httpPost(
    String url,
    String body,
    Map<String, String> headers,
  ) async {
    try {
      final HttpClientResponse res = await _client.postForm(
        Uri.parse(url),
        Uri.splitQueryString(body),
        headers: headers,
      );
      return jsonDecode(res.text);
    } catch (_) {
      return null;
    }
  }

  // MARK: - JSON Helpers

  /// 值转 `Map<String, Object?>`（对齐 iOS `as? [String: Any]`）。
  Map<String, Object?>? _asDict(Object? value) {
    if (value is Map) {
      return value.cast<String, Object?>();
    }
    return null;
  }

  /// 值转 `List<Object?>`（对齐 iOS `as? [Any]`）。
  List<Object?>? _asList(Object? value) {
    if (value is List) {
      return value.cast<Object?>();
    }
    return null;
  }

  /// 提取字符串（对齐 iOS `safeString`：String / Int / Double / NSNumber）。
  String? _safeString(Map<String, Object?> dict, String key) {
    final Object? v = dict[key];
    if (v is String) return v;
    if (v is int) return v.toString();
    if (v is double) return v.toInt().toString();
    if (v is num) return v.toString();
    return null;
  }

  /// 提取整数（对齐 iOS `safeInt`：Int / Double / NSNumber / 数字字符串）。
  int? _safeInt(Map<String, Object?> dict, String key) {
    final Object? v = dict[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is num) return v.toInt();
    if (v is String) {
      final int? i = int.tryParse(v);
      if (i != null) return i;
      final double? d = double.tryParse(v);
      if (d != null) return d.toInt();
    }
    return null;
  }

  /// 提取浮点数（对齐 iOS `safeDouble`）。
  ///
  /// 说明：iOS 侧定义但当前未被任何平台实现调用；为保持 1:1 结构而保留。
  // ignore: unused_element
  double? _safeDouble(Map<String, Object?> dict, String key) {
    final Object? v = dict[key];
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// 提取子字典（对齐 iOS `safeDict`）。
  Map<String, Object?>? _safeDict(Map<String, Object?> dict, String key) =>
      _asDict(dict[key]);

  /// 提取子数组（对齐 iOS `safeArray`）。
  List<Object?>? _safeArray(Map<String, Object?> dict, String key) =>
      _asList(dict[key]);

  /// 从「字典数组」中抽取某字段并以 `, ` 连接（对齐 iOS `safeStringFromDictArray`）。
  String _safeStringFromDictArray(List<Object?>? array, String key) {
    if (array == null) return '';
    final List<String> names = <String>[];
    for (final Object? item in array) {
      final Map<String, Object?>? d = _asDict(item);
      if (d == null) continue;
      final String? s = _safeString(d, key);
      if (s != null) names.add(s);
    }
    return names.join(', ');
  }

  /// 反序列化对象为 JSON 字符串，失败返回 null（对齐 iOS `toJsonString`）。
  String? _toJsonString(Object? obj) {
    try {
      return jsonEncode(obj);
    } catch (_) {
      return null;
    }
  }

  /// 返回第一个非空字符串（对齐 iOS `firstNonNil`）。
  String? _firstNonNil(List<String?> values) {
    for (final String? v in values) {
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  // MARK: - Utility Helpers

  /// 播放量文案：`>=1亿` 用一位小数「亿」，`>=1万` 用「万」，否则原值。
  /// 对齐 iOS `formatPlayCount`。
  String? _formatPlayCount(int? count) {
    if (count == null || count <= 0) return null;
    if (count >= 100000000) {
      return '${(count / 100000000).toStringAsFixed(1)}亿';
    } else if (count >= 10000) {
      return '${count ~/ 10000}万';
    } else {
      return count.toString();
    }
  }

  /// 时长归一（>10000 视为毫秒→秒）。对齐 iOS `normalizeDuration`。
  int? _normalizeDuration(int? value) {
    if (value == null || value <= 0) return null;
    if (value > 10000) {
      return value ~/ 1000;
    }
    return value;
  }

  /// 补全 `//` 开头的协议相对 URL 为 `https:`。对齐 iOS `ensureHTTPSPrefix`。
  String? _ensureHTTPSPrefix(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('//')) {
      return 'https:$url';
    }
    return url;
  }

  /// 构造查询项（对齐 iOS `URLQueryItem`）。
  MapEntry<String, String> _q(String name, String value) =>
      MapEntry<String, String>(name, value);

  /// 拼接带查询参数的 URL（对齐 iOS `buildURL(base:queryItems:)`）。
  Uri? _buildURL(String base, List<MapEntry<String, String>> queryItems) {
    final Uri? parsed = Uri.tryParse(base);
    if (parsed == null) return null;
    return parsed.replace(
      queryParameters: <String, String>{
        for (final MapEntry<String, String> e in queryItems) e.key: e.value,
      },
    );
  }

  /// 将 JSON 编码为单个查询参数后拼接 URL
  /// （对齐 iOS `buildURLWithEncodedJSON(base:paramName:json:)`，QQ 专用）。
  Uri? _buildURLWithEncodedJSON(
    String base,
    String paramName,
    Map<String, Object?> json,
  ) {
    final String jsonString = jsonEncode(json);
    return _buildURL(base, <MapEntry<String, String>>[
      _q(paramName, jsonString),
    ]);
  }

  /// 表单编码（对齐 iOS `formEncode`）。
  ///
  /// 说明：iOS 用 `.urlQueryAllowed` 编码；此处用 [Uri.encodeQueryComponent]，
  /// 会对 `&` / `=` 一并百分号编码，避免值中出现分隔符时破坏表单结构。
  String _formEncode(Map<String, String> params) {
    return params.entries
        .map((MapEntry<String, String> e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  // MARK: - Public API

  /// 拉取平台歌单分类。
  Future<List<PlaylistCategory>> getPlaylistCategories(
    MusicPlatformType platform,
  ) async {
    try {
      return switch (platform) {
        MusicPlatformType.netease => await _neteaseCategories(),
        MusicPlatformType.qq => await _qqCategories(),
        MusicPlatformType.kugou => await _kugouCategories(),
        MusicPlatformType.kuwo => await _kuwoCategories(),
        MusicPlatformType.migu => await _miguCategories(),
      };
    } catch (_) {
      return const <PlaylistCategory>[];
    }
  }

  /// 拉取平台歌单广场（[category] 为空时走推荐/全部）。
  Future<List<PlaylistItem>> getPlaylists(
    MusicPlatformType platform, {
    String? category,
    int page = 1,
  }) async {
    try {
      return switch (platform) {
        MusicPlatformType.netease =>
          await _neteasePlaylists(category, page),
        MusicPlatformType.qq => await _qqPlaylists(category, page),
        MusicPlatformType.kugou => await _kugouPlaylists(category, page),
        MusicPlatformType.kuwo => await _kuwoPlaylists(category, page),
        MusicPlatformType.migu => await _miguPlaylists(category, page),
      };
    } catch (_) {
      return const <PlaylistItem>[];
    }
  }

  /// 拉取歌单详情（含歌曲列表）。
  Future<PlaylistDetail?> getPlaylistDetail(
    MusicPlatformType platform,
    String id,
  ) async {
    try {
      return switch (platform) {
        MusicPlatformType.netease => await _neteasePlaylistDetail(id),
        MusicPlatformType.qq => await _qqPlaylistDetail(id),
        MusicPlatformType.kugou => await _kugouPlaylistDetail(id),
        MusicPlatformType.kuwo => await _kuwoPlaylistDetail(id),
        MusicPlatformType.migu => await _miguPlaylistDetail(id),
      };
    } catch (_) {
      return null;
    }
  }

  /// 拉取平台榜单列表。
  Future<List<RankingItem>> getRankings(MusicPlatformType platform) async {
    try {
      return switch (platform) {
        MusicPlatformType.netease => await _neteaseRankings(),
        MusicPlatformType.qq => await _qqRankings(),
        MusicPlatformType.kugou => await _kugouRankings(),
        MusicPlatformType.kuwo => await _kuwoRankings(),
        MusicPlatformType.migu => await _miguRankings(),
      };
    } catch (_) {
      return const <RankingItem>[];
    }
  }

  /// 拉取榜单详情（含歌曲列表）。
  ///
  /// 对齐 iOS `getRankingDetail`：netease / qq / migu 复用歌单详情，
  /// kugou / kuwo 走各自榜单详情接口。
  Future<PlaylistDetail?> getRankingDetail(
    MusicPlatformType platform,
    String id,
  ) async {
    try {
      return switch (platform) {
        MusicPlatformType.netease => await _neteasePlaylistDetail(id),
        MusicPlatformType.qq => await _qqPlaylistDetail(id),
        MusicPlatformType.kugou => await _kugouRankingDetail(id),
        MusicPlatformType.kuwo => await _kuwoRankingDetail(id),
        MusicPlatformType.migu => await _miguPlaylistDetail(id),
      };
    } catch (_) {
      return null;
    }
  }

  /// 搜索歌单。
  Future<List<PlaylistItem>> searchPlaylists(
    MusicPlatformType platform,
    String keyword, {
    int page = 1,
  }) async {
    try {
      return switch (platform) {
        MusicPlatformType.netease =>
          await _neteaseSearchPlaylists(keyword, page),
        MusicPlatformType.qq => await _qqSearchPlaylists(keyword, page),
        MusicPlatformType.kugou => await _kugouSearchPlaylists(keyword, page),
        MusicPlatformType.kuwo => await _kuwoSearchPlaylists(keyword, page),
        MusicPlatformType.migu => await _miguSearchPlaylists(keyword, page),
      };
    } catch (_) {
      return const <PlaylistItem>[];
    }
  }

  // MARK: - NetEase (网易云)

  /// 网易云请求头（对齐 iOS `neteaseHeaders`）。
  Map<String, String> _neteaseHeaders() =>
      <String, String>{'Referer': 'https://music.163.com'};

  Future<List<PlaylistCategory>> _neteaseCategories() async {
    const String url = 'https://music.163.com/api/playlist/catalogue';
    final Map<String, Object?>? result =
        _asDict(await _httpGet(url, _neteaseHeaders()));
    if (result == null) return const <PlaylistCategory>[];

    final List<PlaylistCategory> categories = <PlaylistCategory>[
      const PlaylistCategory(
        id: '全部',
        name: '全部',
        platform: MusicPlatformType.netease,
      ),
    ];

    final List<Object?>? sub = _safeArray(result, 'sub');
    if (sub != null) {
      for (final Object? item in sub) {
        final Map<String, Object?>? dict = _asDict(item);
        if (dict == null) continue;
        final String? name = _safeString(dict, 'name');
        if (name == null || name.isEmpty) continue;
        categories.add(
          PlaylistCategory(
            id: name,
            name: name,
            platform: MusicPlatformType.netease,
          ),
        );
      }
    }
    return categories;
  }

  Future<List<PlaylistItem>> _neteasePlaylists(
    String? category,
    int page,
  ) async {
    final String cat = category ?? '全部';
    final int offset = page * 35;
    final Uri? url = _buildURL(
      'https://music.163.com/api/playlist/list',
      <MapEntry<String, String>>[
        _q('cat', cat),
        _q('offset', offset.toString()),
        _q('limit', '35'),
        _q('order', 'hot'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _neteaseHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final List<Object?>? playlists = _safeArray(result, 'playlists');
    if (playlists == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in playlists) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final int? id = _safeInt(dict, 'id');
      if (id == null) continue;
      final String name = _safeString(dict, 'name') ?? '';
      final String coverURL = _safeString(dict, 'coverImgUrl') ?? '';
      final String? playCount = _formatPlayCount(_safeInt(dict, 'playCount'));
      final int? songCount = _safeInt(dict, 'trackCount');
      final Map<String, Object?>? creatorDict = _safeDict(dict, 'creator');
      final String? creator =
          creatorDict == null ? null : _safeString(creatorDict, 'nickname');

      items.add(
        PlaylistItem(
          id: 'wy_$id',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.netease,
          rawId: id.toString(),
        ),
      );
    }
    return items;
  }

  Future<PlaylistDetail?> _neteasePlaylistDetail(String id) async {
    const String url = 'https://music.163.com/api/v3/playlist/detail';
    final String body = _formEncode(<String, String>{
      'id': id,
      'n': '1000',
      's': '8',
    });
    final Map<String, Object?>? result =
        _asDict(await _httpPost(url, body, _neteaseHeaders()));
    if (result == null) return null;
    final Map<String, Object?>? playlist = _safeDict(result, 'playlist');
    if (playlist == null) return null;

    final String name = _safeString(playlist, 'name') ?? '';
    final String coverURL = _safeString(playlist, 'coverImgUrl') ?? '';
    final Map<String, Object?>? creatorDict = _safeDict(playlist, 'creator');
    final String? creator =
        creatorDict == null ? null : _safeString(creatorDict, 'nickname');
    final String? description = _safeString(playlist, 'description');
    final int songCount = _safeInt(playlist, 'trackCount') ?? 0;

    final List<PlaylistSong> songs = <PlaylistSong>[];
    final List<Object?>? tracks = _safeArray(playlist, 'tracks');
    if (tracks != null) {
      for (final Object? track in tracks) {
        final Map<String, Object?>? dict = _asDict(track);
        if (dict == null) continue;
        final int? songId = _safeInt(dict, 'id');
        if (songId == null) continue;
        final String songName = _safeString(dict, 'name') ?? '';
        final String artist =
            _safeStringFromDictArray(_safeArray(dict, 'ar'), 'name');
        final Map<String, Object?>? albumDict = _safeDict(dict, 'al');
        final String? album =
            albumDict == null ? null : _safeString(albumDict, 'name');
        final int? duration = _normalizeDuration(_safeInt(dict, 'dt'));
        final String? coverURL =
            albumDict == null ? null : _safeString(albumDict, 'picUrl');
        final String? rawInfo = _toJsonString(dict);

        songs.add(
          PlaylistSong(
            id: 'wy_$songId',
            name: songName,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: coverURL,
            platform: 'wy',
            rawInfo: rawInfo,
          ),
        );
      }
    }

    return PlaylistDetail(
      id: 'wy_$id',
      name: name,
      coverURL: coverURL,
      creator: creator,
      description: description,
      songCount: songCount,
      songs: songs,
      platform: MusicPlatformType.netease,
    );
  }

  Future<List<RankingItem>> _neteaseRankings() async {
    const String url = 'https://music.163.com/api/toplist/detail';
    final Map<String, Object?>? result =
        _asDict(await _httpGet(url, _neteaseHeaders()));
    if (result == null) return const <RankingItem>[];
    final List<Object?>? list = _safeArray(result, 'list');
    if (list == null) return const <RankingItem>[];

    final List<RankingItem> items = <RankingItem>[];
    for (final Object? entry in list) {
      final Map<String, Object?>? dict = _asDict(entry);
      if (dict == null) continue;
      final int? id = _safeInt(dict, 'id');
      if (id == null) continue;
      final String name = _safeString(dict, 'name') ?? '';
      final String? coverURL = _safeString(dict, 'coverImgUrl');
      final String? updateFreq = _safeString(dict, 'updateFrequency');

      items.add(
        RankingItem(
          id: 'wy_$id',
          name: name,
          coverURL: coverURL,
          updateFreq: updateFreq,
          platform: MusicPlatformType.netease,
          rawId: id.toString(),
        ),
      );
    }
    return items;
  }

  Future<List<PlaylistItem>> _neteaseSearchPlaylists(
    String keyword,
    int page,
  ) async {
    const String url = 'https://music.163.com/api/cloudsearch/pc';
    final int offset = page * 30;
    final String body = _formEncode(<String, String>{
      's': keyword,
      'type': '1000',
      'limit': '30',
      'offset': offset.toString(),
    });
    final Map<String, Object?>? result =
        _asDict(await _httpPost(url, body, _neteaseHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? searchResult = _safeDict(result, 'result');
    if (searchResult == null) return const <PlaylistItem>[];
    final List<Object?>? playlists = _safeArray(searchResult, 'playlists');
    if (playlists == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in playlists) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final int? id = _safeInt(dict, 'id');
      if (id == null) continue;
      final String name = _safeString(dict, 'name') ?? '';
      final String coverURL = _safeString(dict, 'coverImgUrl') ?? '';
      final String? playCount = _formatPlayCount(_safeInt(dict, 'playCount'));
      final int? songCount = _safeInt(dict, 'trackCount');
      final Map<String, Object?>? creatorDict = _safeDict(dict, 'creator');
      final String? creator =
          creatorDict == null ? null : _safeString(creatorDict, 'nickname');

      items.add(
        PlaylistItem(
          id: 'wy_$id',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.netease,
          rawId: id.toString(),
        ),
      );
    }
    return items;
  }

  // MARK: - QQ Music (QQ音乐)

  /// QQ 音乐请求头（对齐 iOS `qqHeaders`）。
  Map<String, String> _qqHeaders() =>
      <String, String>{'Referer': 'https://y.qq.com/'};

  Future<List<PlaylistCategory>> _qqCategories() async {
    final Map<String, Object?> requestBody = <String, Object?>{
      'comm': <String, Object?>{
        'uin': 0,
        'format': 'json',
        'ct': 24,
        'cv': 0,
      },
      'req': <String, Object?>{
        'module': 'playlist.PlayListCategoryServer',
        'method': 'get_category_content',
        'param': <String, Object?>{
          'callerId': '0',
          'callerType': '0',
          'categoryType': '1000000000',
          'size': '30',
        },
      },
    };

    final Uri? url = _buildURLWithEncodedJSON(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      'data',
      requestBody,
    );
    if (url == null) return const <PlaylistCategory>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _qqHeaders()));
    if (result == null) return const <PlaylistCategory>[];
    final Map<String, Object?>? req = _safeDict(result, 'req');
    if (req == null) return const <PlaylistCategory>[];
    final Map<String, Object?>? data = _safeDict(req, 'data');
    if (data == null) return const <PlaylistCategory>[];

    final List<PlaylistCategory> categories = <PlaylistCategory>[
      const PlaylistCategory(
        id: '',
        name: '全部',
        platform: MusicPlatformType.qq,
      ),
    ];

    final List<Map<String, Object?>> categoryList = <Map<String, Object?>>[];
    final Map<String, Object?>? category = _safeDict(data, 'category');
    final List<Object?>? nested = category == null
        ? null
        : _safeArray(category, 'categoryList');
    if (nested != null) {
      for (final Object? item in nested) {
        final Map<String, Object?>? dict = _asDict(item);
        if (dict != null) categoryList.add(dict);
      }
    } else {
      final List<Object?>? flat = _safeArray(data, 'categoryList');
      if (flat != null) {
        for (final Object? item in flat) {
          final Map<String, Object?>? dict = _asDict(item);
          if (dict != null) categoryList.add(dict);
        }
      }
    }

    for (final Map<String, Object?> group in categoryList) {
      final List<Object?>? vClass = _asList(group['vClass']);
      if (vClass != null) {
        for (final Object? tag in vClass) {
          final Map<String, Object?>? tagDict = _asDict(tag);
          if (tagDict == null) continue;
          final String id = _safeString(tagDict, 'id') ?? '';
          final String name = _safeString(tagDict, 'tagName') ?? '';
          if (name.isNotEmpty) {
            categories.add(
              PlaylistCategory(
                id: id,
                name: name,
                platform: MusicPlatformType.qq,
              ),
            );
          }
        }
      }
    }
    return categories;
  }

  Future<List<PlaylistItem>> _qqPlaylists(String? category, int page) async {
    final Map<String, Object?> param = <String, Object?>{
      'callerId': '0',
      'size': '30',
      'page': page - 1 < 0 ? 0 : page - 1,
      'type': 0,
    };
    if (category != null && category.isNotEmpty) {
      param['type'] = 1;
      param['tagId'] = category;
    }

    final Map<String, Object?> requestBody = <String, Object?>{
      'comm': <String, Object?>{
        'uin': 0,
        'format': 'json',
        'ct': 24,
        'cv': 0,
      },
      'req': <String, Object?>{
        'module': 'playlist.PlayListPlazaServer',
        'method': 'get_playlist_by_tag',
        'param': param,
      },
    };

    final Uri? url = _buildURLWithEncodedJSON(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      'data',
      requestBody,
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _qqHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? req = _safeDict(result, 'req');
    if (req == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(req, 'data');
    if (data == null) return const <PlaylistItem>[];

    final List<Object?>? playlists = _safeArray(data, 'playlistList') ??
        _safeArray(data, 'v_playlist') ??
        _safeArray(data, 'list');
    if (playlists == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in playlists) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'dirId'),
            _safeString(dict, 'tid'),
            _safeString(dict, 'disstid'),
            _safeInt(dict, 'dirId')?.toString(),
            _safeInt(dict, 'tid')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;

      final String name = _firstNonNil(<String?>[
            _safeString(dict, 'dirName'),
            _safeString(dict, 'dcName'),
            _safeString(dict, 'title'),
            _safeString(dict, 'dissname'),
          ]) ??
          '';
      final String coverURL = _firstNonNil(<String?>[
            _safeString(dict, 'picUrl'),
            _safeString(dict, 'picurl'),
            _safeString(dict, 'imgurl'),
            _safeString(dict, 'logo'),
          ]) ??
          '';
      final String? playCount = _formatPlayCount(
        _safeInt(dict, 'listenNum') ??
            _safeInt(dict, 'listennum') ??
            _safeInt(dict, 'playCount'),
      );
      final int? songCount =
          _safeInt(dict, 'songNum') ?? _safeInt(dict, 'songnum');
      final Map<String, Object?>? creatorDict = _safeDict(dict, 'creator');
      final String? creator =
          creatorDict == null ? null : _safeString(creatorDict, 'name');

      items.add(
        PlaylistItem(
          id: 'tx_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.qq,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  Future<PlaylistDetail?> _qqPlaylistDetail(String id) async {
    final Uri? url = _buildURL(
      'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
      <MapEntry<String, String>>[
        _q('type', '1'),
        _q('json', '1'),
        _q('utf8', '1'),
        _q('onlysong', '0'),
        _q('new_format', '1'),
        _q('disstid', id),
        _q('format', 'json'),
        _q('inCharset', 'utf8'),
        _q('outCharset', 'utf-8'),
      ],
    );
    if (url == null) return null;

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _qqHeaders()));
    if (result == null) return null;
    final List<Object?>? cdlist = _safeArray(result, 'cdlist');
    if (cdlist == null) return null;
    if (cdlist.isEmpty) return null;
    final Map<String, Object?>? firstCD = _asDict(cdlist.first);
    if (firstCD == null) return null;

    final String name = _firstNonNil(<String?>[
          _safeString(firstCD, 'dissname'),
          _safeString(firstCD, 'dirName'),
          _safeString(firstCD, 'title'),
        ]) ??
        '';
    final String coverURL = _firstNonNil(<String?>[
          _safeString(firstCD, 'logo'),
          _safeString(firstCD, 'picUrl'),
          _safeString(firstCD, 'imgurl'),
        ]) ??
        '';
    final Map<String, Object?>? cdCreator = _safeDict(firstCD, 'creator');
    final String? creator = _firstNonNil(<String?>[
      _safeString(firstCD, 'nickname'),
      cdCreator == null ? null : _safeString(cdCreator, 'name'),
    ]);
    final String? description = _firstNonNil(<String?>[
      _safeString(firstCD, 'desc'),
      _safeString(firstCD, 'introduction'),
      _safeString(firstCD, 'comment'),
    ]);
    final int songCount = _safeInt(firstCD, 'total_song_num') ??
        _safeInt(firstCD, 'songnum') ??
        0;

    final List<PlaylistSong> songs = <PlaylistSong>[];
    final List<Object?>? songlist = _safeArray(firstCD, 'songlist');
    if (songlist != null) {
      for (final Object? song in songlist) {
        final Map<String, Object?>? dict = _asDict(song);
        if (dict == null) continue;
        final String? songMid = _safeString(dict, 'songmid');
        if (songMid == null) continue;
        final String songName =
            _safeString(dict, 'songname') ?? _safeString(dict, 'name') ?? '';
        final String artist =
            _safeStringFromDictArray(_safeArray(dict, 'singer'), 'name');
        final String? album =
            _safeString(dict, 'albumname') ?? _safeString(dict, 'albumName');
        final int? duration = _safeInt(dict, 'interval');
        final String albumMid = _safeString(dict, 'albummid') ?? '';
        final String? picUrl = _firstNonNil(<String?>[
              _safeString(dict, 'picAlbum'),
              _safeString(dict, 'picurl'),
              _safeString(dict, 'pic'),
            ]) ??
            (albumMid.isEmpty
                ? null
                : 'https://y.gtimg.cn/music/photo_new/'
                    'T002R300x300M000$albumMid.jpg');
        final String? rawInfo = _toJsonString(dict);

        songs.add(
          PlaylistSong(
            id: 'tx_$songMid',
            name: songName,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: picUrl,
            platform: 'tx',
            rawInfo: rawInfo,
          ),
        );
      }
    }

    return PlaylistDetail(
      id: 'tx_$id',
      name: name,
      coverURL: coverURL,
      creator: creator,
      description: description,
      songCount: songCount,
      songs: songs,
      platform: MusicPlatformType.qq,
    );
  }

  Future<List<RankingItem>> _qqRankings() async {
    final Uri? url = _buildURL(
      'https://c.y.qq.com/v8/fcg-bin/fcg_myqq_toplist.fcg',
      <MapEntry<String, String>>[
        _q('format', 'json'),
        _q('inCharset', 'utf-8'),
        _q('outCharset', 'utf-8'),
        _q('notice', '0'),
        _q('platform', 'h5'),
        _q('needNewCode', '1'),
      ],
    );
    if (url == null) return const <RankingItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _qqHeaders()));
    if (result == null) return const <RankingItem>[];

    final Map<String, Object?>? data = _safeDict(result, 'data');
    final List<Object?>? nested =
        data == null ? null : _safeArray(data, 'topList');
    final List<Object?> topList =
        nested ?? _safeArray(result, 'topList') ?? const <Object?>[];

    final List<RankingItem> items = <RankingItem>[];
    for (final Object? entry in topList) {
      final Map<String, Object?>? dict = _asDict(entry);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'id'),
            _safeString(dict, 'topId'),
            _safeInt(dict, 'id')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _firstNonNil(<String?>[
            _safeString(dict, 'topTitle'),
            _safeString(dict, 'title'),
            _safeString(dict, 'topName'),
          ]) ??
          '';
      final String? coverURL = _firstNonNil(<String?>[
        _safeString(dict, 'picUrl'),
        _safeString(dict, 'picurl'),
        _safeString(dict, 'frontPicUrl'),
        _safeString(dict, 'albumPic'),
      ]);
      final String? updateFreq = _firstNonNil(<String?>[
        _safeString(dict, 'updateTime'),
        _safeString(dict, 'updateFreq'),
        _safeString(dict, 'frequency'),
      ]);

      items.add(
        RankingItem(
          id: 'tx_$rawId',
          name: name,
          coverURL: coverURL,
          updateFreq: updateFreq,
          platform: MusicPlatformType.qq,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  Future<List<PlaylistItem>> _qqSearchPlaylists(
    String keyword,
    int page,
  ) async {
    final Uri? url = _buildURL(
      'http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist',
      <MapEntry<String, String>>[
        _q('page_no', page.toString()),
        _q('format', 'json'),
        _q('query', keyword),
        _q('remoteplace', 'txt.yqq.playlist'),
        _q('inCharset', 'utf8'),
        _q('outCharset', 'utf-8'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _qqHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];

    final Map<String, Object?>? listObj = _safeDict(data, 'list');
    final List<Object?>? nested =
        listObj == null ? null : _safeArray(listObj, 'list');
    final List<Object?> searchList =
        nested ?? _safeArray(data, 'list') ?? const <Object?>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in searchList) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'dissid'),
            _safeString(dict, 'disstid'),
            _safeString(dict, 'id'),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _firstNonNil(<String?>[
            _safeString(dict, 'dissname'),
            _safeString(dict, 'dcName'),
            _safeString(dict, 'title'),
          ]) ??
          '';
      final String coverURL = _firstNonNil(<String?>[
            _safeString(dict, 'imgurl'),
            _safeString(dict, 'picUrl'),
            _safeString(dict, 'picurl'),
            _safeString(dict, 'logo'),
          ]) ??
          '';
      final String? playCount = _formatPlayCount(
        _safeInt(dict, 'listennum') ??
            _safeInt(dict, 'listenNum') ??
            _safeInt(dict, 'playCount'),
      );
      final int? songCount =
          _safeInt(dict, 'songnum') ?? _safeInt(dict, 'songNum');
      final Map<String, Object?>? creatorDict = _safeDict(dict, 'creator');
      final String? creator =
          creatorDict == null ? null : _safeString(creatorDict, 'name');

      items.add(
        PlaylistItem(
          id: 'tx_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.qq,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  // MARK: - KuGou (酷狗)

  /// 酷狗请求头（对齐 iOS `kugouHeaders`：无额外头）。
  Map<String, String> _kugouHeaders() => <String, String>{};

  Future<List<PlaylistCategory>> _kugouCategories() async {
    // 动态自适应：从酷狗标签树接口实时拉取，不再写死分类。
    final List<PlaylistCategory> categories = <PlaylistCategory>[
      const PlaylistCategory(
        id: '',
        name: '推荐',
        platform: MusicPlatformType.kugou,
      ),
    ];

    final Uri? url = _buildURL(
      'http://mobilecdnbj.kugou.com/api/v3/tag/list',
      <MapEntry<String, String>>[
        _q('plat', '0'),
        _q('version', '9108'),
      ],
    );
    if (url == null) return categories;

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kugouHeaders()));
    if (result == null) return categories;
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return categories;
    final List<Object?>? info = _safeArray(data, 'info');
    if (info == null) return categories;

    // 一级分类：取每个标签分类的 id 与名称（对应歌单 tag 接口的 tagid）。
    final Set<String> seen = <String>{};
    for (final Object? group in info) {
      final Map<String, Object?>? dict = _asDict(group);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'special_tag_id'),
            _safeInt(dict, 'special_tag_id')?.toString(),
            _safeString(dict, 'id'),
            _safeInt(dict, 'id')?.toString(),
          ]) ??
          '';
      final String name = _firstNonNil(<String?>[_safeString(dict, 'name')]) ?? '';
      if (name.isEmpty || rawId.isEmpty) continue;
      if (seen.contains(rawId)) continue;
      seen.add(rawId);
      categories.add(
        PlaylistCategory(
          id: rawId,
          name: name,
          platform: MusicPlatformType.kugou,
        ),
      );
    }
    return categories;
  }

  Future<List<PlaylistItem>> _kugouPlaylists(
    String? category,
    int page,
  ) async {
    if (category != null && category.isNotEmpty) {
      return _kugouPlaylistsByTag(category, page);
    } else {
      return _kugouRecommendedPlaylists(page);
    }
  }

  Future<List<PlaylistItem>> _kugouRecommendedPlaylists(int page) async {
    final Uri? url = _buildURL(
      'http://mobilecdnbj.kugou.com/api/v5/special/recommend',
      <MapEntry<String, String>>[
        _q('version', '9108'),
        _q('plat', '0'),
        _q('showtype', '2'),
        _q('apiver', '6'),
        _q('area_code', '1'),
        _q('page', page.toString()),
        _q('pagesize', '30'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kugouHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];
    final List<Object?>? list = _safeArray(data, 'info');
    if (list == null) return const <PlaylistItem>[];

    return _parseKuGouPlaylistItems(list);
  }

  Future<List<PlaylistItem>> _kugouPlaylistsByTag(
    String tagId,
    int page,
  ) async {
    final Uri? url = _buildURL(
      'http://mobilecdnbj.kugou.com/api/v5/special/tag',
      <MapEntry<String, String>>[
        _q('version', '9108'),
        _q('plat', '0'),
        _q('showtype', '2'),
        _q('apiver', '6'),
        _q('area_code', '1'),
        _q('tagid', tagId),
        _q('page', page.toString()),
        _q('pagesize', '30'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kugouHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];
    final List<Object?>? list = _safeArray(data, 'info');
    if (list == null) return const <PlaylistItem>[];

    return _parseKuGouPlaylistItems(list);
  }

  /// 解析酷狗歌单数组（对齐 iOS `parseKuGouPlaylistItems`）。
  List<PlaylistItem> _parseKuGouPlaylistItems(List<Object?> list) {
    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in list) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'specialid'),
            _safeInt(dict, 'specialid')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _firstNonNil(<String?>[
            _safeString(dict, 'specialname'),
            _safeString(dict, 'name'),
          ]) ??
          '';
      String coverURL = _firstNonNil(<String?>[
            _safeString(dict, 'imgurl'),
            _safeString(dict, 'picurl'),
            _safeString(dict, 'logo'),
          ]) ??
          '';
      coverURL = _ensureHTTPSPrefix(coverURL) ?? coverURL;
      final String? playCount = _formatPlayCount(
        _safeInt(dict, 'playcount') ?? _safeInt(dict, 'listennum'),
      );
      final int? songCount =
          _safeInt(dict, 'songcount') ?? _safeInt(dict, 'songnum');
      final String? creator = _firstNonNil(<String?>[
        _safeString(dict, 'nickname'),
        _safeString(dict, 'username'),
        _safeString(dict, 'creator'),
      ]);

      items.add(
        PlaylistItem(
          id: 'kg_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.kugou,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  Future<PlaylistDetail?> _kugouPlaylistDetail(String id) async {
    final Future<_KuGouPlaylistInfo> infoFuture = _kugouPlaylistInfo(id);
    final Future<List<PlaylistSong>> songsFuture = _kugouPlaylistSongs(id);

    final _KuGouPlaylistInfo info = await infoFuture;
    final List<PlaylistSong> songs = await songsFuture;

    return PlaylistDetail(
      id: 'kg_$id',
      name: info.name,
      coverURL: info.coverURL,
      creator: info.creator,
      description: info.description,
      songCount: info.songCount,
      songs: songs,
      platform: MusicPlatformType.kugou,
    );
  }

  Future<_KuGouPlaylistInfo> _kugouPlaylistInfo(String id) async {
    final Uri? url = _buildURL(
      'https://mobiles.kugou.com/api/v5/special/info_v2',
      <MapEntry<String, String>>[
        _q('specialid', id),
        _q('with_common_getter', '1'),
        _q('appid', '1005'),
        _q('clientver', '0'),
        _q('format', '1'),
        _q('srcappid', '2919'),
      ],
    );
    if (url == null) return const _KuGouPlaylistInfo.empty();

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kugouHeaders()));
    if (result == null) return const _KuGouPlaylistInfo.empty();
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const _KuGouPlaylistInfo.empty();

    final String name = _safeString(data, 'specialname') ?? '';
    String coverURL = _safeString(data, 'imgurl') ?? '';
    coverURL = _ensureHTTPSPrefix(coverURL) ?? coverURL;
    final String? creator = _firstNonNil(<String?>[
      _safeString(data, 'nickname'),
      _safeString(data, 'username'),
    ]);
    final String? description = _firstNonNil(<String?>[
      _safeString(data, 'intro'),
      _safeString(data, 'description'),
    ]);
    final int songCount = _safeInt(data, 'songcount') ?? 0;

    return _KuGouPlaylistInfo(
      name: name,
      coverURL: coverURL,
      creator: creator,
      description: description,
      songCount: songCount,
    );
  }

  Future<List<PlaylistSong>> _kugouPlaylistSongs(String id) async {
    final List<PlaylistSong> allSongs = <PlaylistSong>[];
    int page = 1;

    while (page <= 50) {
      final Uri? url = _buildURL(
        'https://mobiles.kugou.com/api/v5/special/song_v2',
        <MapEntry<String, String>>[
          _q('specialid', id),
          _q('page', page.toString()),
          _q('pagesize', '30'),
          _q('appid', '1005'),
          _q('clientver', '0'),
          _q('format', '1'),
          _q('srcappid', '2919'),
        ],
      );
      if (url == null) break;

      final Map<String, Object?>? result =
          _asDict(await _httpGet(url.toString(), _kugouHeaders()));
      if (result == null) break;
      final Map<String, Object?>? data = _safeDict(result, 'data');
      if (data == null) break;
      final List<Object?>? list = _safeArray(data, 'info');
      if (list == null || list.isEmpty) break;

      for (final Object? song in list) {
        final Map<String, Object?>? dict = _asDict(song);
        if (dict == null) continue;
        final String? hash = _safeString(dict, 'hash');
        if (hash == null) continue;
        final String songName = _firstNonNil(<String?>[
              _safeString(dict, 'songname'),
              _safeString(dict, 'filename'),
              _safeString(dict, 'name'),
            ]) ??
            '';
        final String artist = _firstNonNil(<String?>[
              _safeString(dict, 'singername'),
              _safeString(dict, 'artist'),
            ]) ??
            '';
        final String? album = _firstNonNil(<String?>[
          _safeString(dict, 'album_name'),
          _safeString(dict, 'albumname'),
          _safeString(dict, 'album'),
        ]);
        final int? duration = _safeInt(dict, 'duration');
        String? coverURL = _firstNonNil(<String?>[
          _safeString(dict, 'album_img'),
          _safeString(dict, 'imgurl'),
        ]);
        coverURL = _ensureHTTPSPrefix(coverURL) ?? coverURL;
        final String? rawInfo = _toJsonString(dict);

        allSongs.add(
          PlaylistSong(
            id: 'kg_$hash',
            name: songName,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: coverURL,
            platform: 'kg',
            rawInfo: rawInfo,
          ),
        );
      }

      if (list.length < 30) break;
      page += 1;
    }
    return allSongs;
  }

  Future<List<RankingItem>> _kugouRankings() async {
    final Uri? url = _buildURL(
      'http://mobilecdnbj.kugou.com/api/v5/rank/list',
      <MapEntry<String, String>>[
        _q('version', '9108'),
        _q('plat', '0'),
        _q('showtype', '2'),
        _q('parentid', '0'),
        _q('apiver', '6'),
        _q('area_code', '1'),
        _q('withsong', '1'),
      ],
    );
    if (url == null) return const <RankingItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kugouHeaders()));
    if (result == null) return const <RankingItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <RankingItem>[];
    final List<Object?>? list = _safeArray(data, 'list');
    if (list == null) return const <RankingItem>[];

    final List<RankingItem> items = <RankingItem>[];
    for (final Object? entry in list) {
      final Map<String, Object?>? dict = _asDict(entry);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'rankid'),
            _safeInt(dict, 'rankid')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _safeString(dict, 'rankname') ?? '';
      final String? coverURL = _ensureHTTPSPrefix(_safeString(dict, 'imgurl'));
      final String? updateFreq = _safeString(dict, 'update_frequency');

      items.add(
        RankingItem(
          id: 'kg_$rawId',
          name: name,
          coverURL: coverURL,
          updateFreq: updateFreq,
          platform: MusicPlatformType.kugou,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  Future<PlaylistDetail?> _kugouRankingDetail(String id) async {
    final Future<List<RankingItem>> rankingsFuture = _kugouRankings();
    final Future<List<PlaylistSong>> songsFuture =
        _kugouRankingSongs(id, 1);

    final List<RankingItem> rankings = await rankingsFuture;
    final List<PlaylistSong> songs = await songsFuture;

    RankingItem? ranking;
    for (final RankingItem r in rankings) {
      if (r.rawId == id) {
        ranking = r;
        break;
      }
    }
    final String name = ranking?.name ?? '';
    final String coverURL = ranking?.coverURL ?? '';

    return PlaylistDetail(
      id: 'kg_$id',
      name: name,
      coverURL: coverURL,
      creator: null,
      description: null,
      songCount: songs.length,
      songs: songs,
      platform: MusicPlatformType.kugou,
    );
  }

  Future<List<PlaylistSong>> _kugouRankingSongs(
    String rankId,
    int page,
  ) async {
    final List<PlaylistSong> allSongs = <PlaylistSong>[];
    int currentPage = page;

    while (currentPage <= 10) {
      final Uri? url = _buildURL(
        'http://mobilecdnbj.kugou.com/api/v3/rank/song',
        <MapEntry<String, String>>[
          _q('version', '9108'),
          _q('ranktype', '1'),
          _q('plat', '0'),
          _q('pagesize', '30'),
          _q('area_code', '1'),
          _q('page', currentPage.toString()),
          _q('with_res_tag', '0'),
          _q('rankid', rankId),
          _q('show_portrait_mv', '1'),
        ],
      );
      if (url == null) break;

      final Map<String, Object?>? result =
          _asDict(await _httpGet(url.toString(), _kugouHeaders()));
      if (result == null) break;
      final Map<String, Object?>? data = _safeDict(result, 'data');
      if (data == null) break;
      final List<Object?>? list = _safeArray(data, 'info');
      if (list == null || list.isEmpty) break;

      for (final Object? song in list) {
        final Map<String, Object?>? dict = _asDict(song);
        if (dict == null) continue;
        final String? hash = _safeString(dict, 'hash');
        if (hash == null) continue;
        final String songName = _firstNonNil(<String?>[
              _safeString(dict, 'songname'),
              _safeString(dict, 'filename'),
            ]) ??
            '';
        final String artist = _firstNonNil(<String?>[
              _safeString(dict, 'singername'),
              _safeString(dict, 'artist'),
            ]) ??
            '';
        final String? album = _firstNonNil(<String?>[
          _safeString(dict, 'album_name'),
          _safeString(dict, 'albumname'),
        ]);
        final int? duration = _safeInt(dict, 'duration');
        String? coverURL = _firstNonNil(<String?>[
          _safeString(dict, 'album_img'),
          _safeString(dict, 'imgurl'),
        ]);
        coverURL = _ensureHTTPSPrefix(coverURL) ?? coverURL;
        final String? rawInfo = _toJsonString(dict);

        allSongs.add(
          PlaylistSong(
            id: 'kg_$hash',
            name: songName,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: coverURL,
            platform: 'kg',
            rawInfo: rawInfo,
          ),
        );
      }

      if (list.length < 30) break;
      currentPage += 1;
    }
    return allSongs;
  }

  Future<List<PlaylistItem>> _kugouSearchPlaylists(
    String keyword,
    int page,
  ) async {
    final Uri? url = _buildURL(
      'http://msearchretry.kugou.com/api/v3/search/special',
      <MapEntry<String, String>>[
        _q('keyword', keyword),
        _q('showtype', '10'),
        _q('filter', '0'),
        _q('version', '7910'),
        _q('sver', '2'),
        _q('page', page.toString()),
        _q('pagesize', '20'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kugouHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];
    final List<Object?>? list = _safeArray(data, 'lists');
    if (list == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in list) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'specialid'),
            _safeInt(dict, 'specialid')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _safeString(dict, 'specialname') ?? '';
      String coverURL = _safeString(dict, 'imgurl') ?? '';
      coverURL = _ensureHTTPSPrefix(coverURL) ?? coverURL;
      final String? playCount = _formatPlayCount(_safeInt(dict, 'playcount'));
      final int? songCount = _safeInt(dict, 'songcount');
      final String? creator = _firstNonNil(<String?>[
        _safeString(dict, 'username'),
        _safeString(dict, 'nickname'),
      ]);

      items.add(
        PlaylistItem(
          id: 'kg_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.kugou,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  // MARK: - KuWo (酷我)

  /// 酷我请求头（对齐 iOS `kuwoHeaders`）。
  Map<String, String> _kuwoHeaders() =>
      <String, String>{'Referer': 'http://www.kuwo.cn/'};

  Future<List<PlaylistCategory>> _kuwoCategories() async {
    final Uri? url = _buildURL(
      'http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList',
      <MapEntry<String, String>>[
        _q('cmd', 'rcm_keyword_playlist'),
        _q('user', '0'),
        _q('prod', 'kwplayer_pc_9.0.5.0'),
        _q('vipver', '9.0.5.0'),
        _q('source', 'kwplayer_pc_9.0.5.0'),
        _q('loginUid', '0'),
        _q('loginSid', '0'),
        _q('appUid', '76039576'),
      ],
    );
    if (url == null) return const <PlaylistCategory>[_kuwoDefaultCategory];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kuwoHeaders()));
    if (result == null) return const <PlaylistCategory>[_kuwoDefaultCategory];

    final List<PlaylistCategory> categories = <PlaylistCategory>[
      _kuwoDefaultCategory,
    ];

    final List<Object?>? data = _safeArray(result, 'data');
    if (data != null) {
      for (final Object? group in data) {
        final Map<String, Object?>? groupDict = _asDict(group);
        if (groupDict == null) continue;
        final List<Object?>? tags = _asList(groupDict['tags']);
        if (tags != null) {
          for (final Object? tag in tags) {
            final Map<String, Object?>? tagDict = _asDict(tag);
            if (tagDict == null) continue;
            final String id = _firstNonNil(<String?>[
                  _safeString(tagDict, 'id'),
                  _safeInt(tagDict, 'id')?.toString(),
                ]) ??
                '';
            final String name = _safeString(tagDict, 'name') ?? '';
            if (name.isNotEmpty) {
              categories.add(
                PlaylistCategory(
                  id: id,
                  name: name,
                  platform: MusicPlatformType.kuwo,
                ),
              );
            }
          }
        }
      }
    }
    return categories;
  }

  Future<List<PlaylistItem>> _kuwoPlaylists(
    String? category,
    int page,
  ) async {
    final String base;
    final List<MapEntry<String, String>> queryItems;

    if (category != null && category.isNotEmpty) {
      base = 'http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList';
      queryItems = <MapEntry<String, String>>[
        _q('loginUid', '0'),
        _q('loginSid', '0'),
        _q('appUid', '76039576'),
        _q('pn', page.toString()),
        _q('rn', '30'),
        _q('id', category),
      ];
    } else {
      base = 'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList';
      queryItems = <MapEntry<String, String>>[
        _q('loginUid', '0'),
        _q('loginSid', '0'),
        _q('appUid', '76039576'),
        _q('pn', page.toString()),
        _q('rn', '30'),
      ];
    }

    final Uri? url = _buildURL(base, queryItems);
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kuwoHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];
    final List<Object?>? list = _safeArray(data, 'list');
    if (list == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in list) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'id'),
            _safeInt(dict, 'id')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _safeString(dict, 'name') ?? '';
      final String coverURL = _safeString(dict, 'img') ?? '';
      final String? playCount = _formatPlayCount(_safeInt(dict, 'playCount'));
      final int? songCount =
          _safeInt(dict, 'total') ?? _safeInt(dict, 'songnum');
      final String? creator = _firstNonNil(<String?>[
        _safeString(dict, 'userName'),
        _safeString(dict, 'uname'),
        _safeString(dict, 'creator'),
      ]);

      items.add(
        PlaylistItem(
          id: 'kw_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.kuwo,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  Future<PlaylistDetail?> _kuwoPlaylistDetail(String id) async {
    final Uri? url = _buildURL(
      'http://nplserver.kuwo.cn/pl.svc',
      <MapEntry<String, String>>[
        _q('op', 'getlistinfo'),
        _q('pid', id),
        _q('encode', 'utf8'),
        _q('keyset', 'pl2012'),
        _q('identity', 'kuwo'),
        _q('pcmp4', '1'),
        _q('vipver', 'MUSIC_9.0.5.0_W1'),
        _q('newver', '1'),
        _q('pn', '1'),
        _q('rn', '100'),
      ],
    );
    if (url == null) return null;

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kuwoHeaders()));
    if (result == null) return null;

    final String name = _safeString(result, 'name') ?? '';
    final String coverURL = _safeString(result, 'pic') ?? '';
    final String? creator = _firstNonNil(<String?>[
      _safeString(result, 'uname'),
      _safeString(result, 'userName'),
      _safeString(result, 'creator'),
    ]);
    final String? description = _firstNonNil(<String?>[
      _safeString(result, 'info'),
      _safeString(result, 'description'),
    ]);
    final int songCount = _safeInt(result, 'total') ?? 0;

    final List<PlaylistSong> songs = <PlaylistSong>[];
    final List<Object?>? list = _safeArray(result, 'list');
    if (list != null) {
      for (final Object? song in list) {
        final Map<String, Object?>? dict = _asDict(song);
        if (dict == null) continue;
        final String songId = _firstNonNil(<String?>[
              _safeString(dict, 'rid'),
              _safeString(dict, 'id'),
              _safeInt(dict, 'rid')?.toString(),
              _safeInt(dict, 'id')?.toString(),
            ]) ??
            '';
        if (songId.isEmpty) continue;
        final String songName =
            _safeString(dict, 'name') ?? _safeString(dict, 'songName') ?? '';
        final String artist = _firstNonNil(<String?>[
              _safeString(dict, 'artist'),
              _safeString(dict, 'singer'),
            ]) ??
            '';
        final String? album = _firstNonNil(<String?>[
          _safeString(dict, 'album'),
          _safeString(dict, 'albumName'),
        ]);
        final int? duration = _safeInt(dict, 'duration');
        final String? coverURL = _safeString(dict, 'pic');
        final String? rawInfo = _toJsonString(dict);

        songs.add(
          PlaylistSong(
            id: 'kw_$songId',
            name: songName,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: coverURL,
            platform: 'kw',
            rawInfo: rawInfo,
          ),
        );
      }
    }

    return PlaylistDetail(
      id: 'kw_$id',
      name: name,
      coverURL: coverURL,
      creator: creator,
      description: description,
      songCount: songCount,
      songs: songs,
      platform: MusicPlatformType.kuwo,
    );
  }

  Future<List<RankingItem>> _kuwoRankings() async {
    const List<(String, String, String)> hardcoded =
        <(String, String, String)>[
      ('93', '酷我飙升榜', '每日更新'),
      ('16', '酷我热歌榜', '每日更新'),
      ('158', '酷我新歌榜', '每日更新'),
      ('17', '酷我华语榜', '每周更新'),
      ('18', '酷我欧美榜', '每周更新'),
      ('19', '酷我日韩榜', '每周更新'),
      ('26440106', '抖音热歌榜', '每日更新'),
      ('265', '网络红歌榜', '每日更新'),
      ('272', '国风榜', '每周更新'),
      ('273', '怀旧金曲榜', '每周更新'),
    ];

    return <RankingItem>[
      for (final (String rawId, String name, String freq) in hardcoded)
        RankingItem(
          id: 'kw_$rawId',
          name: name,
          coverURL: null,
          updateFreq: freq,
          platform: MusicPlatformType.kuwo,
          rawId: rawId,
        ),
    ];
  }

  Future<PlaylistDetail?> _kuwoRankingDetail(String id) async {
    final Uri? url = _buildURL(
      'http://kbangserver.kuwo.cn/ksong.s',
      <MapEntry<String, String>>[
        _q('from', 'pc'),
        _q('fmt', 'json'),
        _q('pn', '1'),
        _q('rn', '30'),
        _q('type', 'bang'),
        _q('data', 'content'),
        _q('id', id),
        _q('show_copyright_off', '0'),
        _q('pcmp4', '1'),
        _q('isbang', '1'),
      ],
    );
    if (url == null) return null;

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kuwoHeaders()));
    if (result == null) return null;

    final String name = _firstNonNil(<String?>[
          _safeString(result, 'name'),
          _safeString(result, 'bangName'),
          _safeString(result, 'title'),
        ]) ??
        '';
    final String coverURL = _firstNonNil(<String?>[
          _safeString(result, 'pic'),
          _safeString(result, 'img'),
          _safeString(result, 'cover'),
        ]) ??
        '';
    const String? creator = null;
    const String? description = null;
    final int songCount = _safeInt(result, 'total') ?? 0;

    final List<PlaylistSong> songs = <PlaylistSong>[];
    final List<Object?>? list = _safeArray(result, 'list') ??
        _safeArray(result, 'musiclist') ??
        _safeArray(result, 'songs');
    if (list != null) {
      for (final Object? song in list) {
        final Map<String, Object?>? dict = _asDict(song);
        if (dict == null) continue;
        final String songId = _firstNonNil(<String?>[
              _safeString(dict, 'rid'),
              _safeString(dict, 'id'),
              _safeInt(dict, 'rid')?.toString(),
              _safeInt(dict, 'id')?.toString(),
            ]) ??
            '';
        if (songId.isEmpty) continue;
        final String songName =
            _safeString(dict, 'name') ?? _safeString(dict, 'songName') ?? '';
        final String artist = _firstNonNil(<String?>[
              _safeString(dict, 'artist'),
              _safeString(dict, 'singer'),
            ]) ??
            '';
        final String? album = _firstNonNil(<String?>[
          _safeString(dict, 'album'),
          _safeString(dict, 'albumName'),
        ]);
        final int? duration = _safeInt(dict, 'duration');
        final String? coverURL = _safeString(dict, 'pic');
        final String? rawInfo = _toJsonString(dict);

        songs.add(
          PlaylistSong(
            id: 'kw_$songId',
            name: songName,
            artist: artist,
            album: album,
            duration: duration,
            coverURL: coverURL,
            platform: 'kw',
            rawInfo: rawInfo,
          ),
        );
      }
    }

    return PlaylistDetail(
      id: 'kw_$id',
      name: name,
      coverURL: coverURL,
      creator: creator,
      description: description,
      songCount: songCount,
      songs: songs,
      platform: MusicPlatformType.kuwo,
    );
  }

  Future<List<PlaylistItem>> _kuwoSearchPlaylists(
    String keyword,
    int page,
  ) async {
    final Uri? url = _buildURL(
      'http://search.kuwo.cn/r.s',
      <MapEntry<String, String>>[
        _q('all', keyword),
        _q('rformat', 'json'),
        _q('encoding', 'utf8'),
        _q('ver', 'mbox'),
        _q('vipver', 'MUSIC_8.7.7.0_BCS37'),
        _q('plat', 'pc'),
        _q('devid', '28156413'),
        _q('ft', 'playlist'),
        _q('pay', '0'),
        _q('needliveshow', '0'),
        _q('pn', page.toString()),
        _q('rn', '20'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _kuwoHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final List<Object?>? list = _safeArray(result, 'abslist');
    if (list == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in list) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'specialid'),
            _safeInt(dict, 'specialid')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _firstNonNil(<String?>[
            _safeString(dict, 'specialname'),
            _safeString(dict, 'name'),
          ]) ??
          '';
      final String coverURL = _safeString(dict, 'img') ?? '';
      final String? playCount = _formatPlayCount(_safeInt(dict, 'playcnt'));
      final int? songCount = _safeInt(dict, 'songnum');
      final String? creator = _firstNonNil(<String?>[
        _safeString(dict, 'username'),
        _safeString(dict, 'creator'),
      ]);

      items.add(
        PlaylistItem(
          id: 'kw_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.kuwo,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  // MARK: - Migu (咪咕)

  /// 咪咕请求头（对齐 iOS `miguHeaders`）。
  Map<String, String> _miguHeaders() =>
      <String, String>{'Referer': 'https://music.migu.cn/'};

  Future<List<PlaylistCategory>> _miguCategories() async {
    final Uri? url = _buildURL(
      'https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square/v1.0',
      <MapEntry<String, String>>[_q('templateVersion', '1')],
    );
    if (url == null) return const <PlaylistCategory>[_miguDefaultCategory];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _miguHeaders()));
    if (result == null) return const <PlaylistCategory>[_miguDefaultCategory];

    final List<PlaylistCategory> categories = <PlaylistCategory>[
      _miguDefaultCategory,
    ];

    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data != null) {
      final List<Object?>? tagList = _safeArray(data, 'tagList');
      if (tagList != null) {
        for (final Object? tag in tagList) {
          final Map<String, Object?>? tagDict = _asDict(tag);
          if (tagDict == null) continue;
          final String id = _firstNonNil(<String?>[
                _safeString(tagDict, 'tagId'),
                _safeInt(tagDict, 'tagId')?.toString(),
              ]) ??
              '';
          final String name = _firstNonNil(<String?>[
                _safeString(tagDict, 'tagName'),
                _safeString(tagDict, 'name'),
              ]) ??
              '';
          if (name.isNotEmpty) {
            categories.add(
              PlaylistCategory(
                id: id,
                name: name,
                platform: MusicPlatformType.migu,
              ),
            );
          }
        }
      }

      final List<Object?>? contentItemList = _safeArray(data, 'contentItemList');
      if (categories.length <= 1 && contentItemList != null) {
        for (final Object? item in contentItemList) {
          final Map<String, Object?>? itemDict = _asDict(item);
          if (itemDict == null) continue;
          final String itemType = _safeString(itemDict, 'itemType') ?? '';
          if (itemType.toLowerCase().contains('tag')) {
            final List<Object?>? contentList =
                _safeArray(itemDict, 'contentList');
            if (contentList != null) {
              for (final Object? content in contentList) {
                final Map<String, Object?>? contentDict = _asDict(content);
                if (contentDict == null) continue;
                final String id = _firstNonNil(<String?>[
                      _safeString(contentDict, 'tagId'),
                      _safeString(contentDict, 'id'),
                    ]) ??
                    '';
                final String name = _firstNonNil(<String?>[
                      _safeString(contentDict, 'tagName'),
                      _safeString(contentDict, 'name'),
                    ]) ??
                    '';
                if (name.isNotEmpty) {
                  categories.add(
                    PlaylistCategory(
                      id: id,
                      name: name,
                      platform: MusicPlatformType.migu,
                    ),
                  );
                }
              }
            }
          }
        }
      }
    }
    return categories;
  }

  Future<List<PlaylistItem>> _miguPlaylists(
    String? category,
    int page,
  ) async {
    if (category != null && category.isNotEmpty) {
      return _miguPlaylistsByTag(category, page);
    } else {
      return _miguPlaylistSquare(page);
    }
  }

  Future<List<PlaylistItem>> _miguPlaylistSquare(int page) async {
    final Uri? url = _buildURL(
      'https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square/v1.0',
      <MapEntry<String, String>>[
        _q('templateVersion', '1'),
        _q('pageNo', page.toString()),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _miguHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    final List<Object?>? contentItemList = _safeArray(data, 'contentItemList');
    if (contentItemList != null) {
      for (final Object? item in contentItemList) {
        final Map<String, Object?>? itemDict = _asDict(item);
        if (itemDict == null) continue;
        final String itemType = _safeString(itemDict, 'itemType') ?? '';
        if (itemType.toLowerCase().contains('playlist') || itemType.isEmpty) {
          final List<Object?>? contentList =
              _safeArray(itemDict, 'contentList');
          if (contentList != null) {
            for (final Object? content in contentList) {
              final Map<String, Object?>? contentDict = _asDict(content);
              if (contentDict == null) continue;
              final PlaylistItem? parsed = _parseMiguPlaylistItem(contentDict);
              if (parsed != null) items.add(parsed);
            }
          }
        }
      }
    }
    return items;
  }

  Future<List<PlaylistItem>> _miguPlaylistsByTag(
    String tagId,
    int page,
  ) async {
    final Uri? url = _buildURL(
      'https://app.c.nf.migu.cn/pc/v1.0/template/'
      'musiclistplaza-listbytag/release',
      <MapEntry<String, String>>[
        _q('tagId', tagId),
        _q('page', page.toString()),
        _q('count', '20'),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _miguHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];

    final List<PlaylistItem> items = <PlaylistItem>[];
    final List<Object?>? contentItemList = _safeArray(data, 'contentItemList');
    if (contentItemList != null) {
      for (final Object? item in contentItemList) {
        final Map<String, Object?>? itemDict = _asDict(item);
        if (itemDict == null) continue;
        final List<Object?>? contentList = _safeArray(itemDict, 'contentList');
        if (contentList != null) {
          for (final Object? content in contentList) {
            final Map<String, Object?>? contentDict = _asDict(content);
            if (contentDict == null) continue;
            final PlaylistItem? parsed = _parseMiguPlaylistItem(contentDict);
            if (parsed != null) items.add(parsed);
          }
        }
      }
    } else {
      final List<Object?>? list =
          _safeArray(data, 'list') ?? _safeArray(data, 'playlistList');
      if (list != null) {
        for (final Object? content in list) {
          final Map<String, Object?>? contentDict = _asDict(content);
          if (contentDict == null) continue;
          final PlaylistItem? parsed = _parseMiguPlaylistItem(contentDict);
          if (parsed != null) items.add(parsed);
        }
      }
    }
    return items;
  }

  /// 解析咪咕歌单条目（对齐 iOS `parseMiguPlaylistItem`）。
  PlaylistItem? _parseMiguPlaylistItem(Map<String, Object?> dict) {
    final String rawId = _firstNonNil(<String?>[
          _safeString(dict, 'contentId'),
          _safeString(dict, 'playlistId'),
          _safeString(dict, 'id'),
          _safeInt(dict, 'contentId')?.toString(),
          _safeInt(dict, 'playlistId')?.toString(),
        ]) ??
        '';
    if (rawId.isEmpty) return null;

    final String name = _firstNonNil(<String?>[
          _safeString(dict, 'contentName'),
          _safeString(dict, 'playlistName'),
          _safeString(dict, 'name'),
          _safeString(dict, 'title'),
        ]) ??
        '';
    final String coverURL = _firstNonNil(<String?>[
          _safeString(dict, 'imageUrl'),
          _safeString(dict, 'coverUrl'),
          _safeString(dict, 'picUrl'),
          _safeString(dict, 'img'),
        ]) ??
        '';
    final String? playCount = _formatPlayCount(
      _safeInt(dict, 'playCount') ??
          _safeInt(dict, 'listennum') ??
          _safeInt(dict, 'playNum'),
    );
    final int? songCount =
        _safeInt(dict, 'songCount') ?? _safeInt(dict, 'songnum');
    final String? creator = _firstNonNil(<String?>[
      _safeString(dict, 'createUserName'),
      _safeString(dict, 'creator'),
      _safeString(dict, 'nickname'),
    ]);

    return PlaylistItem(
      id: 'mg_$rawId',
      name: name,
      coverURL: coverURL,
      playCount: playCount,
      songCount: songCount,
      creator: creator,
      platform: MusicPlatformType.migu,
      rawId: rawId,
    );
  }

  Future<PlaylistDetail?> _miguPlaylistDetail(String id) async {
    final Future<_MiguPlaylistInfo> infoFuture = _miguPlaylistInfo(id);
    final Future<List<PlaylistSong>> songsFuture = _miguPlaylistSongs(id);

    final _MiguPlaylistInfo info = await infoFuture;
    final List<PlaylistSong> songs = await songsFuture;

    return PlaylistDetail(
      id: 'mg_$id',
      name: info.name,
      coverURL: info.coverURL,
      creator: info.creator,
      description: info.description,
      songCount: info.songCount > 0 ? info.songCount : songs.length,
      songs: songs,
      platform: MusicPlatformType.migu,
    );
  }

  Future<_MiguPlaylistInfo> _miguPlaylistInfo(String id) async {
    final Uri? url = _buildURL(
      'https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0',
      <MapEntry<String, String>>[_q('playlistId', id)],
    );
    if (url == null) return const _MiguPlaylistInfo.empty();

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _miguHeaders()));
    if (result == null) return const _MiguPlaylistInfo.empty();
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const _MiguPlaylistInfo.empty();

    Map<String, Object?> playlist = data;
    final Map<String, Object?>? nested = _safeDict(data, 'playlist');
    if (nested != null) playlist = nested;

    final String name = _firstNonNil(<String?>[
          _safeString(playlist, 'playlistName'),
          _safeString(playlist, 'contentName'),
          _safeString(playlist, 'name'),
        ]) ??
        '';
    final String coverURL = _firstNonNil(<String?>[
          _safeString(playlist, 'imageUrl'),
          _safeString(playlist, 'coverUrl'),
          _safeString(playlist, 'picUrl'),
          _safeString(playlist, 'img'),
        ]) ??
        '';
    final String? creator = _firstNonNil(<String?>[
      _safeString(playlist, 'createUserName'),
      _safeString(playlist, 'creator'),
      _safeString(playlist, 'nickname'),
    ]);
    final String? description = _firstNonNil(<String?>[
      _safeString(playlist, 'playlistDescribe'),
      _safeString(playlist, 'description'),
      _safeString(playlist, 'intro'),
    ]);
    final int songCount = _safeInt(playlist, 'contentCountTotal') ??
        _safeInt(playlist, 'songCount') ??
        _safeInt(playlist, 'songnum') ??
        0;

    return _MiguPlaylistInfo(
      name: name,
      coverURL: coverURL,
      creator: creator,
      description: description,
      songCount: songCount,
    );
  }

  Future<List<PlaylistSong>> _miguPlaylistSongs(String id) async {
    final Uri? url = _buildURL(
      'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0',
      <MapEntry<String, String>>[_q('playlistId', id)],
    );
    if (url == null) return const <PlaylistSong>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _miguHeaders()));
    if (result == null) return const <PlaylistSong>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistSong>[];

    final List<Object?> songArray = <Object?>[];
    final List<Object?>? songList = _safeArray(data, 'songList');
    final List<Object?>? list = _safeArray(data, 'list');
    if (songList != null) {
      songArray.addAll(songList);
    } else if (list != null) {
      songArray.addAll(list);
    } else {
      final List<Object?>? contentItemList = _safeArray(data, 'contentItemList');
      if (contentItemList != null) {
        for (final Object? item in contentItemList) {
          final Map<String, Object?>? itemDict = _asDict(item);
          if (itemDict == null) continue;
          final List<Object?>? contentList =
              _safeArray(itemDict, 'contentList');
          if (contentList != null) songArray.addAll(contentList);
        }
      }
    }

    final List<PlaylistSong> songs = <PlaylistSong>[];
    for (final Object? song in songArray) {
      final Map<String, Object?>? dict = _asDict(song);
      if (dict == null) continue;
      final String songId = _firstNonNil(<String?>[
            _safeString(dict, 'songId'),
            _safeString(dict, 'contentId'),
            _safeString(dict, 'id'),
            _safeInt(dict, 'songId')?.toString(),
            _safeInt(dict, 'contentId')?.toString(),
          ]) ??
          '';
      if (songId.isEmpty) continue;
      final String songName = _firstNonNil(<String?>[
            _safeString(dict, 'songName'),
            _safeString(dict, 'contentName'),
            _safeString(dict, 'name'),
          ]) ??
          '';
      final String artist = _firstNonNil(<String?>[
            _safeString(dict, 'singerName'),
            _safeString(dict, 'singer'),
            _safeString(dict, 'artist'),
          ]) ??
          '';
      final String? album = _firstNonNil(<String?>[
        _safeString(dict, 'albumName'),
        _safeString(dict, 'album'),
      ]);
      final int? duration = _normalizeDuration(
        _safeInt(dict, 'duration') ?? _safeInt(dict, 'length'),
      );
      final String? coverURL = _firstNonNil(<String?>[
        _safeString(dict, 'coverUrl'),
        _safeString(dict, 'imageUrl'),
        _safeString(dict, 'picUrl'),
      ]);
      final String? rawInfo = _toJsonString(dict);

      songs.add(
        PlaylistSong(
          id: 'mg_$songId',
          name: songName,
          artist: artist,
          album: album,
          duration: duration,
          coverURL: coverURL,
          platform: 'mg',
          rawInfo: rawInfo,
        ),
      );
    }
    return songs;
  }

  Future<List<RankingItem>> _miguRankings() async {
    const String url =
        'https://app.c.nf.migu.cn/pc/bmw/rank/rank-index/v1.0';
    final Map<String, Object?>? result =
        _asDict(await _httpGet(url, _miguHeaders()));
    if (result == null) return const <RankingItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <RankingItem>[];

    final List<RankingItem> items = <RankingItem>[];

    final List<Object?>? contentItemList = _safeArray(data, 'contentItemList');
    if (contentItemList != null) {
      for (final Object? item in contentItemList) {
        final Map<String, Object?>? itemDict = _asDict(item);
        if (itemDict == null) continue;
        final List<Object?>? contentList = _safeArray(itemDict, 'contentList');
        if (contentList != null) {
          for (final Object? content in contentList) {
            final Map<String, Object?>? contentDict = _asDict(content);
            if (contentDict == null) continue;
            final String rawId = _firstNonNil(<String?>[
                  _safeString(contentDict, 'contentId'),
                  _safeString(contentDict, 'rankId'),
                  _safeString(contentDict, 'id'),
                  _safeInt(contentDict, 'contentId')?.toString(),
                ]) ??
                '';
            if (rawId.isEmpty) continue;
            final String name = _firstNonNil(<String?>[
                  _safeString(contentDict, 'contentName'),
                  _safeString(contentDict, 'rankName'),
                  _safeString(contentDict, 'name'),
                ]) ??
                '';
            final String? coverURL = _firstNonNil(<String?>[
              _safeString(contentDict, 'imageUrl'),
              _safeString(contentDict, 'coverUrl'),
              _safeString(contentDict, 'picUrl'),
            ]);
            final String? updateFreq = _firstNonNil(<String?>[
              _safeString(contentDict, 'updateFreq'),
              _safeString(contentDict, 'updateFrequency'),
            ]);

            items.add(
              RankingItem(
                id: 'mg_$rawId',
                name: name,
                coverURL: coverURL,
                updateFreq: updateFreq,
                platform: MusicPlatformType.migu,
                rawId: rawId,
              ),
            );
          }
        }
      }
    }

    if (items.isEmpty) {
      final List<Object?>? rankList = _safeArray(data, 'rankList');
      if (rankList != null) {
        for (final Object? entry in rankList) {
          final Map<String, Object?>? dict = _asDict(entry);
          if (dict == null) continue;
          final String rawId = _firstNonNil(<String?>[
                _safeString(dict, 'rankId'),
                _safeString(dict, 'contentId'),
                _safeString(dict, 'id'),
                _safeInt(dict, 'rankId')?.toString(),
              ]) ??
              '';
          if (rawId.isEmpty) continue;
          final String name = _firstNonNil(<String?>[
                _safeString(dict, 'rankName'),
                _safeString(dict, 'contentName'),
                _safeString(dict, 'name'),
              ]) ??
              '';
          final String? coverURL = _firstNonNil(<String?>[
            _safeString(dict, 'imageUrl'),
            _safeString(dict, 'coverUrl'),
            _safeString(dict, 'picUrl'),
          ]);
          final String? updateFreq = _firstNonNil(<String?>[
            _safeString(dict, 'updateFreq'),
            _safeString(dict, 'updateFrequency'),
          ]);

          items.add(
            RankingItem(
              id: 'mg_$rawId',
              name: name,
              coverURL: coverURL,
              updateFreq: updateFreq,
              platform: MusicPlatformType.migu,
              rawId: rawId,
            ),
          );
        }
      }
    }

    return items;
  }

  Future<List<PlaylistItem>> _miguSearchPlaylists(
    String keyword,
    int page,
  ) async {
    const String searchSwitch =
        '{"song":0,"album":0,"singer":0,"tagSong":0,"mvSong":0,'
        '"bestShow":0,"songlist":1,"lyricSong":0}';
    final Uri? url = _buildURL(
      'https://jadeite.migu.cn/music_search/v3/search/searchAll',
      <MapEntry<String, String>>[
        _q('isCorrect', '0'),
        _q('isCopyright', '1'),
        _q('pageSize', '20'),
        _q('searchSwitch', searchSwitch),
        _q('text', keyword),
        _q('pageNo', page.toString()),
      ],
    );
    if (url == null) return const <PlaylistItem>[];

    final Map<String, Object?>? result =
        _asDict(await _httpGet(url.toString(), _miguHeaders()));
    if (result == null) return const <PlaylistItem>[];
    final Map<String, Object?>? data = _safeDict(result, 'data');
    if (data == null) return const <PlaylistItem>[];

    final List<Object?> searchList = <Object?>[];
    final Map<String, Object?>? playListResult =
        _safeDict(data, 'playListResult');
    final List<Object?>? nested = playListResult == null
        ? null
        : _safeArray(playListResult, 'playListList');
    if (nested != null) {
      searchList.addAll(nested);
    } else {
      final List<Object?>? byPlayList = _safeArray(data, 'playListList');
      if (byPlayList != null) {
        searchList.addAll(byPlayList);
      } else {
        final List<Object?>? byList = _safeArray(data, 'list');
        if (byList != null) searchList.addAll(byList);
      }
    }

    final List<PlaylistItem> items = <PlaylistItem>[];
    for (final Object? playlist in searchList) {
      final Map<String, Object?>? dict = _asDict(playlist);
      if (dict == null) continue;
      final String rawId = _firstNonNil(<String?>[
            _safeString(dict, 'playlistId'),
            _safeString(dict, 'contentId'),
            _safeString(dict, 'id'),
            _safeInt(dict, 'playlistId')?.toString(),
          ]) ??
          '';
      if (rawId.isEmpty) continue;
      final String name = _firstNonNil(<String?>[
            _safeString(dict, 'playlistName'),
            _safeString(dict, 'contentName'),
            _safeString(dict, 'name'),
          ]) ??
          '';
      final String coverURL = _firstNonNil(<String?>[
            _safeString(dict, 'imageUrl'),
            _safeString(dict, 'coverUrl'),
            _safeString(dict, 'picUrl'),
          ]) ??
          '';
      final String? playCount = _formatPlayCount(
        _safeInt(dict, 'playCount') ??
            _safeInt(dict, 'playNum') ??
            _safeInt(dict, 'listennum'),
      );
      final int? songCount =
          _safeInt(dict, 'songCount') ?? _safeInt(dict, 'songnum');
      final String? creator = _firstNonNil(<String?>[
        _safeString(dict, 'createUserName'),
        _safeString(dict, 'creator'),
      ]);

      items.add(
        PlaylistItem(
          id: 'mg_$rawId',
          name: name,
          coverURL: coverURL,
          playCount: playCount,
          songCount: songCount,
          creator: creator,
          platform: MusicPlatformType.migu,
          rawId: rawId,
        ),
      );
    }
    return items;
  }

  /// 酷我默认分类（对齐 iOS `kuwoCategories` 的「推荐」兜底）。
  static const PlaylistCategory _kuwoDefaultCategory = PlaylistCategory(
    id: '',
    name: '推荐',
    platform: MusicPlatformType.kuwo,
  );

  /// 咪咕默认分类（对齐 iOS `miguCategories` 的「推荐」兜底）。
  static const PlaylistCategory _miguDefaultCategory = PlaylistCategory(
    id: '',
    name: '推荐',
    platform: MusicPlatformType.migu,
  );
}

/// 酷狗歌单基本信息（对齐 iOS `KuGouPlaylistInfo`）。
class _KuGouPlaylistInfo {
  /// 构造。
  const _KuGouPlaylistInfo({
    required this.name,
    required this.coverURL,
    required this.creator,
    required this.description,
    required this.songCount,
  });

  /// 兜底空值。
  const _KuGouPlaylistInfo.empty()
      : name = '',
        coverURL = '',
        creator = null,
        description = null,
        songCount = 0;

  /// 歌单名。
  final String name;

  /// 封面。
  final String coverURL;

  /// 创建者。
  final String? creator;

  /// 简介。
  final String? description;

  /// 歌曲数。
  final int songCount;
}

/// 咪咕歌单基本信息（对齐 iOS `MiguPlaylistInfo`）。
class _MiguPlaylistInfo {
  /// 构造。
  const _MiguPlaylistInfo({
    required this.name,
    required this.coverURL,
    required this.creator,
    required this.description,
    required this.songCount,
  });

  /// 兜底空值。
  const _MiguPlaylistInfo.empty()
      : name = '',
        coverURL = '',
        creator = null,
        description = null,
        songCount = 0;

  /// 歌单名。
  final String name;

  /// 封面。
  final String coverURL;

  /// 创建者。
  final String? creator;

  /// 简介。
  final String? description;

  /// 歌曲数。
  final int songCount;
}