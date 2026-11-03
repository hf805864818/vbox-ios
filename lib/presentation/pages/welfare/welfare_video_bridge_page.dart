/// 福利平台播放中转页（批次 H · H-03 续段）。
///
/// 唯一真相源：iOS `vbox/Views/FuliVideoBridgeView.swift`。
/// 点击视频卡片后直接进入本页：加载详情（封面 / 标题 / 剧集）→
/// 线路分组 → 解析播放地址 → 进入全屏播放页 [PlayerPage]，
/// **不经过** 通用详情页（不影响网盘 / 切片 / 短剧等既有播放链路）。
///
/// 布局对齐 iOS：
///   · 16:9 封面（`FuliCoverImage`）+ 加载中白色进度圈 / 就绪播放按钮 / 错态；
///   · 详情态：标题 + 操作行（选集 / 播放 / 线路 / 下载四胶囊）+ 简介 4 行截断；
///   · 线路 / 选集悬浮面板（`FuliEpisodeFloatingPanel`：黑底 85% 圆角面板 +
///     列表行 + 选中对勾 `#2196F3`）；
///   · 播放地址解析浮层（进度 / 失败 + 取消·重试）；
///   · 下载选集 Sheet（4 列多选网格 + 全选 + 底部确认，`FuliDownloadSheet`）。
///
/// 移植口径与差异登记：
///   · 播放接入对齐 iOS `FuliVideoBridgeView`（`fullScreenCover → VideoPlayerViewV2`）：
///     解析成功后进入全屏播放页 [PlayerPage]，播放生命周期由播放页持有；
///   · `parse=1` 二次解析（W-福5）：URL 是网页地址而非直链时，先经 [PlayUrlParser]
///     （对齐 iOS `SpiderManager.parsePlayUrl`）提取直链，失败仍回落原 URL 交播放器；
///   · 下载（W-福4）对齐 iOS `DownloadManager.enqueueDownload`：逐集解析后建
///     `__fuli_welfare__:<platformKey>` 记录交 [DownloadManager] 入队。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/download.dart';
import '../../../domain/entities/player/player.dart';
import '../../../domain/entities/playback/playback_detail.dart';
import '../../../domain/entities/welfare/fuli_models.dart';
import '../../../domain/services/fuli_base_service.dart';
import '../../../platform/download/download_manager.dart';
import '../../../platform/player/play_url_parser.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../player/player_page.dart';

/// 线路分组（UI 层概念，对齐 iOS `FuliLine`）。
///
/// 从扁平 episodes 数组中检测 `[线路名]` 前缀自动分组为线路 + 集数两层；
/// 多线路时 `WelfareResultMapper` 会给集名加 `[线路名]` 前缀，本页负责拆分还原。
class FuliLine {
  /// 构造。
  const FuliLine({required this.name, required this.episodes});

  /// 线路名。
  final String name;

  /// 该线路下的剧集。
  final List<FuliEpisode> episodes;
}

/// 福利播放回调（播放地址 + 请求头 → 打开并播放；测试注入）。
///
/// 缺省进入全屏播放页 [PlayerPage]（对齐 iOS `VideoPlayerViewV2` 播放入口）。
typedef WelfarePlayHandler = Future<void> Function(
  String url,
  Map<String, String> headers,
);

/// 福利平台播放中转页。
class WelfareVideoBridgePage extends StatefulWidget {
  /// 构造。
  const WelfareVideoBridgePage({
    super.key,
    required this.service,
    required this.video,
    this.onPlay,
    this.playUrlParser,
    this.downloadManager,
  });

  /// 引擎服务（JS / Python Spider，均继承 [FuliBaseService]）。
  final FuliBaseService service;

  /// 点击的视频条目（封面 / 标题即时展示）。
  final FuliVideo video;

  /// 播放回调（null → 解析成功后进入 [PlayerPage]）。
  final WelfarePlayHandler? onPlay;

  /// `parse=1` 二次解析器（null → 页内自建；测试注入 fake 隔离网络）。
  final PlayUrlParser? playUrlParser;

  /// 下载管理器（null → 从 [Provider] 取全局实例；测试注入内存假件）。
  final DownloadManager? downloadManager;

  @override
  State<WelfareVideoBridgePage> createState() =>
      _WelfareVideoBridgePageState();
}

