/// 领域层：Spider 返回结构模型。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §3「返回结构」
/// 逆向来源：iOS `vbox/Models/SpiderModels.swift`
///
/// ⚠️ 关键容错规则（必须复刻，否则 Node/WEX 源会解析失败）：
/// - `vod_id` / `vod_name` / `vod_pic` 支持 **String / Int / Double**
/// - `type_id` / `type_name` 支持 **String / Int / Double**
/// - 其余字段缺失时用 `null`
/// - `availQualities` 缺省为 `[]`
/// - `PlayerContentResult.urls` = `urls ?? (url 非空 ? [url] : null)`
/// - `PlayerContentResult.url` 兼容 **String / 数组**（多线路蜘蛛）：
///   数组形态下 `urls`=全列表、`url`=首元素（对齐 iOS `init(from:)`）
library;

/// 宽松转字符串：支持 String / Int / Double / bool。
String? asLooseString(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num) {
    // 整数值不输出 .0
    if (v is double && v == v.truncateToDouble()) {
      return v.toInt().toString();
    }
    return v.toString();
  }
  return v.toString();
}

/// 宽松转必需字符串（缺失 → 空串，对齐 iOS 非可选字段语义）。
String asLooseStringRequired(Object? v) => asLooseString(v) ?? '';

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

/// 视频分类（对齐 iOS `VodCategory`）。
///
/// 二级分类扩展（Flutter 侧增量，不影响 iOS 参考实现与普通资源源）：
///   - 新增可选 [subCategories]，缺省 `null`；普通资源源（TY/360/Node/CMS 等）
///     不返回 `sub_categories` 键，解析后恒为 `null`，行为与改动前完全一致。
///   - JSON 键名 `sub_categories`（下划线风格，与 `type_id`/`type_name` 统一）。
///   - `==` / `hashCode` 仍只比较 `typeId` + `typeName`，不纳入子分类，
///     避免影响现有去重 / 判等逻辑。
class VodCategory {
  const VodCategory({
    required this.typeId,
    required this.typeName,
    this.subCategories,
  });

  /// JSON key: `type_id`。
  final String typeId;

  /// JSON key: `type_name`。
  final String typeName;

  /// 二级分类（可选）。仅支持二级分类的福利 Spider 返回；
  /// 普通资源源不返回该键，恒为 `null`。
  final List<VodCategory>? subCategories;

