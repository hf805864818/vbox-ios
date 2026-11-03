/// 测试替身：内存仓储实现（供用例层单测注入）。
library;

import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/settings_store.dart';
import 'package:vbox/data/datasources/local/welfare_platform_cache.dart';
import 'package:vbox/data/datasources/remote/cms_v10_datasource.dart';
import 'package:vbox/data/datasources/remote/douban_datasource.dart';
import 'package:vbox/data/datasources/remote/welfare_platform_datasource.dart';
import 'package:vbox/data/models/download.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/entities/library/library.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/repositories/repositories.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/download/download.dart';
import 'package:vbox/platform/spider/spider_engine_factory.dart';

/// 内存设置键值存储（替代 SQLite `settings` 表，供 [SessionController] 单测注入）。
class InMemorySettingsStore implements SettingsStore {
  /// 构造（可注入初值）。
  InMemorySettingsStore([Map<String, String>? seed])
      : _data = <String, String>{...?seed};

  final Map<String, String> _data;

  /// 当前全部键值（只读快照，便于断言）。
  Map<String, String> get snapshot => Map<String, String>.unmodifiable(_data);

  @override
  Future<String?> get(String key) async => _data[key];

  @override
  Future<void> set(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

/// 内存收藏仓储。
class InMemoryFavoriteRepository implements FavoriteRepository {
  /// 构造（可注入初值）。
  InMemoryFavoriteRepository([List<FavoriteItem>? seed])
      : _items = <FavoriteItem>[...?seed];

  final List<FavoriteItem> _items;
  int _seq = 1000;

  /// 非空时所有操作返回该失败（模拟故障）。
  Failure? failWith;

  /// 当前条目数（测试断言用）。
  int get length => _items.length;

  @override
  Future<Result<List<FavoriteItem>>> list({int? limit, int? offset}) async {
    final Failure? f = failWith;
    if (f != null) return Err<List<FavoriteItem>>(f);
    final List<FavoriteItem> sorted = <FavoriteItem>[..._items]
      ..sort((FavoriteItem a, FavoriteItem b) =>
          b.addedAt.compareTo(a.addedAt));
    final int start = offset ?? 0;
    if (start >= sorted.length) {
      return const Success<List<FavoriteItem>>(<FavoriteItem>[]);
    }
    final List<FavoriteItem> sliced = sorted.sublist(start);
    if (limit == null || limit >= sliced.length) {
      return Success<List<FavoriteItem>>(sliced);
    }
    return Success<List<FavoriteItem>>(sliced.sublist(0, limit));
  }

  @override
  Future<Result<FavoriteItem?>> findByDetailUrl(String detailurl) async {
    final Failure? f = failWith;
    if (f != null) return Err<FavoriteItem?>(f);
    for (final FavoriteItem item in _items) {
      if (item.detailurl == detailurl) return Success<FavoriteItem?>(item);
    }
    return const Success<FavoriteItem?>(null);
  }

  @override
  Future<Result<FavoriteItem?>> findById(int id) async {
    final Failure? f = failWith;
    if (f != null) return Err<FavoriteItem?>(f);
    for (final FavoriteItem item in _items) {
      if (item.id == id) return Success<FavoriteItem?>(item);
    }
    return const Success<FavoriteItem?>(null);
  }

  @override
  Future<Result<int>> add(FavoriteItem item) async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    final int id = _seq++;
    _items.add(item.copyWith(id: id));
    return Success<int>(id);
  }

  @override
  Future<Result<bool>> remove(int id) async {
    final Failure? f = failWith;
    if (f != null) return Err<bool>(f);
    final int before = _items.length;
    _items.removeWhere((FavoriteItem item) => item.id == id);
    return Success<bool>(_items.length != before);
  }

  @override
  Future<Result<int>> clear() async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    final int n = _items.length;
    _items.clear();
    return Success<int>(n);
  }

  @override
  Future<Result<int>> count() async => Success<int>(_items.length);
}

/// 内存历史仓储。
class InMemoryHistoryRepository implements HistoryRepository {
  /// 构造。
  InMemoryHistoryRepository([List<HistoryItem>? seed])
      : _items = <HistoryItem>[...?seed];

  final List<HistoryItem> _items;
  int _seq = 2000;

