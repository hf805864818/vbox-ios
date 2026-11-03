/// 搜索页（批次 D · D-02）。
///
/// 空态：搜索历史（历史 capsulas + 清空）+ 榜单（当前源首页内容取前 N 条）。
/// 结果态：左源列表（横屏竖排 / 竖屏横滑）+ 结果卡（缩略图 + 标题 + 备注）。
/// 数据通路：`ContentBrowseUseCases.listSites` / `searchContent` / `homeContent`
/// + `SearchHistoryUseCases.recent` / `add` / `clear`，点击结果卡 push 详情页。
/// 搜索调试面板（Search-A6）：设置开启 `show_search_debug` 且日志非空时，
/// 搜索框下方显示逐源日志流（对齐 iOS `SearchView` 的 `searchDebugLogs`）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/async/semaphore.dart';
import '../../../core/errors/failures.dart';
import '../../../core/utils/result.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/douban/douban_models.dart';
import '../../../domain/entities/spider/spider.dart';
import '../../../domain/usecases/usecases.dart';
import '../../../platform/spider/spider.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/detail_page.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/skeleton_shimmer.dart';
import '../../widgets/vbox/vbox.dart';
import '../douban/douban_ranking_page.dart';

/// 搜索页。
class SearchPage extends StatefulWidget {
  /// 构造。
  const SearchPage({super.key, this.initialSiteKey, this.initialKeyword});

  /// 初始站点（缺省选中首个可用站点）。
  final String? initialSiteKey;

  /// 进入即搜索的关键词（对齐 iOS 首页/榜单/分类点击条目 `settings.triggerSearch(title)`）。
  final String? initialKeyword;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final ContentBrowseUseCases _uc;
  late final SearchHistoryUseCases _history;

  /// 豆瓣用例（空搜索页「豆瓣榜单」数据源）；未注入时为 null（测试环境无豆瓣）。
  DoubanUseCases? _douban;

  /// 附加结果源（S-设2 占源并列 / S-设3 腾讯原生 / Wave D 兜底切片源）；
  /// 缺省注入时为空（测试环境）。
  ZhanyuanSearchUseCases? _zhanyuan;
  TencentVideoNativeSpider? _tencent;
  SourceGovernanceUseCases? _governance;

  /// 网盘源搜索用例（S-设4；对齐 iOS `SpiderManager.searchStream` 的
  /// `cloudSearch` 通道）。缺省注入时为空（测试环境）。
  CloudSearchUseCases? _cloudSearch;

  /// 搜索调试面板开关（对齐 iOS `UserDefaults "show_search_debug"`）。
  bool _debugEnabled = false;

  /// 搜索调试日志（对齐 iOS `searchDebugLogs`：每次搜索清空、500 条上限）。
  final List<String> _debugLogs = <String>[];

  /// 日志上限（对齐 iOS `addSearchLog` 500 条裁剪）。
  static const int _maxDebugLogs = 500;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  List<SiteConfig>? _sites;
  String? _siteKey;
  List<String> _historyWords = const <String>[];

  /// 空搜索页「豆瓣榜单」栏目标签（标签名 → collectionId），对齐 iOS
  /// `MainViews.swift SearchView.doubanTabs`（L1357）。
  static const List<(String, String)> _doubanTabs = DoubanUseCases.searchTabs;

  /// 当前选中的豆瓣栏目标签下标。
  int _doubanTab = 0;

  /// 豆瓣榜单数据加载中（对齐 iOS `doubanLoading`）。
  bool _doubanLoading = false;

  /// 豆瓣榜单按栏目缓存（对齐 iOS `doubanSubjects[tabName]`，切回不重复请求）。
  final Map<String, List<DoubanSubject>> _doubanCache =
      <String, List<DoubanSubject>>{};

  bool _loading = false;
  Failure? _error;
  bool _searched = false;
  final List<VodItem> _results = <VodItem>[];

  /// 结果态左栏当前选中的来源分组（对齐 iOS `SearchResultsView.selectedSource`）。
  String? _selectedSource;

  @override
  void initState() {
    super.initState();
    _uc = context.read<ContentBrowseUseCases>();
    _history = context.read<SearchHistoryUseCases>();
    _douban = _maybeRead<DoubanUseCases>(context);
    _zhanyuan = _maybeRead<ZhanyuanSearchUseCases>(context);
    _tencent = _maybeRead<TencentVideoNativeSpider>(context);
    _governance = _maybeRead<SourceGovernanceUseCases>(context);
    _cloudSearch = _maybeRead<CloudSearchUseCases>(context);
    _init();
  }