  factory VodCategory.fromJson(Map<String, Object?> j) => VodCategory(
        typeId: asLooseStringRequired(j['type_id']),
        typeName: asLooseStringRequired(j['type_name']),
        subCategories: (j['sub_categories'] as List?)
            ?.whereType<Map>()
            .map((e) => VodCategory.fromJson(e.cast<String, Object?>()))
            .toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'type_id': typeId,
        'type_name': typeName,
        if (subCategories != null)
          'sub_categories': subCategories!.map((e) => e.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is VodCategory && other.typeId == typeId && other.typeName == typeName;

  @override
  int get hashCode => Object.hash(typeId, typeName);
}

/// 视频条目（对齐 iOS `VodItem`，含扩展字段）。
class VodItem {
  const VodItem({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    this.vodRemarks,
    this.vodYear,
    this.vodArea,
    this.vodDirector,
    this.vodActor,
    this.vodContent,
    this.vodPlayFrom,
    this.vodPlayUrl,
    this.customHeaders,
    this.engineKey,
    this.metaDuration,
    this.albumName,
    this.availQualities = const <String>[],
    this.musicPlatform,
    this.lxMusicInfo,
    this.musicEntryType,
  });

  final String vodId;
  final String vodName;
  final String vodPic;
  final String? vodRemarks;
  final String? vodYear;
  final String? vodArea;
  final String? vodDirector;
  final String? vodActor;
  final String? vodContent;
  final String? vodPlayFrom;
  final String? vodPlayUrl;
  final Map<String, String>? customHeaders;
  final String? engineKey;
  final int? metaDuration;
  final String? albumName;

  /// 可用音质（列表），缺省 `[]`。
  final List<String> availQualities;
  final String? musicPlatform;
  final String? lxMusicInfo;
  final String? musicEntryType;

  factory VodItem.fromJson(Map<String, Object?> j) => VodItem(
        vodId: asLooseStringRequired(j['vod_id']),
        vodName: asLooseStringRequired(j['vod_name']),
        vodPic: asLooseStringRequired(j['vod_pic']),
        vodRemarks: asLooseString(j['vod_remarks']),
        vodYear: asLooseString(j['vod_year']),
        vodArea: asLooseString(j['vod_area']),
        vodDirector: asLooseString(j['vod_director']),
        vodActor: asLooseString(j['vod_actor']),
        vodContent: asLooseString(j['vod_content']),
        vodPlayFrom: asLooseString(j['vod_play_from']),
        vodPlayUrl: asLooseString(j['vod_play_url']),
        customHeaders: (j['customHeaders'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString())),
        engineKey: asLooseString(j['engineKey']),
        metaDuration: _asInt(j['metaDuration']),
        albumName: asLooseString(j['albumName']),
        availQualities: (j['availQualities'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
        musicPlatform: asLooseString(j['musicPlatform']),
        lxMusicInfo: asLooseString(j['lxMusicInfo']),
        musicEntryType: asLooseString(j['musicEntryType']),
      );

  /// 复制并设置 [engineKey]（占源/附加源搜索结果回填来源站点 key）。
  VodItem withEngineKey(String key) => VodItem(
        vodId: vodId,
        vodName: vodName,
        vodPic: vodPic,
        vodRemarks: vodRemarks,
        vodYear: vodYear,
        vodArea: vodArea,
        vodDirector: vodDirector,
        vodActor: vodActor,
        vodContent: vodContent,
        vodPlayFrom: vodPlayFrom,
        vodPlayUrl: vodPlayUrl,
        customHeaders: customHeaders,
        engineKey: key,
        metaDuration: metaDuration,
        albumName: albumName,
        availQualities: availQualities,
        musicPlatform: musicPlatform,
        lxMusicInfo: lxMusicInfo,
        musicEntryType: musicEntryType,
      );

  /// 复制并把 [vodRemarks] 覆盖为来源显示名（搜索按源分组用；对齐 iOS
  /// `SpiderManager.searchStream` 把 `vodRemarks` 覆盖为源名，网盘源带 `☁️` 前缀）。
  VodItem withSourceLabel(String label) => VodItem(
        vodId: vodId,
        vodName: vodName,
        vodPic: vodPic,
        vodRemarks: label,
        vodYear: vodYear,
        vodArea: vodArea,
        vodDirector: vodDirector,
        vodActor: vodActor,
        vodContent: vodContent,
        vodPlayFrom: vodPlayFrom,
        vodPlayUrl: vodPlayUrl,
        customHeaders: customHeaders,
        engineKey: engineKey,
        metaDuration: metaDuration,
        albumName: albumName,
        availQualities: availQualities,
        musicPlatform: musicPlatform,
        lxMusicInfo: lxMusicInfo,
        musicEntryType: musicEntryType,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'vod_id': vodId,
        'vod_name': vodName,
        'vod_pic': vodPic,
        if (vodRemarks != null) 'vod_remarks': vodRemarks,
        if (vodYear != null) 'vod_year': vodYear,
        if (vodArea != null) 'vod_area': vodArea,
        if (vodDirector != null) 'vod_director': vodDirector,
        if (vodActor != null) 'vod_actor': vodActor,
        if (vodContent != null) 'vod_content': vodContent,
        if (vodPlayFrom != null) 'vod_play_from': vodPlayFrom,
        if (vodPlayUrl != null) 'vod_play_url': vodPlayUrl,
        if (customHeaders != null) 'customHeaders': customHeaders,
        if (engineKey != null) 'engineKey': engineKey,
        if (metaDuration != null) 'metaDuration': metaDuration,
        if (albumName != null) 'albumName': albumName,
        'availQualities': availQualities,
        if (musicPlatform != null) 'musicPlatform': musicPlatform,
        if (lxMusicInfo != null) 'lxMusicInfo': lxMusicInfo,
        if (musicEntryType != null) 'musicEntryType': musicEntryType,
      };
}

/// 首页结果（对齐 iOS `HomeContentResult`）。
class HomeContentResult {
  const HomeContentResult({this.classes, this.list});

  /// JSON key: `class`。
  final List<VodCategory>? classes;
  final List<VodItem>? list;

  factory HomeContentResult.fromJson(Map<String, Object?> j) => HomeContentResult(
        classes: (j['class'] as List?)
            ?.whereType<Map>()
            .map((e) => VodCategory.fromJson(e.cast<String, Object?>()))
            .toList(),
        list: (j['list'] as List?)
            ?.whereType<Map>()
            .map((e) => VodItem.fromJson(e.cast<String, Object?>()))
            .toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (classes != null) 'class': classes!.map((e) => e.toJson()).toList(),
        if (list != null) 'list': list!.map((e) => e.toJson()).toList(),
      };
}

/// 分类结果（对齐 iOS `CategoryContentResult`）。
class CategoryContentResult {
  const CategoryContentResult({
    this.page,
    this.pagecount,
    this.limit,
    this.total,
    this.list,
  });

  final int? page;
  final int? pagecount;
  final int? limit;
  final int? total;
  final List<VodItem>? list;

  factory CategoryContentResult.fromJson(Map<String, Object?> j) =>
      CategoryContentResult(
        page: _asInt(j['page']),
        pagecount: _asInt(j['pagecount']),
        limit: _asInt(j['limit']),
        total: _asInt(j['total']),
        list: (j['list'] as List?)
            ?.whereType<Map>()
            .map((e) => VodItem.fromJson(e.cast<String, Object?>()))
            .toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (page != null) 'page': page,
        if (pagecount != null) 'pagecount': pagecount,
        if (limit != null) 'limit': limit,
        if (total != null) 'total': total,
        if (list != null) 'list': list!.map((e) => e.toJson()).toList(),
      };
}

/// 搜索结果（对齐 iOS `SearchContentResult`）。
class SearchContentResult {
  const SearchContentResult({this.page, this.pagecount, this.list});

  final int? page;
  final int? pagecount;
  final List<VodItem>? list;

  factory SearchContentResult.fromJson(Map<String, Object?> j) =>
      SearchContentResult(
        page: _asInt(j['page']),
        pagecount: _asInt(j['pagecount']),
        list: (j['list'] as List?)
            ?.whereType<Map>()
            .map((e) => VodItem.fromJson(e.cast<String, Object?>()))
            .toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (page != null) 'page': page,
        if (pagecount != null) 'pagecount': pagecount,
        if (list != null) 'list': list!.map((e) => e.toJson()).toList(),
      };
}

/// 详情结果（对齐 iOS `DetailContentResult`）。
class DetailContentResult {
  const DetailContentResult({this.list});

  final List<VodItem>? list;

  factory DetailContentResult.fromJson(Map<String, Object?> j) =>
      DetailContentResult(
        list: (j['list'] as List?)
            ?.whereType<Map>()
            .map((e) => VodItem.fromJson(e.cast<String, Object?>()))
            .toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (list != null) 'list': list!.map((e) => e.toJson()).toList(),
      };
}

/// 播放结果（对齐 iOS `PlayerContentResult`）。
///
/// ⚠️ 回填规则：`urls = urls ?? (url 非空 ? [url] : null)`
class PlayerContentResult {
  PlayerContentResult({
    this.parse,
    this.playUrl,
    this.url,
    List<String>? urls,
    this.header,
  }) : urls = urls ??
            (url != null && url.isNotEmpty ? <String>[url] : null);

  /// 是否需二次解析（0/1）。
  final int? parse;

  /// 播放地址（旧字段）。
  final String? playUrl;

  /// 播放地址（主字段）。
  final String? url;

  /// 多音质/多线路（已按回填规则处理）。
  final List<String>? urls;

  /// 自定义请求头。
  final Map<String, String>? header;

  factory PlayerContentResult.fromJson(Map<String, Object?> j) {
    // 容错（对齐 iOS init(from:)）：`url` 兼容字符串与数组两种形态——
    // 蜘蛛 play 常返回多线路/多音质数组（酷狗/酷我/网易/QQ），单独按字符串
    // 解码会失败/产出垃圾串。数组形态：urls=全列表、url=首元素（iOS 语义：
    // 此形态下 `urls` 键不再参与）；字符串形态：`urls` 键优先，缺省回填。
    final Object? rawUrl = j['url'];
    final List<String>? urlAsArray =
        rawUrl is List ? rawUrl.map((Object? e) => e.toString()).toList() : null;
    final String? url = urlAsArray != null
        ? (urlAsArray.isNotEmpty ? urlAsArray.first : null)
        : asLooseString(rawUrl);
    return PlayerContentResult(
      parse: _asInt(j['parse']),
      playUrl: asLooseString(j['playUrl']),
      url: url,
      urls: urlAsArray ??
          (j['urls'] as List?)?.map((Object? e) => e.toString()).toList(),
      header: (j['header'] is Map)
          ? (j['header'] as Map).map(
              (Object? k, Object? v) => MapEntry(k.toString(), v.toString()),
            )
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (parse != null) 'parse': parse,
        if (playUrl != null) 'playUrl': playUrl,
        if (url != null) 'url': url,
        if (urls != null) 'urls': urls,
        if (header != null) 'header': header,
      };
}