  /// 模拟故障。
  Failure? failWith;

  /// 当前条目数。
  int get length => _items.length;

  /// 最近一次 upsert 的入参（断言进度钳制用）。
  HistoryItem? lastUpsert;

  @override
  Future<Result<List<HistoryItem>>> list({int? limit}) async {
    final Failure? f = failWith;
    if (f != null) return Err<List<HistoryItem>>(f);
    final List<HistoryItem> sorted = <HistoryItem>[..._items]
      ..sort((HistoryItem a, HistoryItem b) =>
          b.lastPlayedAt.compareTo(a.lastPlayedAt));
    if (limit == null || limit >= sorted.length) {
      return Success<List<HistoryItem>>(sorted);
    }
    return Success<List<HistoryItem>>(sorted.sublist(0, limit));
  }

  @override
  Future<Result<HistoryItem?>> findByDetailUrl(String detailurl) async {
    final Failure? f = failWith;
    if (f != null) return Err<HistoryItem?>(f);
    for (final HistoryItem item in _items) {
      if (item.detailurl == detailurl) return Success<HistoryItem?>(item);
    }
    return const Success<HistoryItem?>(null);
  }

  @override
  Future<Result<int>> upsert(HistoryItem item) async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    lastUpsert = item;
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].detailurl == item.detailurl) {
        final int id = _items[i].id ?? _seq++;
        _items[i] = item.copyWith(id: id);
        return Success<int>(id);
      }
    }
    final int id = _seq++;
    _items.add(item.copyWith(id: id));
    return Success<int>(id);
  }

  @override
  Future<Result<bool>> remove(int id) async {
    final Failure? f = failWith;
    if (f != null) return Err<bool>(f);
    final int before = _items.length;
    _items.removeWhere((HistoryItem item) => item.id == id);
    return Success<bool>(_items.length != before);
  }

  @override
  Future<Result<int>> clear() async {
    final int n = _items.length;
    _items.clear();
    return Success<int>(n);
  }

  @override
  Future<Result<int>> trim(int keep) async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    final List<HistoryItem> sorted = <HistoryItem>[..._items]
      ..sort((HistoryItem a, HistoryItem b) =>
          b.lastPlayedAt.compareTo(a.lastPlayedAt));
    final List<HistoryItem> drop = sorted.skip(keep).toList();
    _items.removeWhere((HistoryItem item) => drop.contains(item));
    return Success<int>(drop.length);
  }

  @override
  Future<Result<int>> count() async => Success<int>(_items.length);
}

/// 内存搜索历史仓储。
class InMemorySearchHistoryRepository implements SearchHistoryRepository {
  /// 构造（可注入初值，按时间倒序传入）。
  InMemorySearchHistoryRepository([List<String>? seed])
      : _words = <String>[...?seed];

  final List<String> _words;
  int _seq = 5000;

  /// 模拟故障。
  Failure? failWith;

  /// 当前条目数。
  int get length => _words.length;

  @override
  Future<Result<List<String>>> recent({int limit = 20}) async {
    final Failure? f = failWith;
    if (f != null) return Err<List<String>>(f);
    final List<String> seen = <String>[];
    final List<String> out = <String>[];
    // 遍历顺序即时间倒序（最新在前）
    for (final String w in _words.reversed) {
      final String kw = w.trim();
      if (kw.isEmpty || seen.contains(kw)) continue;
      seen.add(kw);
      out.add(kw);
    }
    final int n = out.length > limit ? limit : out.length;
    return Success<List<String>>(out.sublist(0, n));
  }

  @override
  Future<Result<int>> add(String keyword) async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    _seq++;
    _words.add(keyword.trim());
    return Success<int>(_seq);
  }

  @override
  Future<Result<int>> clear() async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    final int n = _words.length;
    _words.clear();
    return Success<int>(n);
  }
}

/// 内存订阅仓储。
class InMemorySubscriptionRepository implements SubscriptionRepository {
  /// 构造。
  InMemorySubscriptionRepository([List<SubscriptionItem>? seed])
      : _items = <SubscriptionItem>[...?seed];

  final List<SubscriptionItem> _items;
  int _seq = 3000;

  /// 模拟故障。
  Failure? failWith;