  /// 读取可选 Provider（未注入返回 null，便于 widget 测试无附加源运行）。
  T? _maybeRead<T extends Object>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadHistory();
    unawaited(_loadDouban());
    unawaited(_loadDebugFlag());
    await _resolveSites();
    // 对齐 iOS `triggerSearch`：带初始关键词进入即自动搜索（首页/榜单/分类点击条目）。
    final String kw = (widget.initialKeyword ?? '').trim();
    if (kw.isEmpty) return;
    _controller.text = kw;
    _controller.selection = TextSelection.collapsed(offset: kw.length);
    await _submit(kw);
  }

  /// 解析站点清单（搜索期间可复用；失败不阻断，对齐 iOS 空态仍展示豆瓣榜单）。
  Future<List<SiteConfig>> _resolveSites() async {
    final List<SiteConfig>? cached = _sites;
    if (cached != null) return cached;
    final Result<List<SiteConfig>> result = await _uc.listSites();
    final List<SiteConfig> sites = result.valueOrNull ?? const <SiteConfig>[];
    if (mounted) {
      setState(() {
        _sites = sites;
        final String initial = widget.initialSiteKey ?? '';
        _siteKey = sites.isEmpty
            ? null
            : sites
                .firstWhere(
                  (SiteConfig s) => s.key == initial,
                  orElse: () => sites.first,
                )
                .key;
      });
    }
    return sites;
  }

  Future<void> _loadHistory() async {
    final Result<List<String>> result = await _history.recent();
    if (!mounted) return;
    final List<String> words = result.valueOrNull ?? const <String>[];
    setState(() => _historyWords = words);
  }

  /// 读取「搜索调试面板」开关（对齐 iOS 每次 body 渲染读
  /// `UserDefaults.standard.bool(forKey: "show_search_debug")`：进入页面与
  /// 每次发起搜索时刷新）。偏好未就绪时按缺省关闭（iOS 默认 false）。
  Future<void> _loadDebugFlag() async {
    try {
      final bool enabled =
          await PrefsManager.instance.getBool('show_search_debug');
      if (!mounted) return;
      setState(() => _debugEnabled = enabled);
    } catch (_) {
      // 偏好未初始化（如测试环境）：保持关闭，不阻断搜索页。
    }
  }

  /// 追加搜索调试日志（对齐 iOS `addSearchLog`：超出 500 条裁剪最早）。
  void _addSearchLog(String msg) {
    if (!mounted) return;
    setState(() {
      _debugLogs.add(msg);
      if (_debugLogs.length > _maxDebugLogs) {
        _debugLogs.removeRange(0, _debugLogs.length - _maxDebugLogs);
      }
    });
  }

  /// 加载当前栏目的豆瓣榜单（对齐 iOS `SearchView.loadDoubanData`，L1812-L1829）：
  /// 已缓存且非强制 → 直接复用；单栏目失败静默（保持空列表，不阻断页面）。
  Future<void> _loadDouban({bool force = false}) async {
    final DoubanUseCases? uc = _douban;
    if (uc == null) return;
    final (String, String) tab = _doubanTabs[_doubanTab];
    final String tabName = tab.$1;
    if (!force && (_doubanCache[tabName]?.isNotEmpty ?? false)) return;
    setState(() => _doubanLoading = true);
    final Result<List<DoubanSubject>> result =
        await uc.collection(tab.$2, count: 20);
    if (!mounted) return;
    setState(() {
      _doubanLoading = false;
      _doubanCache[tabName] = result.valueOrNull ?? const <DoubanSubject>[];
    });
  }

  Future<void> _selectDoubanTab(int index) async {
    if (index == _doubanTab) return;
    setState(() => _doubanTab = index);
    await _loadDouban();
  }

  /// 打开豆瓣排行榜页（对齐 iOS `SearchView` → `DoubanRankingView`）。
  void _openRanking() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DoubanRankingPage()),
    );
  }

  Future<void> _submit(String raw) async {
    final String keyword = raw.trim();
    if (keyword.isEmpty) return;
    await _history.add(keyword);
    await _loadHistory();
    await _search(keyword);
  }

  /// 执行搜索（对齐 iOS `SearchView.performSearch` → `SpiderManager.searchStream`）。
  ///
  /// 关键对齐点（修复「点搜索没反应」）：
  ///   · **不依赖已选站点**：iOS 走 `searchStream` 对**全部源**并发搜索并逐批回调，
  ///     不要求先选中某个源；此处改为对 `_sites` 全部站点并发 `searchContent`，
  ///     并叠加附加源（占源 / 腾讯原生 / 兜底切片）。
  ///   · **立刻进入搜索结果态**：`_searched = true` + `_loading = true`，
  ///     顶栏出现「取消」、正文出现加载指示，**不再静默 return**；
  ///     无任何源时也会落到「没有找到相关影片」空态，用户始终有反馈。
  ///   · **流式增量**：每个源返回即 `setState` 并入（对齐 iOS `searchStream onBatch`
  ///     逐批回调），谁先出数据先显示，不再等全部源结束。
  Future<void> _search(String keyword) async {
    final String kw = keyword.trim();
    if (kw.isEmpty) return;
    if (!mounted) return;
    unawaited(_loadDebugFlag());
    setState(() {
      _searched = true;
      _loading = true;
      _error = null;
      _results.clear();
      _selectedSource = null;
      _debugLogs.clear();
    });
    // 搜索调试日志（对齐 iOS performSearch L1729 / searchStream L2219）。
    _addSearchLog('🔍 开始搜索: $kw');

    final List<SiteConfig> sites = await _resolveSites();
    if (!mounted) return;
    _addSearchLog('====== 开始流式搜索: $kw (${sites.length} 源) ======');
    // 网盘源（group == 'cloud'）走 [CloudSearchUseCases] 独立通道（对齐 iOS
    // `searchStream` 的网盘通道与 apiSites 分立），不进入逐源 `searchContent`。
    // 引擎类源（Node / QuickJS·JSC / Python）经 [Semaphore] 有界限流（对齐 iOS
    // `searchStream` 通道 3/4 的 maxConcurrent=10），避免一次性打满子进程/FFI。
    final List<Future<void>> tasks = <Future<void>>[];
    for (final SiteConfig s in sites) {
      if (s.group == 'cloud') continue;
      tasks.add(
        s.resolveEngineType() != null
            ? _searchSiteThrottled(s, kw)
            : _searchSite(s, kw),
      );
    }
    _collectExtraSources(kw, tasks);
    await Future.wait(tasks);
    if (!mounted) return;
    // 收尾日志（对齐 iOS searchStream L2451 + performSearch L1745-L1747）。
    _addSearchLog('====== Stream全部完成 ======');
    _addSearchLog('✅ 搜索结束: 共${_results.length}条/$_distinctSourceCount个源');
    setState(() => _loading = false);
  }

  /// 结果的去重来源数（对齐 iOS `Set(searchResults.compactMap { $0.vodRemarks })`）。
  int get _distinctSourceCount => _results
      .map((VodItem v) => (v.vodRemarks ?? '').trim())
      .where((String s) => s.isNotEmpty)
      .toSet()
      .length;

  /// 引擎类源（Node / QuickJS·JSC / Python）搜索并发上限（对齐 iOS
  /// `searchStream` 通道 3/4 的 maxConcurrent=10）。
  final Semaphore _spiderSemaphore = Semaphore(10);

  /// 引擎类源限流版搜索：先取信号量再走 [_searchSite]（子进程/FFI 有界并发）。
  Future<void> _searchSiteThrottled(SiteConfig site, String keyword) async {
    await _spiderSemaphore.acquire();
    try {
      await _searchSite(site, keyword);
    } finally {
      _spiderSemaphore.release();
    }
  }

  /// 单站点搜索（返回即并入；单源失败静默，不阻断其余源，对齐 iOS 逐源容错）。
  ///
  /// 结果打上 `engineKey = site.key` 与 `vodRemarks = 源显示名`（网盘源带 `☁️`），
  /// 对齐 iOS `SpiderManager.searchStream`，使结果可按来源分组。
  Future<void> _searchSite(SiteConfig site, String keyword) async {
    try {
      final Result<SearchContentResult> result =
          await _uc.searchContent(site.key, keyword);
      final List<VodItem> items = result.valueOrNull?.list ?? const <VodItem>[];
      if (!mounted || items.isEmpty) return;
      _addSearchLog(_siteLogLine(site, count: items.length));
      final String label = _siteLabel(site);
      setState(() {
        _mergeResults(
          items
              .map((VodItem v) =>
                  v.withEngineKey(site.key).withSourceLabel(label))
              .toList(growable: false),
        );
      });
    } catch (e) {
      // 单源失败静默（对齐 iOS searchStream 的逐源 try/catch）；仅蜘蛛源记
      // ❌/🐍（对齐 iOS 引擎通道，API 通道错误静默）。
      if (site.type == 3) _addSearchLog(_siteLogLine(site, error: e));
    }
  }

  /// 逐源搜索日志行（对齐 iOS `searchStream` 通道 2/3/4：API 源
  /// `✅ name +N条`；JS 蜘蛛 `✅ QuickJS[key] +N条`；Python 蜘蛛
  /// `🐍 Python[key] +N条`；失败仅蜘蛛源记 `❌ QuickJS[key] err` / `🐍`）。
  String _siteLogLine(SiteConfig site, {int count = 0, Object? error}) {
    final bool ok = error == null;
    if (site.type == 3) {
      if (site.resolveEngineType() == SpiderEngineType.python) {
        return '🐍 Python[${site.key}] ${ok ? '+$count条' : error}';
      }
      return '${ok ? '✅' : '❌'} QuickJS[${site.key}] ${ok ? '+$count条' : error}';
    }
    return '✅ ${_siteLabel(site)} +$count条';
  }

  /// 站点显示名（网盘源加 `☁️` 前缀，对齐 iOS `SpiderManager.searchStream`）。
  String _siteLabel(SiteConfig site) {
    final String name = site.name.isEmpty ? site.key : site.name;
    return site.group == 'cloud' ? '☁️$name' : name;
  }

  /// 附加结果源（S-设2 占源并列 / S-设3 腾讯原生 / Wave D 兜底切片）并入任务表。
  void _collectExtraSources(String keyword, List<Future<void>> tasks) {
    final ZhanyuanSearchUseCases? zhanyuan = _zhanyuan;
    final TencentVideoNativeSpider? tencent = _tencent;
    final SourceGovernanceUseCases? governance = _governance;
    final CloudSearchUseCases? cloud = _cloudSearch;

    // S-设4：网盘源搜索（对齐 iOS `searchStream` 通道 0 `cloudSearch`）。
    // 网盘结果 `vodRemarks` 已由用例按站型打标（☁️ 来源名），命中即流式并入。
    if (cloud != null) {
      tasks.add(() async {
        try {
          await cloud.searchCloud(
            keyword,
            onBatch: (List<VodItem> items) {
              if (!mounted || items.isEmpty) return;
              // 网盘通道日志（对齐 iOS searchStream L2255）。
              _addSearchLog('☁️ 网盘 +${items.length}条');
              setState(() => _mergeResults(items));
            },
          );
        } catch (_) {
          // 单通道失败静默（对齐 iOS searchStream 的逐通道 try/catch）。
        }
      }());
    }

    if (zhanyuan != null) {
      tasks.add(
        zhanyuan
            .searchAll(
              keyword,
              onBatch: (List<VodItem> items) {
                if (!mounted || items.isEmpty) return;
                setState(() => _mergeResults(items));
              },
            )
            .catchError((Object _) {}),
      );
    }
    if (tencent != null) {
      tasks.add(
        tencent.search(keyword).then((List<VodItem> items) {
          if (!mounted || items.isEmpty) return;
          // 腾讯原生结果覆盖 `vodRemarks` 为来源显示名（对齐 iOS `searchStream`
          // 把备注置为源名），使结果可按来源分组而非按分集备注散开。
          final String name =
              TencentVideoNativeSpider.siteKey.replaceFirst('drpy_js_', '');
          // 引擎通道日志（对齐 iOS `✅ QuickJS[key] +N条`）。
          _addSearchLog(
            '✅ QuickJS[${TencentVideoNativeSpider.siteKey}] +${items.length}条',
          );
          setState(() {
            _mergeResults(
              items
                  .map((VodItem v) => v
                      .withEngineKey(TencentVideoNativeSpider.siteKey)
                      .withSourceLabel(name))
                  .toList(growable: false),
            );
          });
        }).catchError((Object _) {}),
      );
    }
    // Wave D · O-源1：兜底切片源（受 `fallback_enabled` 开关约束，内部自判）。
    if (governance != null) {
      tasks.add(
        governance
            .searchFallback(
              keyword,
              onBatch: (List<VodItem> items) {
                if (!mounted || items.isEmpty) return;
                setState(() => _mergeResults(items));
                // 兜底切片源逐源 ✅ 行（对齐 iOS：兜底源并入 API 通道
                // `✅ name +N条`，L2245-L2247）。
                final Map<String, int> bySource = <String, int>{};
                for (final VodItem v in items) {
                  final String label = (v.vodRemarks ?? '').trim();
                  if (label.isEmpty) continue;
                  bySource[label] = (bySource[label] ?? 0) + 1;
                }
                for (final MapEntry<String, int> e in bySource.entries) {
                  _addSearchLog('✅ ${e.key} +${e.value}条');
                }
              },
            )
            .catchError((Object _) {}),
      );
    }
  }

  /// 去重并入结果（按 `engineKey|vodId|vodName`）。
  void _mergeResults(List<VodItem> items) {
    final Set<String> seen = _results
        .map((VodItem v) => '${v.engineKey ?? ''}|${v.vodId}|${v.vodName}')
        .toSet();
    for (final VodItem v in items) {
      if (seen.add('${v.engineKey ?? ''}|${v.vodId}|${v.vodName}')) {
        _results.add(v);
      }
    }
  }

  Future<void> _onSourceChanged(String key) async {
    if (key == _siteKey) return;
    setState(() => _siteKey = key);
    if (_searched) {
      await _search(_controller.text);
    }
  }

  Future<void> _clearHistory() async {
    await _history.clear();
    await _loadHistory();
  }

  Future<void> _useHistoryWord(String word) async {
    _controller.text = word;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    await _submit(word);
  }

  void _backToEmpty() {
    setState(() {
      _searched = false;
      _results.clear();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 顶栏对齐 iOS `MainViews.swift SearchView`（L1360-L1414）：
      // 搜索框（放大镜 + 清除）→ 豆瓣排行榜入口（chart.bar.fill）→ 提交（arrow）。
      appBar: AppBar(
        titleSpacing: VboxSpacing.md,
        title: _buildSearchField(),
        // 对齐 iOS `SearchView`（L1362-L1414）：顶栏恒为「搜索框 + 豆瓣排行榜入口 +
        // 提交钮」，搜索结果态亦然（iOS 主搜索页无「取消」按钮，退出结果态靠清空输入 /
        // 返回上页）。
        actions: <Widget>[
          _buildRankingButton(),
          _buildSubmitButton(),
        ],
      ),
      // 搜索调试面板固定在搜索框下方（对齐 iOS L1425-L1480：
      // `show_search_debug` 开启且日志非空时显示）。
      body: Column(
        children: <Widget>[
          if (_debugEnabled && _debugLogs.isNotEmpty) _buildDebugPanel(),
          Expanded(child: _searched ? _buildResultState() : _buildEmptyState()),
        ],
      ),
    );
  }

  // ─────────────── 搜索调试面板（对齐 iOS SearchView L1425-L1480） ───────────────

  /// 搜索调试面板：计数头 + 120pt 等宽日志区（按前缀着色、新日志置底）+
  /// 右下角导出按钮。
  Widget _buildDebugPanel() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 计数头（对齐 iOS L1428-L1438）。
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Row(
            children: <Widget>[
              Text(
                '搜索调试',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${_results.length}条/$_distinctSourceCount源',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // 日志区（对齐 iOS L1440-L1463：9pt 等宽、前缀着色、滚动到底部）。
        SizedBox(
          height: 120,
          child: ListView.builder(
            // reverse 让最新日志恒定贴底（等价 iOS onChange scrollTo(last)）。
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            itemCount: _debugLogs.length,
            itemBuilder: (BuildContext context, int index) {
              final String log = _debugLogs[_debugLogs.length - 1 - index];
              return Text(
                log,
                style: TextStyle(
                  // iOS 9pt；R-3 字号档位无 9，取最近档 10。
                  fontSize: VboxTypography.s10,
                  fontFamily: 'monospace',
                  color: _debugLogColor(log, scheme),
                ),
              );
            },
          ),
        ),
        // 右下角导出（对齐 iOS L1466-L1479）。
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
          child: Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: _exportDebugLogs,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.ios_share,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 日志行着色（对齐 iOS L1446-L1450：✅ 绿 / ❌ 红 / 📦 黄 / ☁️ 青）；
  /// 缺省色取主题次要前景（iOS 白 0.7，主题化以保证浅色主题可读）。
  Color _debugLogColor(String log, ColorScheme scheme) {
    if (log.startsWith('✅')) return Colors.green.withValues(alpha: 0.9);
    if (log.startsWith('❌')) return Colors.red.withValues(alpha: 0.9);
    if (log.startsWith('📦')) return Colors.yellow.withValues(alpha: 0.9);
    if (log.startsWith('☁️')) return Colors.cyan.withValues(alpha: 0.9);
    return scheme.onSurfaceVariant;
  }

  /// 导出搜索调试日志（对齐 iOS `exportSearchLogs` L1759-L1781）：汇总搜索
  /// 信息 + 全部日志写入临时文件走系统分享面板；写文件失败退化为剪贴板。
  ///
  /// Windows 特例（与 player_page 同口径）：未打包桌面应用调用系统共享面板
  /// 必然失败，改为写入「下载」目录并在资源管理器中定位。
  Future<void> _exportDebugLogs() async {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String text = <String>[
      'vbox 搜索调试日志',
      '导出时间: ${now.year}-${two(now.month)}-${two(now.day)} '
          '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
      '搜索关键词: ${_controller.text.trim()}',
      '结果: ${_results.length} 条 / $_distinctSourceCount 源',
      '───── 日志（最近 ${_debugLogs.length} 条）─────',
      ..._debugLogs,
    ].join('\n');
    if (Platform.isWindows) {
      try {
        final Directory downloads =
            Directory('${Platform.environment['USERPROFILE']}\\Downloads');
        final String dir =
            downloads.existsSync() ? downloads.path : Directory.systemTemp.path;
        final File file = File('$dir\\vbox_search_debug_'
            '${now.year}${two(now.month)}${two(now.day)}_'
            '${two(now.hour)}${two(now.minute)}${two(now.second)}.txt');
        await file.writeAsString(text, flush: true);
        await Process.run('explorer.exe', <String>['/select,', file.path]);
        return;
      } catch (_) {
        await Clipboard.setData(ClipboardData(text: text));
        return;
      }
    }
    try {
      final File file = File(
        '${Directory.systemTemp.path}'
        '/vbox_search_debug_${now.millisecondsSinceEpoch ~/ 1000}.txt',
      );
      await file.writeAsString(text, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path)],
          text: 'vbox 搜索调试日志',
        ),
      );
    } catch (_) {
      // 写临时文件失败时退化为复制到剪贴板，保证日志可导出（对齐 iOS）。
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  /// 顶栏搜索框（放大镜 + 输入 + 清除；对齐 iOS `SearchView` 搜索栏）。
  Widget _buildSearchField() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          // 搜索中放大镜原地画小圈（对齐 iOS `SearchWiggleModifier`：
          // 图标保持正立不旋转，半径 8pt、1 圈/1s，停止时 easeOut 回正）。
          _WiggleIcon(
            isActive: _loading,
            child: Icon(
              Icons.search,
              size: VboxTypography.s16,
              color: scheme.outline,
            ),
          ),
          const SizedBox(width: VboxSpacing.sm),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: false,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '搜索影片、剧集',
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: _submit,
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (BuildContext context, TextEditingValue value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return GestureDetector(
                onTap: () {
                  _controller.clear();
                  _backToEmpty();
                },
                child: Icon(
                  Icons.close,
                  size: VboxTypography.s14,
                  color: scheme.outline,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 豆瓣排行榜入口（36×36 圆角灰底 + 主色柱状图；对齐 iOS `SearchView`
  /// L1393-L1403 `chart.bar.fill` 按钮）。
  Widget _buildRankingButton() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openRanking,
          child: const Icon(
            Icons.bar_chart_rounded,
            size: 18,
            color: VboxColors.brandRed,
          ),
        ),
      ),
    );
  }

  /// 提交按钮（主色底 + 箭头；对齐 iOS `SearchView` 提交钮）。
  Widget _buildSubmitButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.sm),
      child: SizedBox(
        width: 40,
        height: 36,
        child: FilledButton(
          onPressed: () => _submit(_controller.text),
          style: FilledButton.styleFrom(
            backgroundColor: VboxColors.brandRed,
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: const Icon(Icons.arrow_forward, size: 18),
        ),
      ),
    );
  }

  // ─────────────── 空态 ───────────────

  Widget _buildEmptyState() {
    final Failure? error = _error;
    if (error != null && _sites == null) {
      return _ErrorRetry(message: '$error', onRetry: _init);
    }
    final List<SiteConfig> sites = _sites ?? const <SiteConfig>[];
    final List<DoubanSubject> doubanItems =
        _doubanCache[_doubanTabs[_doubanTab].$1] ?? const <DoubanSubject>[];
    final bool showDouban = _douban != null;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: VboxSpacing.md),
      children: <Widget>[
        if (_historyWords.isNotEmpty) _buildHistory(),
        if (showDouban) ...<Widget>[
          _buildDoubanTabs(),
          _buildDoubanList(doubanItems),
          const Divider(height: VboxSpacing.xl),
        ],
        if (sites.isNotEmpty) _buildAllSites(sites),
        if (_historyWords.isEmpty && !showDouban && sites.isEmpty)
          const _EmptyHint(text: '输入关键词，搜索你想要的影片'),
      ],
    );
  }

  /// 豆瓣栏目标签行（对齐 iOS `SearchView.doubanTabs` 下划线标签）。
  Widget _buildDoubanTabs() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _doubanTabs.length; i++) ...<Widget>[
            if (i > 0) ...<Widget>[
              const SizedBox(width: VboxSpacing.md),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outlineVariant,
                indent: 8,
                endIndent: 8,
              ),
              const SizedBox(width: VboxSpacing.md),
            ],
            GestureDetector(
              onTap: () => _selectDoubanTab(i),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _doubanTabs[i].$1,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: i == _doubanTab
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: i == _doubanTab
                          ? VboxColors.brandRed
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 2,
                    width: 24,
                    decoration: BoxDecoration(
                      color: i == _doubanTab
                          ? VboxColors.brandRed
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(VboxRadii.r4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 豆瓣栏目数据列表（骨架屏 / 卡片行）。
  Widget _buildDoubanList(List<DoubanSubject> items) {
    if (_doubanLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: VboxSpacing.lg, vertical: VboxSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        children: <Widget>[
          for (final DoubanSubject subject in items) ...<Widget>[
            _DoubanCardRow(
              subject: subject,
              onTap: () => _runKeywordSearch(subject.title),
            ),
            const SizedBox(height: VboxSpacing.sm),
          ],
        ],
      ),
    );
  }

  /// 全部站点区块（对齐 iOS `SearchView`「全部站点 (N)」）。
  Widget _buildAllSites(List<SiteConfig> sites) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        VboxSectionHeader(title: '全部站点 (${sites.length})'),
        for (final SiteConfig s in sites)
          _SourceTile(
            name: s.name.isEmpty ? s.key : s.name,
            selected: s.key == _siteKey,
            onTap: () => _onSourceChanged(s.key),
          ),
      ],
    );
  }

  /// 以关键词触发搜索（豆瓣卡片点击，对齐 iOS `runKeywordSearch`）。
  Future<void> _runKeywordSearch(String keyword) async {
    _controller.text = keyword;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    await _submit(keyword);
  }

  /// 搜索历史（时钟图标 + 标题 + 「清空」；对齐 iOS `SearchView` 历史区）。
  Widget _buildHistory() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
          child: Row(
            children: <Widget>[
              Icon(Icons.history, size: VboxTypography.s16, color: scheme.primary),
              const SizedBox(width: VboxSpacing.xs),
              Expanded(
                child: Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              TextButton(
                onPressed: _clearHistory,
                child: const Text('清空'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            itemCount: _historyWords.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(width: VboxSpacing.sm),
            itemBuilder: (BuildContext context, int index) {
              final String word = _historyWords[index];
              return VboxChip(
                label: word,
                dense: true,
                onTap: () => _useHistoryWord(word),
              );
            },
          ),
        ),
      ],
    );
  }

  // ─────────────── 结果态 ───────────────

  Widget _buildResultState() {
    final Failure? error = _error;
    if (_results.isEmpty) {
      if (error != null && !_loading) {
        return _ErrorRetry(
          message: '$error',
          onRetry: () => _search(_controller.text),
        );
      }
      // 搜索中尚无结果：保留默认内容 + 顶部「搜索中…」小条
      // （对齐 iOS `SearchView` L1505-L1522）。
      if (_loading) {
        return Stack(
          children: <Widget>[
            _buildEmptyState(),
            const Positioned(
              top: VboxSpacing.sm,
              left: 0,
              right: 0,
              child: Center(child: _SearchingPill()),
            ),
          ],
        );
      }
      // 已结束且无结果：放大镜 + 「未找到结果」（对齐 iOS L1496-L1504）。
      return const _NoResultHint();
    }

    final List<_SourceGroup> groups = _groupResults();
    // 单一来源 → 单列；多来源 → 左源列表 + 右结果（对齐 iOS `SearchResultsView`）。
    // 已有结果即直接展示结果页，**不再叠加「搜索中…」小条**
    // （对齐 iOS L1493-L1495：结果非空时只渲染 `SearchResultsView`）。
    return groups.length <= 1
        ? _buildResultList(groups.isEmpty ? _results : groups.first.videos)
        : _buildMultiColumn(groups);
  }

  /// 按来源分组（对齐 iOS `SearchResultsView.grouped`）。
  ///
  /// 排序三级：① 网盘原生（☁️ 非 JS）② JS 蜘蛛网盘（☁️ + engineKey）
  /// ③ 其他；同级按结果数降序。
  List<_SourceGroup> _groupResults() {
    final Map<String, List<VodItem>> dict = <String, List<VodItem>>{};
    for (final VodItem v in _results) {
      dict.putIfAbsent(_groupLabel(v), () => <VodItem>[]).add(v);
    }
    final List<_SourceGroup> groups = dict.entries
        .map((MapEntry<String, List<VodItem>> e) =>
            _SourceGroup(source: e.key, videos: e.value))
        .toList();
    groups.sort((_SourceGroup a, _SourceGroup b) {
      final int ta = _sourceTier(a);
      final int tb = _sourceTier(b);
      if (ta != tb) return ta.compareTo(tb);
      return b.videos.length.compareTo(a.videos.length);
    });
    return groups;
  }

  int _sourceTier(_SourceGroup g) {
    final bool cloud = g.source.startsWith('☁️');
    final bool js = g.videos.any((VodItem v) => v.engineKey != null);
    if (cloud && !js) return 1;
    if (cloud && js) return 2;
    return 3;
  }

  String _groupLabel(VodItem v) {
    final String r = v.vodRemarks?.trim() ?? '';
    if (r.isNotEmpty) return r;
    final String k = v.engineKey ?? '';
    if (k.isNotEmpty) {
      final SiteConfig? s = _siteByKey(k);
      return s == null ? k : _siteLabel(s);
    }
    return '搜索结果';
  }

  SiteConfig? _siteByKey(String key) {
    for (final SiteConfig s in _sites ?? const <SiteConfig>[]) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 多来源：左源列表 + 右结果（该源结果按剧名排序，对齐 iOS `currentVideos`）。
  Widget _buildMultiColumn(List<_SourceGroup> groups) {
    final String sel = groups.any((_SourceGroup g) => g.source == _selectedSource)
        ? _selectedSource!
        : groups.first.source;
    final List<VodItem> videos = List<VodItem>.of(
      groups.firstWhere((_SourceGroup g) => g.source == sel).videos,
    )..sort((VodItem a, VodItem b) => a.vodName.compareTo(b.vodName));
    // 左栏宽度对齐 iOS `min(108, max(98, width * 0.23))`。
    final double panelWidth =
        (MediaQuery.sizeOf(context).width * 0.23).clamp(98.0, 108.0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: panelWidth,
          child: ListView(
            padding: const EdgeInsets.symmetric(
              vertical: VboxSpacing.sm,
              horizontal: VboxSpacing.sm,
            ),
            children: <Widget>[
              for (final _SourceGroup g in groups)
                _SourceLabel(
                  name: g.source,
                  selected: g.source == sel,
                  onTap: () => setState(() => _selectedSource = g.source),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _buildResultList(videos)),
      ],
    );
  }

  Widget _buildResultList(List<VodItem> items) {
    return ListView.builder(
      padding: const EdgeInsets.all(VboxSpacing.md),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final VodItem vod = items[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: VboxSpacing.md),
          child: _ResultCard(vod: vod, onTap: () => _openDetail(vod)),
        );
      },
    );
  }

  void _openDetail(VodItem vod) {
    // 附加源结果（占源/腾讯）按 `engineKey` 路由详情；缺省用当前选中站点。
    final String? engineKey = vod.engineKey;
    final String key = (engineKey != null && engineKey.isNotEmpty)
        ? engineKey
        : (_siteKey ?? '');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DetailPage(
          siteKey: key,
          vodId: vod.vodId,
          title: vod.vodName,
        ),
      ),
    );
  }
}