class _WelfareVideoBridgePageState extends State<WelfareVideoBridgePage> {
  FuliDetail? _detail;
  bool _isLoading = true;
  String? _errorMsg;

  /// `parse=1` 二次解析器（页内自建时负责释放）。
  late final PlayUrlParser _parser;

  /// 解析器是否由页内自建（自建才在 [dispose] 关闭底层 client）。
  late final bool _ownsParser;

  // 线路 / 选集。
  List<FuliLine> _lines = const <FuliLine>[];
  int _selectedLineIndex = 0;
  bool _showLinePanel = false;
  bool _showSelectPanel = false;
  FuliEpisode? _selectedEpisode;

  // 播放地址解析。
  bool _isResolvingURL = false;
  String? _resolveError;
  FuliEpisode? _pendingEpisode;

  // 下载。
  bool _isDownloading = false;
  bool _showDownloadTip = false;
  String _downloadTipText = '';

  // ─────────────── 计算属性（对齐 iOS `currentLine` / `currentEpisodes`）───────────────

  FuliLine? get _currentLine =>
      _selectedLineIndex < _lines.length ? _lines[_selectedLineIndex] : null;

  List<FuliEpisode> get _currentEpisodes => _currentLine?.episodes ?? const [];

  // ─────────────── 生命周期 ───────────────

  @override
  void initState() {
    super.initState();
    final PlayUrlParser? injected = widget.playUrlParser;
    _ownsParser = injected == null;
    _parser = injected ?? PlayUrlParser();
    _loadDetail();
  }

  @override
  void dispose() {
    if (_ownsParser) _parser.dispose();
    super.dispose();
  }

  // ─────────────── 数据加载（对齐 iOS `loadDetail`）───────────────