  @override
  Future<Result<List<SubscriptionItem>>> list() async {
    final Failure? f = failWith;
    if (f != null) return Err<List<SubscriptionItem>>(f);
    return Success<List<SubscriptionItem>>(<SubscriptionItem>[..._items]);
  }

  @override
  Future<Result<SubscriptionItem?>> findByUrl(String dyurl) async {
    final Failure? f = failWith;
    if (f != null) return Err<SubscriptionItem?>(f);
    for (final SubscriptionItem item in _items) {
      if (item.dyurl == dyurl) {
        return Success<SubscriptionItem?>(item);
      }
    }
    return const Success<SubscriptionItem?>(null);
  }

  @override
  Future<Result<SubscriptionItem?>> findById(int id) async {
    for (final SubscriptionItem item in _items) {
      if (item.id == id) return Success<SubscriptionItem?>(item);
    }
    return const Success<SubscriptionItem?>(null);
  }

  @override
  Future<Result<int>> add(SubscriptionItem item) async {
    final Failure? f = failWith;
    if (f != null) return Err<int>(f);
    final int id = _seq++;
    _items.add(item.copyWith(id: id));
    return Success<int>(id);
  }

  @override
  Future<Result<bool>> remove(int id) async {
    final Failure? f = failWith;
    if (f != null) return Err<bool>(f);
    final int before = _items.length;
    _items.removeWhere((SubscriptionItem item) => item.id == id);
    return Success<bool>(_items.length != before);
  }

  @override
  Future<Result<bool>> touchSync(int id, int atSeconds) async {
    final Failure? f = failWith;
    if (f != null) return Err<bool>(f);
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].id == id) {
        _items[i] = _items[i].copyWith(lastSyncAt: atSeconds);
        return const Success<bool>(true);
      }
    }
    return const Success<bool>(false);
  }
}

/// 内存远程源仓储。
class InMemoryRemoteSourceRepository implements RemoteSourceRepository {
  /// 缓存清单（可注入）。
  RemoteManifest? cached;

  /// 缓存写入时间（Unix 秒）。
  int cachedAt = 0;

  /// saveManifest 时写入的时间戳（测试注入）。
  int cachedAtHint = 0;

  /// fetch 返回的清单。
  RemoteManifest? fetchResult;

  /// fetch 返回的失败（非空则优先）。
  Failure? fetchFailure;

  /// fetch 调用次数（断言 TTL 命中不再拉取）。
  int fetchCount = 0;

  /// saveManifest 调用次数。
  int saveCount = 0;

  @override
  Future<Result<RemoteManifest>> fetchManifest({bool forceRefresh = false}) async {
    fetchCount++;
    final Failure? f = fetchFailure;
    if (f != null) return Err<RemoteManifest>(f);
    final RemoteManifest? m = fetchResult;
    if (m == null) {
      return const Err<RemoteManifest>(UnknownFailure('fake 未设置 fetchResult'));
    }
    return Success<RemoteManifest>(m);
  }

  @override
  Future<Result<RemoteManifest?>> cachedManifest() async =>
      Success<RemoteManifest?>(cached);

  @override
  Future<Result<bool>> saveManifest(RemoteManifest manifest) async {
    saveCount++;
    cached = manifest;
    // 写入时间由测试显式设置（fake 不掌握真实时钟）
    cachedAt = cachedAtHint;
    // 镜像真实现：同步成功落 configVersion / lastSyncTime 契约键
    settingsValue = settingsValue.copyWith(
      lastConfigVersion: manifest.configVersion,
      lastSyncTimeSeconds: cachedAtHint,
    );
    return const Success<bool>(true);
  }

  @override
  Future<Result<bool>> needsRefresh(int nowSeconds) async {
    final RemoteManifest? c = cached;
    if (c == null) return const Success<bool>(true);
    return Success<bool>(nowSeconds - cachedAt >= c.ttlSeconds);
  }

  @override
  Future<Result<int>> cachedAtSeconds() async => Success<int>(cachedAt);

  /// 远程源设置（可注入；默认契约默认值）。
  RemoteSourceSettings settingsValue = const RemoteSourceSettings.defaults();

  /// clearCache 调用次数。
  int clearCacheCount = 0;