/// 源列表项（横屏左栏）。
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.name,
    required this.selected,
    this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.12),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: VboxTypography.s13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? scheme.primary : scheme.onSurface,
        ),
      ),
      onTap: onTap,
    );
  }
}

/// 豆瓣空搜索页卡片行（封面 + 标题 + 评分 + 副标题 + 「点击搜索」）。
///
/// 对齐 iOS `MainViews.swift SearchDoubanCardItem`（L2183-L2236）：封面 70×95、
/// 圆角 8；标题 15 semibold；黄色星形评分；副标题 12；底部主色「点击搜索 “标题”」；
/// 右侧放大镜图标。整卡点击 → 以条目标题触发搜索。
class _DoubanCardRow extends StatelessWidget {
  const _DoubanCardRow({required this.subject, this.onTap});

  final DoubanSubject subject;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String subtitle = subject.cardSubtitle?.isNotEmpty ?? false
        ? subject.cardSubtitle!
        : subject.genreText;

    return InkWell(
      onTap: onTap,
      borderRadius: VboxRadii.button,
      child: Container(
        padding: const EdgeInsets.all(VboxSpacing.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 70,
                height: 95,
                child: PlatformAsyncImage(
                  url: subject.coverUrl,
                  fit: BoxFit.cover,
                  // UI-B3 骨架屏动效：静态占位 → 渐变扫光（保留影片图标，见 golden 像素契约）。
                  placeholder: ShimmerBox(
                    color: scheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.movie_outlined,
                        size: VboxTypography.s24,
                        color: Colors.white.withValues(alpha: 0.40),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    subject.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s15,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subject.hasRating) ...<Widget>[
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        const Icon(Icons.star, size: 12, color: VboxColors.ratingStar),
                        const SizedBox(width: 4),
                        Text(
                          subject.rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: VboxTypography.s13,
                            fontWeight: FontWeight.w700,
                            color: VboxColors.ratingStar,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: VboxTypography.s12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '点击搜索 “${subject.title}”',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: VboxSpacing.sm),
            Icon(
              Icons.search,
              size: 24,
              color: scheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 结果卡（对齐 iOS `MainViews.swift SearchResultRow` L2108-L2150）：
/// 封面 85×110、标题 15 semibold、年份/地区素标签、导演/主演 11、底部居中来源标签、右侧播放图标。
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.vod, this.onTap});

  final VodItem vod;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? year = _nonEmptyText(vod.vodYear);
    final String? area = _nonEmptyText(vod.vodArea);
    final String? director = _nonEmptyText(vod.vodDirector);
    final String? actor = _nonEmptyText(vod.vodActor);
    final String? source = _nonEmptyText(vod.vodRemarks);

    return InkWell(
      onTap: onTap,
      borderRadius: VboxRadii.button,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: VboxRadii.button,
              child: SizedBox(
                width: 85,
                height: 110,
                child: PlatformAsyncImage(
                  url: vod.vodPic,
                  fit: BoxFit.cover,
                  // UI-B3 骨架屏动效：静态占位 → 渐变扫光（保留影片图标，见 golden 像素契约）。
                  placeholder: ShimmerBox(
                    color: scheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.movie_outlined,
                        size: VboxTypography.s24,
                        color: Colors.white.withValues(alpha: 0.40),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: SizedBox(
                height: 110,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      vod.vodName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (year != null || area != null) ...<Widget>[
                      const SizedBox(height: 5),
                      Row(
                        children: <Widget>[
                          if (year != null) _PlainTag(text: year),
                          if (year != null && area != null)
                            const SizedBox(width: VboxSpacing.sm),
                          if (area != null) _PlainTag(text: area),
                        ],
                      ),
                    ],
                    if (director != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '导演: $director',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: VboxTypography.s11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (actor != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '主演: $actor',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: VboxTypography.s11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (source != null)
                      Align(
                        alignment: Alignment.center,
                        child: _SourceTag(text: source),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: VboxSpacing.sm),
            Icon(Icons.play_circle_fill, size: 30, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

String? _nonEmptyText(String? value) {
  final String s = value?.trim() ?? '';
  return s.isEmpty ? null : s;
}

/// 素标签（年份 / 地区；对齐 iOS `PlainTagBadge`）。
class _PlainTag extends StatelessWidget {
  const _PlainTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: VboxTypography.s11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
}

/// 来源标签（主色胶囊；对齐 iOS `SourceTagBadge`）。
class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final Color primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(VboxRadii.capsule),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: VboxTypography.s10,
          fontWeight: FontWeight.w500,
          color: primary,
        ),
      ),
    );
  }
}

/// 左栏来源标签（对齐 iOS `SourceNameLabel`）：☁️ 源显示云图标，选中主色底 + 白字。
class _SourceLabel extends StatelessWidget {
  const _SourceLabel({
    required this.name,
    required this.selected,
    this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasCloud = name.startsWith('☁️');
    final String clean =
        name.replaceFirst('☁️', '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: VboxRadii.button,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 7),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 14,
                height: 14,
                child: hasCloud
                    ? Icon(
                        Icons.cloud,
                        size: 10,
                        color: selected
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      )
                    : null,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  clean,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索中「原地画圈」放大镜（对齐 iOS `SearchWiggleModifier`）。
///
/// 图标保持正立不旋转，在原地做半径 8pt 的小圆周运动（1 圈/1s），
/// 激停时以 easeOut 0.25s 平滑回正。
class _WiggleIcon extends StatefulWidget {
  const _WiggleIcon({required this.isActive, required this.child});

  /// 是否激活动画（绑定搜索加载态）。
  final bool isActive;

  /// 被包裹的图标。
  final Widget child;

  @override
  State<_WiggleIcon> createState() => _WiggleIconState();
}

class _WiggleIconState extends State<_WiggleIcon>
    with SingleTickerProviderStateMixin {
  /// 圆周半径（pt），对齐 iOS `SearchWiggleModifier.orbitRadius`。
  static const double _orbitRadius = 8;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.isActive) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _WiggleIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      _controller.repeat();
    } else {
      // 停止并平滑回正（对齐 iOS `stopAnimation`：easeOut 0.25s → angle 0）。
      _controller.stop();
      _controller.animateBack(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double angle = _controller.value * 2 * math.pi;
        return Transform.translate(
          offset: Offset(
            math.cos(angle) * _orbitRadius,
            math.sin(angle) * _orbitRadius,
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// 搜索中提示小条（对齐 iOS `SearchView` 顶部「搜索中...」胶囊）。
class _SearchingPill extends StatelessWidget {
  const _SearchingPill();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.capsule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: VboxSpacing.sm),
          Text(
            '搜索中...',
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果来源分组（对齐 iOS `SearchResultsView.grouped`）。
class _SourceGroup {
  const _SourceGroup({required this.source, required this.videos});

  final String source;
  final List<VodItem> videos;
}

/// 空态提示。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ),
    );
  }
}

/// 无结果提示（放大镜 + 「未找到结果」；对齐 iOS `SearchView` L1498-L1503）。
class _NoResultHint extends StatelessWidget {
  const _NoResultHint();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.search, size: 40, color: scheme.outline),
          const SizedBox(height: VboxSpacing.xl),
          Text(
            '未找到结果',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              color: scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 加载失败提示 + 重试。
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}