  Future<void> _loadDetail() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
      _detail = null;
    });
    final FuliDetail result = await widget.service.fetchDetail(
      widget.video.vodId,
    );
    if (!mounted) return;
    setState(() {
      _detail = result;
      _isLoading = false;
      if (result.episodes.isEmpty) {
        _errorMsg = '未解析到播放地址';
      } else {
        _lines = _detectLines(result.episodes);
        _selectedLineIndex = 0;
        _selectedEpisode = _lines.isEmpty ? null : _lines.first.episodes.first;
      }
    });
  }

  /// 重试（对齐 iOS 重试按钮：重新加载详情）。
  void _retry() {
    widget.service.reprobe();
    _loadDetail();
  }

  // ─────────────── 播放控制（对齐 iOS `playFirst` / `playEpisode` / `resolveEpisode`）───────────────

  void _playFirst() {
    final List<FuliEpisode> eps = _currentEpisodes;
    if (eps.isEmpty) return;
    final FuliEpisode first = eps.first;
    setState(() => _selectedEpisode = first);
    _playEpisode(first);
  }

  void _playEpisode(FuliEpisode episode) {
    setState(() => _pendingEpisode = episode);
    _resolveEpisode();
  }

  Future<void> _resolveEpisode() async {
    final FuliEpisode? episode = _pendingEpisode;
    if (episode == null) return;
    setState(() {
      _isResolvingURL = true;
      _resolveError = null;
    });

    final FuliPlayerResult result = await widget.service.fetchPlayerURL(
      episode,
    );

    // 对齐 iOS `resolveEpisode`：`parse=1` 时 URL 是网页地址而非直链，先经
    // [PlayUrlParser]（对齐 `SpiderManager.parsePlayUrl`）提取直链；失败仍回落
    // 原 URL 交播放器内部重试；headers 始终保留原始值。解析期间浮层保持展示。
    final String url = await _resolvePlayableUrl(result);
    if (!mounted) return;
    if (url.isEmpty) {
      setState(() {
        _isResolvingURL = false;
        _resolveError = '无法获取有效的播放地址';
      });
      return;
    }
    setState(() {
      _isResolvingURL = false;
      _pendingEpisode = null;
    });
    final WelfarePlayHandler handler = widget.onPlay ?? _defaultPlay;
    await handler(url, result.headers);
  }

  /// `parse=1` 二次解析：把 `result.url` 提取为直链；`parse != 1` 原样返回。
  ///
  /// 对齐 iOS `resolveEpisode` L415-L423：仅当 `parse == 1` 且 URL 非空时走解析器，
  /// 解析失败（返回 `null`）保留原始 URL 交由播放器内部再次尝试。
  Future<String> _resolvePlayableUrl(FuliPlayerResult result) async {
    final String url = result.url;
    if (result.parse != 1 || url.isEmpty) return url;
    final String? parsed = await _parser.parse(url);
    return parsed ?? url;
  }

  /// 缺省播放：解析成功后进入全屏播放页（对齐 iOS `fullScreenCover → VideoPlayerViewV2`）。
  Future<void> _defaultPlay(String url, Map<String, String> headers) async {
    if (!mounted) return;
    final List<PlaybackEpisode> episodes = _playbackEpisodes();
    final int index = _selectedEpisodeIndex(episodes);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PlayerPage(
          source: PlayerSource(
            url: url,
            title: widget.video.vodName,
            headers: headers,
          ),
          title: widget.video.vodName,
          subtitle: _selectedEpisode?.name,
          episodes: episodes,
          initialEpisodeIndex: index,
          onResolveEpisode:
              episodes.isEmpty ? null : _resolveEpisodeSource,
        ),
      ),
    );
  }

  /// 当前线路剧集 → 播放页选集数据（[PlaybackEpisode] 与 [FuliEpisode] 同构）。
  List<PlaybackEpisode> _playbackEpisodes() => _currentEpisodes
      .map((FuliEpisode e) => PlaybackEpisode(name: e.name, url: e.url))
      .toList(growable: false);

  /// 当前选中集在 [episodes] 中的下标（缺失回退 0）。
  int _selectedEpisodeIndex(List<PlaybackEpisode> episodes) {
    final FuliEpisode? selected = _selectedEpisode;
    if (selected == null || episodes.isEmpty) return 0;
    final int i = episodes.indexWhere(
      (PlaybackEpisode e) => e.url == selected.url && e.name == selected.name,
    );
    return i < 0 ? 0 : i;
  }

  /// 选集重开解析器：单集 → 播放源（复用 [FuliBaseService.fetchPlayerURL]）。
  Future<PlayerSource?> _resolveEpisodeSource(PlaybackEpisode episode) async {
    final FuliPlayerResult result = await widget.service.fetchPlayerURL(
      FuliEpisode(name: episode.name, url: episode.url),
    );
    final String url = await _resolvePlayableUrl(result);
    if (url.isEmpty) return null;
    return PlayerSource(
      url: url,
      title: widget.video.vodName,
      headers: result.headers,
    );
  }

  void _retryResolve() {
    setState(() => _resolveError = null);
    _resolveEpisode();
  }

  void _cancelResolve() {
    setState(() {
      _resolveError = null;
      _pendingEpisode = null;
      _isResolvingURL = false;
    });
  }

  // ─────────────── 线路分组检测（对齐 iOS `detectLines`）───────────────

  /// 从扁平 episodes 数组中检测并分组线路。
  ///
  /// `[线路名]` 前缀 → 提取线路名与纯集名；无前缀视为单线路（"在线播放"）。
  List<FuliLine> _detectLines(List<FuliEpisode> episodes) {
    final List<String> lineOrder = <String>[];
    final Map<String, List<FuliEpisode>> lineMap =
        <String, List<FuliEpisode>>{};
    const String defaultLine = '在线播放';

    for (final FuliEpisode ep in episodes) {
      if (ep.name.startsWith('[')) {
        final int closeIdx = ep.name.indexOf(']');
        if (closeIdx > 0) {
          final String lineName = ep.name.substring(1, closeIdx);
          final String epName = ep.name.substring(closeIdx + 1).trim();
          lineMap.putIfAbsent(lineName, () {
            lineOrder.add(lineName);
            return <FuliEpisode>[];
          }).add(FuliEpisode(name: epName, url: ep.url));
          continue;
        }
      }
      lineMap.putIfAbsent(defaultLine, () {
        lineOrder.add(defaultLine);
        return <FuliEpisode>[];
      }).add(ep);
    }

    return <FuliLine>[
      for (final String name in lineOrder)
        FuliLine(name: name, episodes: lineMap[name] ?? const <FuliEpisode>[]),
    ];
  }

  // ─────────────── 下载（UI 对齐 iOS `handleBatchDownload`；W-福4 接线）───────────────

  /// 批量下载：逐集解析 → `parse=1` 二次解析 → 建 `[福利]` 记录交 [DownloadManager]。
  ///
  /// 对齐 iOS `FuliVideoBridgeView.handleBatchDownload` L458-L527：
  ///   · `name = "<视频名> <集名>"`、`laiyuan = "[福利]<平台名>"`、
  ///     `engineKey = "__fuli_welfare__:<platformKey>"`、`sourceType = "normal"`、
  ///     `jishu = 成功序号`；`headers` 非空时 JSON 编码，空则 null；
  ///   · 解析失败的单集跳过；成功数 > 0 → 提示「已添加 N 集到下载」，
  ///     否则提示「下载失败，未能解析到播放地址」。
  Future<void> _handleBatchDownload(List<int> indices) async {
    final List<FuliEpisode> eps = _currentEpisodes;
    if (_isDownloading || eps.isEmpty || indices.isEmpty) return;

    final DownloadManager manager =
        widget.downloadManager ?? context.read<DownloadManager>();
    final String platformKey = widget.service.platformKey;
    final String platformName = widget.service.platformName;
    final String videoName = widget.video.vodName;
    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    setState(() => _isDownloading = true);
    int successCount = 0;
    for (final int index in indices) {
      if (index < 0 || index >= eps.length) continue;
      final FuliEpisode episode = eps[index];
      final FuliPlayerResult result =
          await widget.service.fetchPlayerURL(episode);
      final String url = await _resolvePlayableUrl(result);
      if (url.isEmpty) continue;

      final String headersJson = result.headers.isEmpty
          ? ''
          : jsonEncode(result.headers);
      await manager.enqueue(
        Download(
          name: '$videoName ${episode.name}',
          laiyuan: '[福利]$platformName',
          imgurl: widget.video.vodPic,
          detailurl: widget.video.vodId,
          playurl: url,
          jishu: successCount + 1,
          addedAt: now,
          sourceType: 'normal',
          engineKey: '__fuli_welfare__:$platformKey',
          vodId: widget.video.vodId,
          headers: headersJson.isEmpty ? null : headersJson,
        ),
      );
      successCount++;
    }

    if (!mounted) return;
    setState(() {
      _isDownloading = false;
      _downloadTipText = successCount > 0
          ? '已添加 $successCount 集到下载'
          : '下载失败，未能解析到播放地址';
      _showDownloadTip = true;
    });
    Future<void>.delayed(const Duration(seconds: 2)).then((void _) {
      if (mounted) setState(() => _showDownloadTip = false);
    });
  }

  // ─────────────── 构建 ───────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放'), centerTitle: true),
      body: Stack(
        children: <Widget>[
          _body(context),
          if (_showLinePanel && _lines.length > 1) _panelBarrier(false),
          if (_showSelectPanel && _currentEpisodes.length > 1)
            _panelBarrier(true),
          if (_showLinePanel && _lines.length > 1)
            Positioned(
              left: 0,
              right: 0,
              top: 90,
              child: Center(
                child: _FuliFloatingPanel(
                  title: '选择线路',
                  items: <_FuliPanelItem>[
                    for (final FuliLine line in _lines)
                      _FuliPanelItem(
                        name: line.name,
                        isSelected: line.name == _currentLine?.name,
                        onTap: () => _selectLine(line.name),
                      ),
                  ],
                ),
              ),
            ),
          if (_showSelectPanel && _currentEpisodes.length > 1)
            Positioned(
              left: 0,
              right: 0,
              top: 90,
              child: Center(
                child: _FuliFloatingPanel(
                  title: '选集',
                  items: <_FuliPanelItem>[
                    for (final FuliEpisode ep in _currentEpisodes)
                      _FuliPanelItem(
                        name: ep.name,
                        isSelected:
                            ep.url == _selectedEpisode?.url && ep.name == _selectedEpisode?.name,
                        onTap: () => _selectEpisode(ep),
                      ),
                  ],
                ),
              ),
            ),
          if (_isResolvingURL || _resolveError != null)
            _resolveOverlay(context),
          if (_showDownloadTip) _downloadTip(context),
        ],
      ),
    );
  }

  Widget _panelBarrier(bool isSelect) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() {
          if (isSelect) {
            _showSelectPanel = false;
          } else {
            _showLinePanel = false;
          }
        }),
        child: Container(color: Colors.black.withValues(alpha: 0.3)),
      ),
    );
  }

  void _selectLine(String lineName) {
    final int idx = _lines.indexWhere((FuliLine l) => l.name == lineName);
    if (idx >= 0) {
      setState(() {
        _selectedLineIndex = idx;
        final List<FuliEpisode> eps = _lines[idx].episodes;
        _selectedEpisode = eps.isEmpty ? null : eps.first;
      });
    }
    setState(() => _showLinePanel = false);
  }

  void _selectEpisode(FuliEpisode ep) {
    setState(() => _selectedEpisode = ep);
    setState(() => _showSelectPanel = false);
    _playEpisode(ep);
  }

  Widget _body(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(
        top: VboxSpacing.xl,
        bottom: VboxSpacing.xxl,
      ),
      children: <Widget>[
        _cover(context, scheme),
        const SizedBox(height: VboxSpacing.lg),
        if (_errorMsg != null)
          _errorState(scheme)
        else if (_detail != null)
          ..._detailState(context, scheme, _detail!),
      ],
    );
  }

  // ─────────────── 16:9 封面（对齐 iOS `FuliCoverImage` + 播放按钮叠加）───────────────

  Widget _cover(BuildContext context, ColorScheme scheme) {
    final FuliDetail? detail = _detail;
    final bool showPlay =
        !_isLoading && _errorMsg == null && (detail?.episodes.isNotEmpty ?? false);

    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(VboxRadii.r12),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              PlatformAsyncImage.sourceCover(
                widget.video.vodPic,
                referer: widget.service.imageReferer,
                sslBypass: widget.service.imageSSLBypass,
                fit: BoxFit.fitWidth,
                placeholderColor: scheme.surfaceContainerHighest,
                placeholder: Icon(
                  Icons.movie_outlined,
                  size: VboxTypography.s28,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.40),
                ),
              ),
              if (_isLoading)
                const Center(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (showPlay)
                Center(
                  child: GestureDetector(
                    onTap: _playFirst,
                    child: Icon(
                      Icons.play_circle_fill,
                      size: 64,
                      color: Colors.white.withValues(alpha: 0.95),
                      shadows: const <Shadow>[
                        Shadow(
                          color: Colors.black38,
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── 错态（对齐 iOS 错态：play.slash + 文案 + 重试）───────────────

  Widget _errorState(ColorScheme scheme) {
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.play_disabled,
            size: 40,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: VboxSpacing.md),
          Text(
            _errorMsg!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              textStyle: const TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.xl),
        ],
      ),
    );
  }

  // ─────────────── 详情态（对齐 iOS：标题 + 操作行 + 简介）───────────────

  List<Widget> _detailState(
    BuildContext context,
    ColorScheme scheme,
    FuliDetail detail,
  ) {
    final List<FuliEpisode> eps = _currentEpisodes;
    final bool hasEpisodes = detail.episodes.isNotEmpty;
    return <Widget>[
      Padding(
        padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
        child: Text(
          detail.vodName,
          style: TextStyle(
            fontSize: VboxTypography.s18,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
      ),
      if (hasEpisodes) ...<Widget>[
        const SizedBox(height: VboxSpacing.md),
        _actionRow(context, scheme, eps),
      ],
      if (!hasEpisodes)
        Padding(
          padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
          child: Text(
            '未解析到播放地址',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      if (detail.vodContent != null && detail.vodContent!.isNotEmpty)
        Padding(
          padding: VboxSpacing.symmetric(
            horizontal: VboxSpacing.lg,
            vertical: VboxSpacing.md,
          ),
          child: Text(
            detail.vodContent!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }

  // ─────────────── 操作行（对齐 iOS：选集 / 播放 / 线路 / 下载 四胶囊）───────────────

  Widget _actionRow(
    BuildContext context,
    ColorScheme scheme,
    List<FuliEpisode> eps,
  ) {
    final String playLabel = eps.length == 1
        ? '立即播放'
        : '播放${_selectedEpisode?.name ?? eps.first.name}';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Row(
        children: <Widget>[
          if (eps.length > 1) ...<Widget>[
            _pillButton(
              scheme: scheme,
              icon: Icons.format_list_bulleted,
              label: '选集(${eps.length})',
              active: _showSelectPanel,
              onTap: () => setState(() {
                _showSelectPanel = !_showSelectPanel;
                _showLinePanel = false;
              }),
            ),
            const SizedBox(width: VboxSpacing.md),
          ],
          _pillButton(
            scheme: scheme,
            icon: Icons.play_arrow_rounded,
            label: playLabel,
            filled: true,
            onTap: _playFirst,
          ),
          if (_lines.length > 1) ...<Widget>[
            const SizedBox(width: VboxSpacing.md),
            _pillButton(
              scheme: scheme,
              icon: Icons.swap_vert_rounded,
              label: '线路(${_lines.length})',
              active: _showLinePanel,
              onTap: () => setState(() {
                _showLinePanel = !_showLinePanel;
                _showSelectPanel = false;
              }),
            ),
          ],
          const SizedBox(width: VboxSpacing.md),
          _pillButton(
            scheme: scheme,
            icon: Icons.download_outlined,
            label: '下载',
            onTap: _showDownloadSheet,
          ),
        ],
      ),
    );
  }

  Widget _pillButton({
    required ColorScheme scheme,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool filled = false,
  }) {
    final Color accent = active ? VboxColors.selected : scheme.primary;
    final Color bg = filled
        ? scheme.primary
        : (active
            ? VboxColors.selected.withValues(alpha: 0.15)
            : scheme.primary.withValues(alpha: 0.10));
    final Color fg = filled ? scheme.onPrimary : accent;

    return Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: VboxSpacing.symmetric(
            horizontal: VboxSpacing.xl,
            vertical: 10,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: VboxSpacing.xs),
              Text(
                label,
                style: TextStyle(
                  fontSize: VboxTypography.s15,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── 下载选集 Sheet（对齐 iOS `FuliDownloadSheet`）───────────────

  Future<void> _showDownloadSheet() async {
    final List<FuliEpisode> eps = _currentEpisodes;
    if (eps.isEmpty) return;
    final List<int>? picked = await showModalBottomSheet<List<int>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _WelfareDownloadSheet(
        episodes: eps,
        lineName: _currentLine?.name ?? '',
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    await _handleBatchDownload(picked);
  }

  // ─────────────── 解析浮层（对齐 iOS：进度 / 失败 + 取消·重试）───────────────

  Widget _resolveOverlay(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.4)),
          ),
          Center(
            child: Container(
              width: double.infinity,
              margin: VboxSpacing.symmetric(horizontal: 40),
              padding: VboxSpacing.all(VboxSpacing.xxl),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(VboxRadii.r16),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_isResolvingURL) ...<Widget>[
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(height: VboxSpacing.lg),
                    Text(
                      '正在解析播放地址...',
                      style: TextStyle(
                        fontSize: VboxTypography.s14,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                  ] else ...<Widget>[
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 36,
                      color: VboxColors.warning,
                    ),
                    const SizedBox(height: VboxSpacing.md),
                    Text(
                      '播放地址解析失败',
                      style: TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: VboxSpacing.sm),
                    Text(
                      _resolveError ?? '',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: VboxTypography.s13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: VboxSpacing.lg),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _cancelResolve,
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: VboxSpacing.md),
                        Expanded(
                          child: FilledButton(
                            onPressed: _retryResolve,
                            style: FilledButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: scheme.onPrimary,
                            ),
                            child: const Text('重试'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── 下载提示（对齐 iOS 底部 Capsule 提示）───────────────

  Widget _downloadTip(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: VboxSpacing.xl,
      child: Center(
        child: Material(
          color: Colors.black.withValues(alpha: 0.8),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: VboxSpacing.symmetric(
              horizontal: VboxSpacing.lg,
              vertical: 10,
            ),
            child: Text(
              _downloadTipText,
              style: const TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 线路 / 选集悬浮面板（对齐 iOS `FuliEpisodeFloatingPanel`）。
///
/// 黑底 85% 圆角面板：标题 + 可滚动列表行（选中项 `#2196F3` 粗体 + 对勾），
/// 通用于「选择线路」与「选集」两种场景。
class _FuliFloatingPanel extends StatelessWidget {
  const _FuliFloatingPanel({required this.title, required this.items});

  /// 面板标题。
  final String title;

  /// 列表项。
  final List<_FuliPanelItem> items;

  @override
  Widget build(BuildContext context) {
    final double maxHeight = (MediaQuery.sizeOf(context).height * 0.5)
        .clamp(0.0, 280.0)
        .toDouble();
    return Container(
      width: 220,
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(VboxRadii.r12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 0.5),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Colors.black45,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int i = 0; i < items.length; i++) ...<Widget>[
                    _row(items[i]),
                    if (i < items.length - 1)
                      Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.08),
                        indent: 14,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(_FuliPanelItem item) {
    return InkWell(
      onTap: item.onTap,
      child: Container(
        width: double.infinity,
        padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.lg - 2,
          vertical: 11,
        ),
        color: item.isSelected
            ? VboxColors.selected.withValues(alpha: 0.15)
            : Colors.transparent,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight:
                      item.isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: item.isSelected
                      ? VboxColors.selected
                      : Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (item.isSelected) ...<Widget>[
              const SizedBox(width: VboxSpacing.sm),
              const Icon(
                Icons.check,
                size: 11,
                color: VboxColors.selected,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 悬浮面板列表项。
class _FuliPanelItem {
  const _FuliPanelItem({
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  /// 显示名。
  final String name;

  /// 是否选中。
  final bool isSelected;

  /// 点击回调。
  final VoidCallback onTap;
}

/// 福利下载选集 Sheet（对齐 iOS `FuliDownloadSheet`）。
///
/// 4 列网格多选 + 全选切换 + 底部「下载选中(N)」确认；
/// 选中项实心主色底白字，未选中灰 12% 底正文色，圆角 8。
class _WelfareDownloadSheet extends StatefulWidget {
  const _WelfareDownloadSheet({required this.episodes, required this.lineName});

  /// 当前线路剧集。
  final List<FuliEpisode> episodes;

  /// 线路名。
  final String lineName;

  @override
  State<_WelfareDownloadSheet> createState() => _WelfareDownloadSheetState();
}

class _WelfareDownloadSheetState extends State<_WelfareDownloadSheet> {
  final Set<int> _selectedIndices = <int>{};

  bool get _allSelected => _selectedIndices.length == widget.episodes.length;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int total = widget.episodes.length;
    final int selected = _selectedIndices.length;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.lg,
                vertical: VboxSpacing.sm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '选择下载集数',
                          style: TextStyle(
                            fontSize: VboxTypography.s16,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: VboxSpacing.xs),
                        Text(
                          '${widget.lineName} - 共 $total 集，已选 $selected 集',
                          style: TextStyle(
                            fontSize: VboxTypography.s12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_allSelected) {
                        _selectedIndices.clear();
                      } else {
                        _selectedIndices
                          ..clear()
                          ..addAll(Iterable<int>.generate(total));
                      }
                    }),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.primary,
                      textStyle: const TextStyle(
                        fontSize: VboxTypography.s14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    child: Text(_allSelected ? '取消全选' : '全选'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  VboxSpacing.lg,
                  0,
                  VboxSpacing.lg,
                  VboxSpacing.xxl,
                ),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: VboxSpacing.sm,
                    crossAxisSpacing: VboxSpacing.sm,
                    childAspectRatio: 2.4,
                  ),
                  itemCount: total,
                  itemBuilder: (BuildContext context, int index) {
                    return _downloadCell(scheme, widget.episodes[index], index);
                  },
                ),
              ),
            ),
            Padding(
              padding: VboxSpacing.symmetric(
                horizontal: VboxSpacing.lg,
                vertical: VboxSpacing.sm,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: selected == 0
                      ? null
                      : () => Navigator.of(context).pop(
                            _selectedIndices.toList()..sort(),
                          ),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    disabledBackgroundColor: scheme.onSurface.withValues(
                      alpha: 0.12,
                    ),
                    disabledForegroundColor: scheme.onSurfaceVariant,
                    textStyle: const TextStyle(
                      fontSize: VboxTypography.s16,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text('下载选中($selected)'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadCell(ColorScheme scheme, FuliEpisode ep, int index) {
    final bool isSelected = _selectedIndices.contains(index);
    return Material(
      color: isSelected
          ? scheme.primary
          : scheme.onSurface.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(VboxRadii.r8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() {
          if (isSelected) {
            _selectedIndices.remove(index);
          } else {
            _selectedIndices.add(index);
          }
        }),
        child: Center(
          child: Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.xs),
            child: Text(
              ep.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? Colors.white
                    : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