  @override
  Future<Result<RemoteSourceSettings>> settings() async =>
      Success<RemoteSourceSettings>(settingsValue);

  @override
  Future<Result<bool>> setEnabled(bool enabled) async {
    settingsValue = settingsValue.copyWith(enabled: enabled);
    return const Success<bool>(true);
  }

  @override
  Future<Result<bool>> setManifestUrl(String url) async {
    settingsValue = settingsValue.copyWith(manifestUrl: url);
    return const Success<bool>(true);
  }

  @override
  Future<Result<bool>> clearCache() async {
    clearCacheCount++;
    cached = null;
    cachedAt = 0;
    settingsValue = settingsValue.copyWith(
      lastConfigVersion: '',
      lastSyncTimeSeconds: 0,
    );
    return const Success<bool>(true);
  }
}

/// 构造测试用清单。
RemoteManifest buildManifest({
  String configVersion = '2026.09.29.1',
  int ttlSeconds = 3600,
  bool withRequiredFiles = true,
  Map<String, Object?>? meta,
}) =>
    RemoteManifest.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'configVersion': configVersion,
      'ttlSeconds': ttlSeconds,
      'forceRefresh': false,
      'disabledKeys': <String>[],
      'files': withRequiredFiles
          ? <String, String>{
              'allSources': 'https://cdn.example.com/all_sources.json',
            }
          : <String, String>{
              'parsers': 'https://cdn.example.com/parsers.json',
            },
      if (meta != null) '_meta': meta,
    });

/// 构造站点聚合（`apiSources.sites`）。
AllSourcesContainer buildSources(List<Map<String, Object?>> sites) =>
    AllSourcesContainer(
      apiSources: <String, Object?>{'sites': sites},
    );

/// 单站点 JSON（缺省 key，可覆盖）。
Map<String, Object?> siteJson({
  required String key,
  required int type,
  String? api,
  String? name,
}) =>
    <String, Object?>{
      'key': key,
      'name': name ?? key,
      'type': type,
      if (api != null) 'api': api,
    };

/// 构造内容浏览用例（可注入站点 + CMS 数据源 + 引擎工厂）。
ContentBrowseUseCases buildContentBrowseUseCases({
  List<Map<String, Object?>> sites = const <Map<String, Object?>>[],
  CmsV10Datasource? cmsDatasource,
  SpiderEngineFactory engineFactory = const SpiderEngineFactory(),
}) =>
    ContentBrowseUseCases(
      loadAllSources: () async =>
          Success<AllSourcesContainer>(buildSources(sites)),
      cmsDatasource: cmsDatasource,
      engineFactory: engineFactory,
    );

/// 内存豆瓣数据源（A9 首页默认内容测试用；默认返回空集合 → 空态）。
class InMemoryDoubanDatasource extends DoubanDatasource {
  /// 构造。
  InMemoryDoubanDatasource({this.subjects = const <DoubanSubject>[]});

  /// 固定返回的合集条目。
  final List<DoubanSubject> subjects;

  @override
  Future<List<DoubanSubject>> fetchCollection(
    String collectionId, {
    int start = 0,
    int count = 20,
  }) async =>
      subjects;

  @override
  Future<List<DoubanSubject>> fetchCollectionWithTVCovers(
    String collectionId, {
    int start = 0,
    int count = 20,
  }) async =>
      subjects;

  @override
  Future<String?> fetchTVDetailCoverUrl(String id) async => null;

  @override
  Future<List<DoubanChartSubject>> fetchChartRanking(
    DoubanChartCategory category, {
    int start = 0,
    int count = 20,
  }) async =>
      const <DoubanChartSubject>[];
}

/// 构造豆瓣用例（内存数据源；默认空集合）。
DoubanUseCases buildDoubanUseCases({
  List<DoubanSubject> subjects = const <DoubanSubject>[],
}) =>
    DoubanUseCases(datasource: InMemoryDoubanDatasource(subjects: subjects));

/// 内存福利平台配置数据源（H-01 / H-06 单测用，不触碰真实网络）。
///
/// 默认返回 [UnknownFailure]（等价「远程不可达」→ 页面走错误/空态分支）；
/// 注入 [config] 后返回该配置（页面走有数据分支）。
class InMemoryWelfarePlatformDatasource extends WelfarePlatformDatasource {
  /// 构造。
  InMemoryWelfarePlatformDatasource({
    this.config,
    this.failure = const UnknownFailure('fake 未配置福利平台数据'),
  }) : super(client: HttpClient());

  /// 命中时返回的配置（null → 返回 [failure]）。
  final WelfarePlatformConfig? config;

  /// 未配置 [config] 时返回的失败。
  final Failure failure;

  /// fetch 调用次数（断言刷新行为用）。
  int fetchCount = 0;

  @override
  Future<Result<WelfarePlatformConfig>> fetch(
    String manifestUrl, {
    bool forceRefresh = false,
  }) async {
    fetchCount++;
    final WelfarePlatformConfig? c = config;
    return c == null
        ? Err<WelfarePlatformConfig>(failure)
        : Success<WelfarePlatformConfig>(c);
  }
}

/// 内存福利平台配置缓存（H-01 单测用；不落盘，读写均在内存）。
class InMemoryWelfarePlatformCache extends WelfarePlatformCache {
  /// 构造（可注入初值）。
  InMemoryWelfarePlatformCache({this.config});

  /// 当前缓存配置。
  WelfarePlatformConfig? config;

  @override
  Future<WelfarePlatformConfig?> read() async => config;

  @override
  Future<void> write(WelfarePlatformConfig value) async {
    config = value;
  }

  @override
  Future<void> clear() async {
    config = null;
  }
}

/// 构造福利平台配置（H-06 单测用；按 `video` / `live` / `comic` 三栏各给平台）。
WelfarePlatformConfig buildWelfarePlatformConfig({
  Map<String, List<String>> namesByCategory = const <String, List<String>>{
    'video': <String>['平台甲', '平台乙'],
    'live': <String>['直播甲'],
    'comic': <String>['漫画甲'],
  },
}) {
  int order = 0;
  final List<WelfarePlatform> platforms = <WelfarePlatform>[];
  namesByCategory.forEach((String category, List<String> names) {
    final WelfarePlatformCategory? c = WelfarePlatformCategory.fromKey(category);
    if (c == null) return;
    for (final String name in names) {
      platforms.add(WelfarePlatform(
        platformKey: '$category-${order + 1}',
        name: name,
        category: c,
        sortOrder: order++,
      ));
    }
  });
  return WelfarePlatformConfig(
    meta: const <String, Object?>{'version': '2026.10.03.1'},
    platforms: platforms,
  );
}

/// 内存下载存储（G-02 单测用；镜像 iOS `queryDownloads` 的 addedAt 倒序）。
///
/// 与 `download_manager_test.dart` 内的私有实现同构，供表现层测试注入
/// [DownloadManager]（避免触网 / 落盘）。
class InMemoryDownloadStore implements DownloadStore {
  /// 构造（可注入初值）。
  InMemoryDownloadStore([List<Download>? seed])
      : items = <Download>[...?seed];

  /// 当前记录（全量快照，供断言）。
  final List<Download> items;
  int _seq = 1;

  @override
  Future<int> add(Download d) async {
    final int id = _seq++;
    items.add(d.copyWith(id: id));
    return id;
  }

  @override
  Future<List<Download>> all() async {
    final List<Download> sorted = <Download>[...items]
      ..sort((Download a, Download b) => b.addedAt.compareTo(a.addedAt));
    return sorted;
  }

  @override
  Future<void> updateProgress(
    int id,
    double progress,
    int downloadedSize,
    String status,
  ) async {
    final int i = items.indexWhere((Download d) => d.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(
      progress: progress,
      downloadedSize: downloadedSize,
      status: DownloadStatus.fromDb(status),
    );
  }

  @override
  Future<void> updatePath(int id, String path, int fileSize, String status) async {
    final int i = items.indexWhere((Download d) => d.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(
      filePath: path,
      fileSize: fileSize,
      status: DownloadStatus.fromDb(status),
    );
  }

  @override
  Future<void> updateStatus(int id, String status) async {
    final int i = items.indexWhere((Download d) => d.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(status: DownloadStatus.fromDb(status));
  }

  @override
  Future<void> delete(int id) async {
    items.removeWhere((Download d) => d.id == id);
  }

  @override
  Future<void> clear() async {
    items.clear();
  }
}
