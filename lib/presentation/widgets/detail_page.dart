/// 详情页：全屏封面背景 + 可滚动内容层（对齐 iOS `VideoDetailView`）。
///
/// 对齐 iOS `VideoDetailView`（`vbox/Views/PlayerViews.swift#L35` / 背景层 L1150 /
/// 内容层 L1192）：
/// - **双层结构**：底层全屏铺满封面（TMDB poster/backdrop 优先，回退豆瓣站点封面）
///   并叠加自 45% 高度起的黑色渐暗遮罩；上层为安全区内可滚动内容；
/// - 内容序：片名/logo + 剧情标签行 → 「立即播放」胶囊按钮 → 演职人员（分类 tab +
///   60×90 小方头像卡横滑）→ 剧情简介（含收藏心形）→ 线路 chips → 剧集宫格；
/// - 剧集宫格对齐 iOS `episodeSection`：标题 + 排序（倒序）+ 集数 + 宫格展开弹窗
///   （`EpisodeExpandPopup`：下载多选模式 / 全选 / 确认批量下载）。
///
/// 数据通路：[DetailPlaybackUseCases].loadDetail / resolvePlayUrl；
/// 封面 / 演职增强：[TmdbUseCases].enrich（G-06，未启用或未命中时回退站点数据）；
/// 收藏 / 历史：[FavoriteUseCases] / [HistoryUseCases]（全局 Provider 注入）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../core/utils/time_utils.dart';
import '../../data/datasources/local/cloud_drive_sort_store.dart';
import '../../data/datasources/local/prefs_manager.dart';
import '../../data/models/download.dart';
import '../../domain/entities/cloud/cloud_drive.dart';
import '../../domain/entities/cloud/cloud_play_item.dart';
import '../../domain/entities/cloud/node_pan.dart';
import '../../domain/entities/cloud/vbox_fragment.dart';
import '../../domain/entities/douban/douban_models.dart';
import '../../domain/entities/library/library.dart';
import '../../domain/entities/player/player.dart';
import '../../domain/entities/playback/playback.dart';
import '../../domain/entities/spider/spider_models.dart';
import '../../domain/entities/tmdb/tmdb_models.dart';
import '../../domain/usecases/usecases.dart';
import '../../platform/download/download.dart';
import '../../platform/player/drive_error_mapper.dart';
import '../../platform/player/pan_player.dart';
import '../../platform/player/playback_route.dart';
import '../pages/cloud/files.dart';
import '../pages/player/player_page.dart';
import '../theme/tokens/colors.dart';
import '../theme/tokens/radii.dart';
import '../theme/tokens/typography.dart';
import 'download/download_overlay_widgets.dart';
import 'platform_async_image.dart';

/// 详情页。
class DetailPage extends StatefulWidget {
  /// 构造。
  const DetailPage({
    super.key,
    required this.siteKey,
    required this.vodId,
    this.initialIndex = 0,
    this.title,
    this.isFromSourceDiscovery = false,
  });

  /// 站点 key（收藏/历史条目的 laiyuan）。
  final String siteKey;

  /// 影片 ID（收藏/历史条目的 detailurl）。
  final String vodId;

  /// 默认选中的剧集索引（历史续播入口；钳制到合法区间）。
  final int initialIndex;

  /// 页面标题（缺省用详情名）。
  final String? title;

  /// 是否由「源发现」页进入（对齐 iOS `isFromSourceDiscovery`）。
  ///
  /// 为真时启用**沉浸式**观感：隐藏 AppBar（`navigationBarHidden`），
  /// 顶部保留系统返回热区（对齐 iOS `edgeSwipeBack`）。
  final bool isFromSourceDiscovery;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final DetailPlaybackUseCases _uc;
  PlaybackDetail? _detail;

  /// 下载管理弹窗是否打开（对齐 iOS `showDownloadPopup`：弹窗显示时
  /// 隐藏悬浮下载按键）。
  bool _downloadPopupOpen = false;

  /// TMDB 用例（G-06；宿主未装配时为 null → 跳过增强，回退站点数据）。
  TmdbUseCases? _tmdbUc;

  /// 收藏 / 历史用例（宿主未装配时为 null → 静默跳过）。
  FavoriteUseCases? _favUc;
  HistoryUseCases? _histUc;

  /// 豆瓣用例（演职兜底；宿主未装配时为 null → 跳过）。
  DoubanUseCases? _doubanUc;

  /// TMDB 增强结果（封面 / 演职）。
  TmdbEnrichment? _tmdb;

  /// 豆瓣演职兜底（对齐 iOS `loadDoubanData`：TMDB 无演职 / 关闭时回退豆瓣）。
  DoubanCredits? _doubanCredits;

  /// 豆瓣大封面（竖版剧照；仅当无 TMDB 封面时作为背景兜底，对齐 iOS
  /// `doubanBackdropURL`）。
  String? _doubanBackdropUrl;

  Failure? _error;
  bool _loaded = false;
  bool _playing = false;
  bool _favorite = false;
  int _fromIndex = 0;
  int _episodeIndex = 0;
  bool _episodesReversed = false;
  String _castTab = '全部';

  /// 观看记录写入节流时间戳（毫秒；对齐 iOS 5s 节流）。
  int _lastHistoryWriteMs = 0;

  // ─────────────── 网盘（对齐 iOS panSection / driveExpandStates）───────────────

  /// 网盘播放编排（详情页内联展开 / 取链播放）。
  final PanPlayer _pan = PanPlayer();

  /// 原始网盘链接（已按网盘排序顺序排列，对齐 iOS `rawCloudLinks`）。
  final List<_RawCloudLink> _rawCloudLinks = <_RawCloudLink>[];

  /// 每个网盘的展开状态（对齐 iOS `driveExpandStates`）。
  final Map<String, _DriveExpandState> _driveExpandStates =
      <String, _DriveExpandState>{};

  /// 当前选中的网盘（对齐 iOS `selectedCloudDrive`）。
  String? _selectedCloudDrive;

  /// 网盘链接加载中（对齐 iOS `isLoadingPan`）。
  bool _isLoadingPan = false;

  @override
  void initState() {
    super.initState();
    // 用例引用在 initState 缓存，避免跨 async gap 使用 context
    _uc = context.read<DetailPlaybackUseCases>();
    _tmdbUc = _tryRead<TmdbUseCases>();
    _favUc = _tryRead<FavoriteUseCases>();
    _histUc = _tryRead<HistoryUseCases>();
    _doubanUc = _tryRead<DoubanUseCases>();
    _load();
  }

  /// 读取可选 Provider（宿主未装配时返回 null）。
  T? _tryRead<T>() {
    try {
      return context.read<T>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final Result<PlaybackDetail> result = await _uc.loadDetail(
      siteKey: widget.siteKey,
      vodId: widget.vodId,
      initialIndex: widget.initialIndex,
    );
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _error = result.failureOrNull;
      _detail = result.valueOrNull;
    });
    _applyInitialSelection();
    if (_detail != null) {
      // 详情就绪后异步拉取 TMDB 增强（对齐 iOS `loadTMDBData`，不阻塞首屏）。
      unawaited(_loadTmdb());
      unawaited(_checkFavorite());
      // 云源（☁️）→ 内联加载网盘源区块（对齐 iOS `onAppear` 的 `loadPanLinks`）。
      if (_isCloudVideo) unawaited(_loadPanLinks());
    }
  }

  /// 是否云源（对齐 iOS `isCloudVideo`：`vod_remarks` 以 `☁️` 开头）。
  bool get _isCloudVideo => _detail?.vod.vodRemarks?.startsWith('☁️') ?? false;

  /// TMDB 详情增强（对齐 iOS `VideoDetailView.loadTMDBData`）。
  ///
  /// 未启用 / 未配置代理 / 无匹配 / 请求失败 → 保持 null，UI 回退站点数据。
  Future<void> _loadTmdb() async {
    final TmdbUseCases? uc = _tmdbUc;
    final PlaybackDetail? d = _detail;
    if (uc == null || d == null) {
      unawaited(_loadDouban());
      return;
    }
    final Result<TmdbEnrichment?> result = await uc.enrich(
      name: d.vod.vodName,
      year: d.vod.vodYear,
    );
    if (!mounted) return;
    final TmdbEnrichment? enrichment = result.valueOrNull;
    if (enrichment != null && !enrichment.isEmpty) {
      setState(() => _tmdb = enrichment);
    }
    // 对齐 iOS：TMDB 无演职（或无大封面）时回退豆瓣演职 / 大封面。
    final bool hasTmdbCredits = enrichment?.hasCredits ?? false;
    if (!hasTmdbCredits) unawaited(_loadDouban());
  }

  /// 豆瓣演职兜底（对齐 iOS `loadDoubanData`：仅当 TMDB 未拿到演职时才写入，
  /// 避免覆盖 TMDB 数据；并补拉竖版大封面作为背景兜底）。
  Future<void> _loadDouban() async {
    final DoubanUseCases? uc = _doubanUc;
    final PlaybackDetail? d = _detail;
    if (uc == null || d == null) return;
    final Result<DoubanCredits> result = await uc.credits(d.vod.vodName);
    if (!mounted) return;
    final DoubanCredits? credits = result.valueOrNull;
    if (credits == null || credits.isEmpty) return;

    // 仅当 TMDB 未拿到演职时才写入（对齐 iOS `loadDoubanData` 的
    // `actors.isEmpty && directors.isEmpty && writers.isEmpty` 判定 —— iOS 的
    // actors 只由 TMDB / 豆瓣填充；此前误用 `_castData` 判定，站点演员文本
    // 恒非空导致豆瓣演职**永不写入** → 头像不显示、只剩无名氏文本卡）。
    if (_tmdb?.hasCredits ?? false) return;

    // 有 subjectId 时补拉竖版大封面（对齐 iOS `fetchWallpaperURL`）。
    String? backdrop;
    final String? subjectId = credits.subjectId;
    if (subjectId != null && subjectId.isNotEmpty) {
      final Result<String?> wallpaper = await uc.wallpaper(subjectId);
      backdrop = wallpaper.valueOrNull;
    }
    if (!mounted) return;
    setState(() {
      _doubanCredits = credits;
      // 仅当没有 TMDB 大封面时才写入豆瓣封面（对齐 iOS `tmdbPosterURL == nil
      // && tmdbBackdropURL == nil` 判定）。
      if ((_tmdb?.posterUrl ?? '').isEmpty &&
          (_tmdb?.backdropUrl ?? '').isEmpty) {
        _doubanBackdropUrl = backdrop;
      }
    });
  }

  /// 初始剧集索引 → 线路索引 + 线路内剧集索引。
  void _applyInitialSelection() {
    final PlaybackDetail? d = _detail;
    if (d == null) return;
    if (d.froms.isEmpty || d.episodes.isEmpty) {
      _fromIndex = 0;
      _episodeIndex = d.initialIndex;
      return;
    }
    final int flat = d.initialIndex.clamp(0, d.episodes.length - 1);
    final PlaybackEpisode target = d.episodes[flat];
    final int line = d.froms.indexOf(target.from ?? '');
    final int fromIdx = line < 0 ? 0 : line;
    final List<PlaybackEpisode> visible = _episodesForLine(fromIdx);
    _fromIndex = fromIdx;
    _episodeIndex = visible.indexWhere(
      (PlaybackEpisode e) => e.url == target.url && e.name == target.name,
    );
    if (_episodeIndex < 0) _episodeIndex = 0;
  }

  /// 指定线路的剧集（无线路信息时返回全集）。
  List<PlaybackEpisode> _episodesForLine(int lineIndex) {
    final PlaybackDetail? d = _detail;
    if (d == null) return const <PlaybackEpisode>[];
    if (d.froms.isEmpty) return d.episodes;
    final String from = d.froms[lineIndex.clamp(0, d.froms.length - 1)];
    final List<PlaybackEpisode> out =
        d.episodes.where((PlaybackEpisode e) => e.from == from).toList();
    return out.isEmpty ? d.episodes : out;
  }

  // ─────────────── 收藏 / 历史 ───────────────

  /// 读取收藏态（对齐 iOS `checkFavorite`）。
  Future<void> _checkFavorite() async {
    final FavoriteUseCases? uc = _favUc;
    if (uc == null) return;
    final Result<bool> result = await uc.isFavorite(widget.vodId);
    if (!mounted) return;
    setState(() => _favorite = result.valueOrNull ?? false);
  }

  /// 切换收藏（对齐 iOS `toggleFavorite`）。
  Future<void> _toggleFavorite() async {
    final FavoriteUseCases? uc = _favUc;
    final PlaybackDetail? d = _detail;
    if (uc == null || d == null) return;
    final Result<bool> result = await uc.toggle(
      FavoriteItem(
        name: d.vod.vodName,
        laiyuan: widget.siteKey,
        imgurl: d.vod.vodPic,
        detailurl: widget.vodId,
        xianlu: _fromIndex,
        jishu: _episodeIndex,
        addedAt: TimeUtils.nowUnixSeconds(),
      ),
    );
    if (!mounted) return;
    final Failure? failure = result.failureOrNull;
    if (failure != null) {
      _toast('收藏操作失败：$failure');
      return;
    }
    final bool now = result.valueOrNull ?? false;
    setState(() => _favorite = now);
    _toast(now ? '已加入收藏' : '已取消收藏');
  }

  /// 写入观看记录（对齐 iOS 播放开始 / 进度 >5s 落库）。
  Future<void> _recordHistory({double progress = 0}) async {
    final HistoryUseCases? uc = _histUc;
    final PlaybackDetail? d = _detail;
    if (uc == null || d == null) return;
    await uc.record(
      HistoryItem(
        name: d.vod.vodName,
        laiyuan: widget.siteKey,
        imgurl: d.vod.vodPic,
        detailurl: widget.vodId,
        xianlu: _fromIndex,
        jishu: _episodeIndex,
        progress: progress,
        lastPlayedAt: TimeUtils.nowUnixSeconds(),
      ),
    );
  }

  /// 播放进度回调（对齐 iOS：进度 >5s 且距上次落库 >5s 才写入）。
  void _onPlaybackProgress(PlaybackProgress p) {
    if (p.durationMs <= 0 || p.positionMs < 5000) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastHistoryWriteMs < 5000) return;
    _lastHistoryWriteMs = now;
    final double progress = (p.positionMs / p.durationMs).clamp(0.0, 1.0);
    unawaited(_recordHistory(progress: progress));
  }

  // ─────────────── 播放 ───────────────

  Future<void> _playEpisode(PlaybackEpisode episode) async {
    final List<PlaybackEpisode> visible = _episodesForLine(_fromIndex);
    final int index = visible.indexWhere(
      (PlaybackEpisode e) => e.url == episode.url && e.name == episode.name,
    );
    if (index >= 0) setState(() => _episodeIndex = index);
    await _play();
  }

  Future<void> _play() async {
    final PlaybackDetail? d = _detail;
    if (d == null || _playing) return;

    // 云源（☁️）→ 播首个网盘的第一集（对齐 iOS `handlePlay` 的 isCloudVideo 分支）；
    // 尚未加载完且无原始链接 → 触发网盘源加载。
    if (_isCloudVideo) {
      if (_rawCloudLinks.isEmpty) {
        if (!_isLoadingPan) unawaited(_loadPanLinks());
        return;
      }
      final String drive = _selectedCloudDrive ?? _firstCloudDriveName ?? '';
      final List<_CloudPanLink> links = _linksForDrive(drive);
      if (links.isEmpty) {
        _toast('暂无可播放的网盘条目');
        return;
      }
      await _playPanLink(links.first);
      return;
    }

    final List<PlaybackEpisode> visible = _episodesForLine(_fromIndex);
    if (visible.isEmpty) return;
    final PlaybackEpisode episode =
        visible[_episodeIndex.clamp(0, visible.length - 1)];

    // F-P07：网盘分享链接 → 走网盘文件列表（分享模式）选集播放。
    final CloudDriveType? drive = CloudDriveType.fromShareUrl(episode.url);
    if (drive != null) {
      await _openCloudFiles(drive, episode.url);
      return;
    }

    setState(() => _playing = true);
    try {
      // 播放开始即写入观看记录（对齐 iOS 播放启动落库）。
      unawaited(_recordHistory());

      if (!mounted) return;
      // 问题4：先 push 播放器（立即呈现，含加载态），解析下沉到播放器内
      // （对齐 iOS 先 present 后 resolve），消除可感知的等待空窗。
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PlayerPage(
            title: d.vod.vodName,
            subtitle: episode.name,
            vodId: d.vod.vodId,
            episodes: visible,
            initialEpisodeIndex: _episodeIndex.clamp(0, visible.length - 1),
            onResolveEpisode: _resolveEpisodeSource,
            onResolveInitialSource: () => _resolveEpisodeSource(episode),
            onProgress: _onPlaybackProgress,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('播放失败：$e');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  /// 打开网盘文件列表（分享模式）选集播放（对齐 iOS 播放器 `handleDriveUrl`）。
  Future<void> _openCloudFiles(CloudDriveType type, String shareUrl) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => CloudDriveFilesPage(
          driveType: type,
          shareUrl: shareUrl,
          panPlayer: PanPlayer(),
        ),
      ),
    );
  }

  /// 选集重开解析器（Wave A · R-渲2）：单集 → 播放源（复用 [DetailPlaybackUseCases]）。
  Future<PlayerSource?> _resolveEpisodeSource(PlaybackEpisode episode) async {
    final PlaybackDetail? d = _detail;
    if (d == null) return null;
    final Result<PlayerContentResult> result =
        await _uc.resolvePlayUrl(detail: d, episode: episode);
    final PlayerContentResult? pc = result.valueOrNull;
    final String? url = _firstUrl(pc);
    if (url == null || url.isEmpty) return null;
    return PlayerSource(
      url: url,
      title: d.vod.vodName,
      headers: pc?.header ?? const <String, String>{},
    );
  }

  String? _firstUrl(PlayerContentResult? pc) {
    if (pc == null) return null;
    final String? u = pc.url;
    if (u != null && u.isNotEmpty) return u;
    if (pc.urls != null && pc.urls!.isNotEmpty) return pc.urls!.first;
    final String? pu = pc.playUrl;
    if (pu != null && pu.isNotEmpty) return pu;
    return null;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ─────────────── 下载 ───────────────

  /// 下载接线（G-02 / P2b）：逐集解析真实地址 → 建 [Download] 记录 → 交
  /// [DownloadManager] 入队（对齐 iOS `VideoDetailView.handleBatchDownload`）。
  ///
  /// 云源（☁️）→ `episode.url`（带 vbox 定位 fragment 的分享链）直接入队
  /// `sourceType: 'cloud'`，**执行时**由 [CloudDownloadUrlResolver] 取链
  /// （对齐 iOS L920 `isCloudVideo ? "cloud" : "normal"` + L243
  /// `resolveCloudDriveURL`：定位 token 有时效性，入队不解析）；
  /// 非云源 → 维持蜘蛛链路入队前预解析（Flutter 侧现行实现）。
  Future<void> _enqueueDownloads(List<PlaybackEpisode> episodes) async {
    final PlaybackDetail? d = _detail;
    if (d == null || episodes.isEmpty) return;
    final DownloadManager manager = context.read<DownloadManager>();
    final List<PlaybackEpisode> visible = _episodesForLine(_fromIndex);
    final bool cloud = _isCloudVideo;

    int added = 0;
    final List<String> failed = <String>[];
    for (int i = 0; i < episodes.length; i++) {
      final PlaybackEpisode episode = episodes[i];
      final int original = visible.indexWhere((PlaybackEpisode e) =>
          e.url == episode.url && e.name == episode.name);
      final int jishu = original >= 0 ? original + 1 : i + 1;
      final String label = episode.name.isEmpty ? '第$jishu集' : episode.name;

      if (cloud) {
        await manager.enqueue(
          Download(
            name: '${d.vod.vodName} $label',
            laiyuan: d.site.name,
            imgurl: d.vod.vodPic,
            detailurl: widget.vodId,
            playurl: episode.url,
            jishu: jishu,
            addedAt: TimeUtils.nowUnixSeconds(),
            sourceType: 'cloud',
            vodId: widget.vodId,
          ),
        );
        added++;
        continue;
      }

      final Result<PlayerContentResult> result =
          await _uc.resolvePlayUrl(detail: d, episode: episode);
      final PlayerContentResult? pc = result.valueOrNull;
      final String? url = _firstUrl(pc);
      if (url == null || url.isEmpty) {
        failed.add(label);
        continue;
      }

      final String headers = jsonEncode(pc?.header ?? const <String, String>{});
      await manager.enqueue(
        Download(
          name: '${d.vod.vodName} $label',
          laiyuan: d.site.name,
          imgurl: d.vod.vodPic,
          detailurl: widget.vodId,
          playurl: url,
          jishu: jishu,
          addedAt: TimeUtils.nowUnixSeconds(),
          sourceType: 'normal',
          engineKey: d.vod.engineKey,
          vodId: widget.vodId,
          headers: headers,
        ),
      );
      added++;
    }

    if (!mounted) return;
    if (added > 0 && failed.isEmpty) {
      _toast('已添加 $added 集到下载');
    } else if (added > 0) {
      _toast('已添加 $added 集到下载，${failed.length} 集解析失败已跳过');
    } else {
      _toast('${failed.length} 集解析失败，未添加下载');
    }
  }

  // ─────────────── 剧集弹窗 ───────────────

  /// 展开弹窗标题（对齐 iOS `expandedEpisodeTitle` L174-185）：
  /// 云源 → `<当前网盘> 剧集列表`；非云源 → `<线路名> 剧集列表`；
  /// 名称缺失 → `剧集列表`。
  String _expandedEpisodeTitle(PlaybackDetail d) {
    if (_isCloudVideo) {
      final String drive =
          _selectedCloudDrive ?? _firstCloudDriveName ?? '网盘资源';
      return '$drive 剧集列表';
    }
    if (d.froms.isEmpty) return '剧集列表';
    final String name = d.froms[_fromIndex.clamp(0, d.froms.length - 1)];
    return name.isEmpty ? '剧集列表' : '$name 剧集列表';
  }

  /// 首个网盘名（对齐 iOS `cloudDriveGroups.first?.drive`）。
  String? get _firstCloudDriveName {
    for (final _RawCloudLink link in _rawCloudLinks) {
      return link.driveName;
    }
    return null;
  }

  /// 当前选中网盘的剧集项（云源；对齐 iOS `expandedEpisodeItems` 的云分支）。
  ///
  /// 返回合成 [PlaybackEpisode]（`url` = 带 fragment 的条目地址，供播放时定位）。
  List<PlaybackEpisode> _cloudEpisodesForPopup() {
    final String? drive = _selectedCloudDrive ?? _firstCloudDriveName;
    if (drive == null) return const <PlaybackEpisode>[];
    final List<_CloudPanLink> links = _linksForDrive(drive);
    // 先按**原序**构建（保证各盘 fileIndex 对齐 iOS「文件列表内序号」），
    // 再按需整体倒序展示，避免倒序后下标与文件列表错位。
    final List<PlaybackEpisode> built = <PlaybackEpisode>[
      for (int i = 0; i < links.length; i++) _cloudEpisodeOf(links[i], i),
    ];
    return _episodesReversed ? built.reversed.toList(growable: false) : built;
  }

  /// 云源剧集项（F-P06：携带 `sourceType` / 各盘定位字段 / Node 字段，
  /// 对齐 iOS `expandedEpisodeItems` 的云分支 `EpisodeItem`）。
  ///
  /// [index] 为该条目在**当前网盘链接列表中的原序下标**，对齐 iOS
  /// `EpisodeItem.baiduFileIndex = idx` / `quarkFileIndex = idx` 的语义。
  PlaybackEpisode _cloudEpisodeOf(_CloudPanLink link, int index) {
    final CloudDriveType? type = link.driveType;
    final bool nodeManaged = type != null && NodePanRouting.isNodeManaged(type);
    final VboxFragment fragment = VboxFragmentCodec.split(link.url).params;
    return PlaybackEpisode(
      name: _cloudEpisodeTitle(link, index),
      url: link.url,
      sourceType: EpisodeSourceType.fromDriveType(type),
      // Node 托管盘：fragment 的 vbox_node 即条目 playID。
      nodePlayID: nodeManaged ? fragment.node : null,
      nodeDriveType: nodeManaged ? type : null,
      // 原生盘定位字段（与 [_locateParams] 生成的 fragment 一一对应）：
      // 夸克 / 百度 → 文件列表序号；UC / 阿里 → `vbox_fid`；
      // 迅雷 / 123 / 189 → `vbox_fileId`；115 → `vbox_pickcode`；139 → `vbox_contentId`。
      baiduFileIndex: type == CloudDriveType.baidu ? index : null,
      quarkFileIndex: type == CloudDriveType.quark ? index : null,
      ucFileFid: type == CloudDriveType.uc ? fragment.fid : null,
      aliFileId: type == CloudDriveType.ali ? fragment.fid : null,
      xunleiFileId: type == CloudDriveType.xunlei ? fragment.fileId : null,
      one15PickCode: type == CloudDriveType.one15 ? fragment.pickcode : null,
      pan123FileId: type == CloudDriveType.pan123 ? fragment.fileId : null,
      pan189FileId: type == CloudDriveType.pan189 ? fragment.fileId : null,
      pan139ContentId:
          type == CloudDriveType.pan139 ? fragment.contentId : null,
    );
  }

  /// 指定网盘当前展开的条目（未展开时用原始链接占位）。
  List<_CloudPanLink> _linksForDrive(String drive) {
    final _DriveExpandState? state = _driveExpandStates[drive];
    if (state != null && state.kind == _DriveExpandKind.loaded) {
      return state.links;
    }
    return _fallbackLinks(
      drive,
      _rawCloudLinks
          .where((_RawCloudLink l) => l.driveName == drive)
          .toList(growable: false),
    );
  }

  /// 未展开 / 展开失败时的占位条目（对齐 iOS `cloudDriveGroups` 的 fallback 分支）。
  List<_CloudPanLink> _fallbackLinks(String drive, List<_RawCloudLink> raw) =>
      <_CloudPanLink>[
        for (int i = 0; i < raw.length; i++)
          _makeCloudPanLink(
            url: raw[i].url,
            name: raw[i].name,
            driveType: raw[i].driveType,
            driveName: drive,
            index: i,
          ),
      ];

  /// 网盘分组（去重保序；对齐 iOS `cloudDriveGroups` 的 `orderedDrives`）。
  List<String> get _cloudDriveNames {
    final List<String> out = <String>[];
    for (final _RawCloudLink link in _rawCloudLinks) {
      if (!out.contains(link.driveName)) out.add(link.driveName);
    }
    return out;
  }

  /// 云源剧集标题（对齐 iOS `cloudEpisodeTitle`：剥掉网盘名后缀，空则「第 N 集」）。
  String _cloudEpisodeTitle(_CloudPanLink link, int index) {
    final String drive = link.driveName;
    String cleaned = link.name
        .replaceAll(drive, '')
        .replaceAll('网盘', '')
        .replaceAll('云盘', '')
        .replaceAll('·', '')
        .trim();
    if (cleaned.isEmpty) cleaned = link.name.trim();
    return cleaned.isEmpty ? '第${index + 1}集' : cleaned;
  }

  /// 网盘条目 id（对齐 iOS `makeCloudPanLink` 的 `driveName|index|name|url`）。
  _CloudPanLink _makeCloudPanLink({
    required String url,
    required String name,
    required CloudDriveType? driveType,
    required String driveName,
    required int index,
  }) =>
      _CloudPanLink(
        id: '$driveName|$index|$name|$url',
        url: url,
        name: name,
        driveType: driveType,
        driveName: driveName,
      );

  // ─────────────── 网盘源加载（对齐 iOS `loadPanLinks`）───────────────

  /// 内联加载网盘源：识别盘别 → 派生 Node 路链 → 排序 → 逐个网盘展开文件列表。
  ///
  /// 与 iOS 的差异：iOS 由 `video.vodId` 二次 `resolveCloudPlay` 取原始链接；
  /// Flutter 端 [DetailPlaybackUseCases.loadDetail] 已把同一结果落到
  /// `d.episodes`（`name$shareUrl`），故直接复用，避免重复网络请求。
  Future<void> _loadPanLinks() async {
    final PlaybackDetail? d = _detail;
    if (d == null) return;
    if (_rawCloudLinks.isNotEmpty || _isLoadingPan) return;
    setState(() => _isLoadingPan = true);

    try {
      // ① 预处理：识别盘别 + 派生 Node 路链（对齐 iOS `loadPanLinks` step 1-2）。
      final List<_RawCloudLink> split = <_RawCloudLink>[];
      for (final PlaybackEpisode e in d.episodes) {
        final String url = e.url;
        final CloudDriveType? dt = CloudDriveType.fromShareUrl(url);
        final String driveName = dt?.displayName ?? _driveNameFromLink(e.name);
        split.add(_RawCloudLink(
          url: url,
          name: e.name,
          driveType: dt,
          driveName: driveName,
        ));
        if (dt == CloudDriveType.quark) {
          split.add(_RawCloudLink(
            url: url,
            name: e.name,
            driveType: dt,
            driveName: '备用夸克',
          ));
          split.add(_RawCloudLink(
            url: VboxFragmentCodec.appendNodeMark(url),
            name: e.name,
            driveType: CloudDriveType.quarkNode,
            driveName: '夸克Node',
          ));
        }
        if (dt == CloudDriveType.uc) {
          split.add(_RawCloudLink(
            url: VboxFragmentCodec.appendNodeMark(url),
            name: e.name,
            driveType: CloudDriveType.ucNode,
            driveName: 'UC网盘Node',
          ));
        }
        if (dt == CloudDriveType.baidu) {
          split.add(_RawCloudLink(
            url: VboxFragmentCodec.appendNodeMark(url),
            name: e.name,
            driveType: CloudDriveType.baiduNode,
            driveName: '百度网盘Node',
          ));
        }
      }

      // ② 按网盘排序顺序排列（对齐 iOS `sortRawCloudLinks`）。
      final List<CloudDriveType> order =
          await CloudDriveSortStore(PrefsManager.instance).order();
      final List<_RawCloudLink> sorted = _sortRawCloudLinks(split, order);
      if (!mounted) return;
      setState(() {
        _rawCloudLinks
          ..clear()
          ..addAll(sorted);
        for (final String drive in _cloudDriveNames) {
          _driveExpandStates[drive] = _DriveExpandState.loading;
        }
      });

      // ③ 按网盘分组，首个同步展开，其余后台预加载（对齐 iOS step 2-4）。
      final List<(String, List<_RawCloudLink>)> grouped =
          _groupRawCloudLinks(sorted);
      if (grouped.isEmpty) {
        if (mounted) setState(() => _isLoadingPan = false);
        return;
      }
      final _DriveExpandState first =
          await _expandSingleDrive(grouped.first.$1, grouped.first.$2);
      if (!mounted) return;
      setState(() {
        _driveExpandStates[grouped.first.$1] = first;
        _isLoadingPan = false;
        _selectedCloudDrive ??= grouped.first.$1;
      });
      for (final (String drive, List<_RawCloudLink> links) in grouped.skip(1)) {
        final _DriveExpandState state = await _expandSingleDrive(drive, links);
        if (!mounted) return;
        setState(() => _driveExpandStates[drive] = state);
      }
    } finally {
      if (mounted && _isLoadingPan) setState(() => _isLoadingPan = false);
    }
  }

  /// 原始链接排序（对齐 iOS `sortRawCloudLinks`：位次升序，同序按名称）。
  List<_RawCloudLink> _sortRawCloudLinks(
    List<_RawCloudLink> links,
    List<CloudDriveType> order,
  ) {
    final List<_RawCloudLink> sorted = List<_RawCloudLink>.of(links);
    sorted.sort((_RawCloudLink a, _RawCloudLink b) {
      final int la = _sortIndex(a, order);
      final int lb = _sortIndex(b, order);
      if (la != lb) return la.compareTo(lb);
      return a.driveName.compareTo(b.driveName);
    });
    return sorted;
  }

  /// 排序位次（对齐 iOS `sortIndex`：Node 派生盘紧跟其原生盘）。
  int _sortIndex(_RawCloudLink link, List<CloudDriveType> order) {
    int baseOf(CloudDriveType t) {
      final int i = order.indexOf(t);
      return i < 0 ? order.length : i;
    }

    switch (link.driveName) {
      case '备用夸克':
        return baseOf(CloudDriveType.quark) + 1;
      case '夸克Node':
        return baseOf(CloudDriveType.quark) + 2;
      case 'UC网盘Node':
        return baseOf(CloudDriveType.uc) + 1;
      case '百度网盘Node':
        return baseOf(CloudDriveType.baidu) + 1;
    }
    final CloudDriveType? dt = link.driveType;
    if (dt != null) return baseOf(dt);
    return order.length;
  }

  /// 按网盘名分组（保序；对齐 iOS `groupRawLinks`）。
  List<(String, List<_RawCloudLink>)> _groupRawCloudLinks(
    List<_RawCloudLink> links,
  ) {
    final List<(String, List<_RawCloudLink>)> groups =
        <(String, List<_RawCloudLink>)>[];
    final Set<String> seen = <String>{};
    for (final _RawCloudLink link in links) {
      if (!seen.contains(link.driveName)) {
        seen.add(link.driveName);
        groups.add((link.driveName, <_RawCloudLink>[]));
      }
      groups.last.$2.add(link);
    }
    return groups;
  }

  /// 展开单个网盘的文件列表（对齐 iOS `expandSingleDrive`）。
  ///
  /// 逐盘生成 fragment 定位键（对齐 iOS `expandSingleDrive` 的**可达**分支）：
  /// - Node 托管盘（115/123/139/189/迅雷/光鸭/蜗牛/夸克Node/UCNode/百度Node）
  ///   → `vbox_node=<playID>`（iOS 首个 case 即归 Node，优先于原生分支）；
  /// - 夸克原生 → `vbox_fid=<fid>`（+ `vbox_route`）/ 备用夸克走 `transcode`；
  /// - 百度原生 → `vbox_fsid=<fsId>`；
  /// - UC 原生 → `vbox_fid=<fid>`；
  /// - 阿里 → `vbox_fid=<fileId>`。
  ///
  /// 说明一：iOS 另有 `vbox_pickcode`（115）/ `vbox_fileId`（123/189）/
  /// `vbox_contentId`（139）三键，但均落在 `isNodeManagedDrive` 首判之后，
  /// 属**不可达死分支**；且 Flutter 这些盘同样走 Node 链路（playID 为 base64
  /// 载荷，非原生 pickCode/fileId），故不产出这三键。
  ///
  /// 说明二：iOS V1 详情页（`PlayerViews.swift:590`）UC 分支另发
  /// `vbox_token=<shareFidToken>`，但 V2 播放器（`PlayerViewsV2.swift:3244-3262`）
  /// **不消费**该键 —— 它按 `vbox_fid` 命中后从本次重取的文件列表拿
  /// `targetFile.shareFidToken`。故 Flutter 仅发 `vbox_fid` 即与 V2 消费端一致；
  /// 若后续要逐字对齐 V1 的生成，随 F-P06 二批 `ucShareFidToken` 一并补齐。
  Future<_DriveExpandState> _expandSingleDrive(
    String driveName,
    List<_RawCloudLink> links,
  ) async {
    final CloudDriveType? driveType = links.first.driveType;
    if (driveType == null) {
      return _DriveExpandState.loaded(_fallbackLinks(driveName, links));
    }
    final List<_CloudPanLink> out = <_CloudPanLink>[];
    int failures = 0;
    for (final _RawCloudLink link in links) {
      // Node 派生盘链接带 `#vbox_nd=1` 标记，解析分享时须剥离 fragment
      // （对齐 iOS `resolveNodeShare` 内部 `splitVboxFragment` 的干净链接语义）。
      final String cleanShare = VboxFragmentCodec.strip(link.url);
      try {
        final NodePanShare share =
            await _pan.resolveShare(driveType, cleanShare);
        for (final NodePanEntry entry in share.entries) {
          out.add(_makeCloudPanLink(
            url: VboxFragmentCodec.append(
              link.url,
              _locateParams(driveType, entry.playID, driveName),
            ),
            name: entry.name,
            driveType: driveType,
            driveName: driveName,
            index: out.length,
          ));
        }
      } catch (e) {
        failures++;
        if (out.isEmpty && failures == links.length) {
          return _DriveExpandState.failed(
            '$driveName资源加载失败：${DriveErrorMapper.messageOf(e)}',
          );
        }
      }
    }
    return out.isEmpty
        ? _DriveExpandState.empty
        : _DriveExpandState.loaded(out);
  }

  /// 按盘别生成 F-P27 定位 fragment 参数（对齐 iOS 各 `expand*Drive` 分支）。
  Map<String, String> _locateParams(
    CloudDriveType type,
    String playID,
    String driveName,
  ) {
    switch (type) {
      case CloudDriveType.quarkNode:
      case CloudDriveType.ucNode:
      case CloudDriveType.baiduNode:
        return <String, String>{'vbox_node': playID};
      case CloudDriveType.quark:
        return <String, String>{
          'vbox_fid': playID,
          'vbox_route': driveName == '备用夸克' ? 'transcode' : 'original',
        };
      case CloudDriveType.baidu:
        return <String, String>{'vbox_fsid': playID};
      case CloudDriveType.uc:
        return <String, String>{'vbox_fid': playID};
      default:
        // Node 托管盘（115/123/139/189/迅雷/光鸭/蜗牛）→ playID 即 vbox_node。
        return NodePanRouting.isNodeManaged(type)
            ? <String, String>{'vbox_node': playID}
            : <String, String>{'vbox_fid': playID};
    }
  }

  /// 由链接名推断网盘名（对齐 iOS `driveNameFromLink`）。
  String _driveNameFromLink(String name) {
    if (name.contains('115')) return '115网盘';
    if (name.contains('阿里')) return '阿里云盘';
    if (name.contains('夸克')) return '夸克网盘';
    if (name.contains('百度')) return '百度网盘';
    if (name.contains('UC')) return 'UC网盘';
    if (name.contains('天翼')) return '天翼云盘';
    if (name.contains('123')) return '123云盘';
    return '其他网盘';
  }

  /// 播放网盘条目（对齐 iOS `playPanLink` → 播放器 `handleDriveUrl`）：
  /// 剥离 fragment 得干净分享链接 + 定位键 → 取链 → 全屏播放页（显式 pan 路由）。
  Future<void> _playPanLink(_CloudPanLink link) async {
    final PlaybackDetail? d = _detail;
    if (d == null) return;
    final VboxFragmentSplit split = VboxFragmentCodec.split(link.url);
    final CloudDriveType? type =
        link.driveType ?? VboxFragmentCodec.resolveShareType(link.url);
    if (type == null) {
      _toast('无法识别的网盘链接');
      return;
    }
    if (_playing) return;
    setState(() => _playing = true);
    try {
      // 播放开始即写入观看记录（对齐 iOS 播放启动落库）。
      unawaited(_recordHistory());
      if (!mounted) return;
      // 问题4：先 push 播放器（立即呈现，含加载态），取链下沉到播放器内
      // （对齐 iOS 先 present 后 resolve），消除可感知的等待空窗。
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PlayerPage(
            // 直链特征无法自证 pan 路由，显式传入（对齐 F-08）。
            route: PlaybackRoute.pan,
            title: d.vod.vodName,
            subtitle: link.name,
            vodId: d.vod.vodId,
            // 统一播放源落地（对齐 iOS 播放器取链后交引擎）：HLS 经 Go 代理注册 +
            // 携带 F21 兜底线路（原画 403 / 断连 / 首帧超时回落 m3u8）。
            onResolveInitialSource: () async {
              final CloudPlayItem item = await _pan.prepare(
                type: type,
                shareUrl: split.baseUrl,
                routePreference: split.params.route,
                entry: NodePanEntry(
                  playID: split.params.locateValue.isEmpty
                      ? link.name
                      : split.params.locateValue,
                  name: link.name,
                ),
              );
              if (!item.hasPlayURL) {
                throw const PanPlayException('播放地址为空');
              }
              return _pan.sourceFor(item, title: d.vod.vodName);
            },
            // UI-F16：网盘路径同样落库观看进度（此前缺失）。
            onProgress: _onPlaybackProgress,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('播放失败：${DriveErrorMapper.messageOf(e)}');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  /// 打开剧集展开弹窗（对齐 iOS `EpisodeExpandPopup`）。
  ///
  /// 云源（☁️）→ 弹窗内容为当前网盘的网盘条目，点击走 [PanPlayer] 取链播放；
  /// 非云源 → 线路剧集，点击走解析播放（对齐 iOS `handleExpandedEpisodeSelect`）。
  Future<void> _showEpisodePopup({bool downloadMode = false}) async {
    final PlaybackDetail? d = _detail;
    if (d == null) return;
    final bool cloud = _isCloudVideo;
    final List<PlaybackEpisode> episodes =
        cloud ? _cloudEpisodesForPopup() : _episodesForLine(_fromIndex);
    if (episodes.isEmpty) {
      _toast('暂无剧集');
      return;
    }
    // 下载模式对云源同样开放（对齐 iOS `EpisodeExpandPopup`：下载开关
    // 无条件显示，云源入队 `sourceType: "cloud"` 执行时取链）。
    final bool allowDownload = downloadMode;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.38),
      builder: (BuildContext ctx) => _EpisodeExpandDialog(
        title: _expandedEpisodeTitle(d),
        episodes: episodes,
        initialReversed: _episodesReversed,
        initialDownloadMode: allowDownload,
        onReversedChanged: (bool value) =>
            setState(() => _episodesReversed = value),
        onPlay: (PlaybackEpisode episode) {
          Navigator.of(ctx).pop();
          if (cloud) {
            unawaited(_playCloudEpisode(episode));
          } else {
            unawaited(_playEpisode(episode));
          }
        },
        onDownload: (List<PlaybackEpisode> list) {
          Navigator.of(ctx).pop();
          unawaited(_enqueueDownloads(list));
        },
      ),
    );
  }

  /// 播放云源弹窗中被点选的条目（按 `url` 回到对应网盘条目后取链）。
  Future<void> _playCloudEpisode(PlaybackEpisode episode) async {
    final String drive = _selectedCloudDrive ?? _firstCloudDriveName ?? '';
    for (final _CloudPanLink link in _linksForDrive(drive)) {
      if (link.url == episode.url) {
        await _playPanLink(link);
        return;
      }
    }
  }

  // ─────────────── UI ───────────────

  /// 打开下载管理弹窗（对齐 iOS `showDownloadPopup = true`：期间隐藏悬浮
  /// 按键，关闭后恢复）。
  Future<void> _openDownloadPopup() async {
    setState(() => _downloadPopupOpen = true);
    await showDownloadManagementPopup(context);
    if (!mounted) return;
    setState(() => _downloadPopupOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.title ?? _detail?.vod.vodName ?? '详情';
    // 沉浸式：由「源发现」页进入时隐藏 AppBar（对齐 iOS `navigationBarHidden`）。
    final bool immersive = widget.isFromSourceDiscovery;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: immersive
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              foregroundColor: Colors.white,
              title: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: VboxTypography.s18,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
      body: Stack(
        children: <Widget>[
          _buildBody(),
          // 沉浸式下 AppBar 隐藏，保留顶部返回热区（对齐 iOS `edgeSwipeBack`）。
          if (immersive) _buildImmersiveBackZone(),
          // 悬浮下载按键（详情页专用，对齐 iOS VideoDetailView L1061-L1069）：
          // shell 全局按键被详情页新路由遮挡，此处兜底挂载；管理弹窗打开时
          // 隐藏（对齐 iOS `!showDownloadPopup`），手动隐藏状态由按钮内部处理。
          if (!_downloadPopupOpen)
            Positioned.fill(
              child: FloatingVideoDownloadButton(onTap: _openDownloadPopup),
            ),
        ],
      ),
    );
  }

  /// 沉浸式返回热区（AppBar 隐藏时的兜底返回入口）。
  Widget _buildImmersiveBackZone() {
    return Positioned(
      top: 0,
      left: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final Failure? error = _error;
    if (error != null) {
      return _ErrorRetry(message: '$error', onRetry: _retry);
    }
    final PlaybackDetail? d = _detail;
    if (d == null) {
      return const Center(
        child: Text('详情为空', style: TextStyle(color: Colors.white70)),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height = constraints.maxHeight;
        return Stack(
          children: <Widget>[
            Positioned.fill(child: _buildBackground(d, height)),
            Positioned.fill(child: _buildContent(d, height)),
          ],
        );
      },
    );
  }

  void _retry() {
    setState(() {
      _loaded = false;
      _error = null;
      _detail = null;
      _tmdb = null;
    });
    _load();
  }

  /// 背景层（对齐 iOS `backgroundLayer` + `bottomDimmingOverlay`）。
  Widget _buildBackground(PlaybackDetail d, double height) {
    final String cover = _tmdb?.posterUrl ??
        _tmdb?.backdropUrl ??
        _doubanBackdropUrl ??
        d.vod.vodPic;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: Colors.black),
        if (cover.trim().isNotEmpty)
          PlatformAsyncImage(
            url: cover,
            fit: BoxFit.cover,
            placeholderColor: Colors.black,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            height: height * 0.55,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: VboxColors.detailCoverFadeGradient,
                stops: <double>[0.0, 0.35, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 内容滚动层（对齐 iOS `contentLayer`：顶部 30% 透明露出封面）。
  Widget _buildContent(PlaybackDetail d, double height) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(height: height * 0.30),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 60),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 20,
              children: <Widget>[
                _buildTitleBlock(d),
                _buildPlayButton(),
                _buildCast(d),
                _buildSynopsis(d),
                // 云源（☁️）→ 网盘源区块；非云源 → 剧集列表（对齐 iOS
                // `contentLayer`：`panSection` 后 `if !isCloudVideo { episodeSection }`）。
                _buildPanSection(),
                if (!_isCloudVideo) _buildEpisodeSection(d),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 片名 / logo / 剧情标签行（对齐 iOS `HeroTitleView` + 片名 + 剧情标签）。
  Widget _buildTitleBlock(PlaybackDetail d) {
    final VodItem vod = d.vod;
    final String? logo = _tmdb?.logoUrl;
    final bool hasLogo = logo != null && logo.isNotEmpty;
    final List<String> meta = <String>[
      if (vod.vodYear?.isNotEmpty ?? false) vod.vodYear!,
      if (vod.vodArea?.isNotEmpty ?? false) vod.vodArea!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 大标题（对齐 iOS `HeroTitleView`）：TMDB logo 优先，加载失败 / 无 logo
        // → 马善政毛笔楷体兜底（48pt 白字带阴影）。
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 70),
          child: hasLogo
              ? PlatformAsyncImage(
                  url: logo,
                  fit: BoxFit.contain,
                  placeholderColor: Colors.transparent,
                  errorBuilder: (_, __, ___) => _heroFallbackTitle(vod.vodName),
                )
              : _heroFallbackTitle(vod.vodName),
        ),
        const SizedBox(height: 12),
        Text(
          vod.vodName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: VboxTypography.s14,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: const Text(
                '剧情',
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  color: VboxColors.detailLabelText,
                ),
              ),
            ),
            if (meta.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  meta.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ],
            if (vod.vodRemarks?.isNotEmpty ?? false) ...<Widget>[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  vod.vodRemarks!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Hero 大标题兜底（对齐 iOS `HeroTitleView.fallbackTitle`）：
  /// 马善政毛笔楷体 48pt 白字 + 黑色阴影。
  Widget _heroFallbackTitle(String name) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: VboxTypography.heroFontFamily,
        fontSize: VboxTypography.heroTitle,
        color: Colors.white,
        shadows: <Shadow>[
          Shadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }

  /// 立即播放胶囊按钮（对齐 iOS `playButton`）。
  Widget _buildPlayButton() {
    final bool enabled =
        _detail != null && _episodesForLine(_fromIndex).isNotEmpty && !_playing;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: SizedBox(
          width: double.infinity,
          // E5-3 Semantics 补点：立即播放按钮。
          child: Semantics(
            button: true,
            label: _playing ? '播放中' : '立即播放',
            child: Material(
              color: VboxColors.detailPlayButton,
              borderRadius: BorderRadius.circular(VboxRadii.capsule),
              child: InkWell(
                onTap: enabled ? _play : null,
                borderRadius: BorderRadius.circular(VboxRadii.capsule),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (_playing)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      else
                        const Icon(Icons.play_arrow,
                            size: 16, color: Colors.black),
                      const SizedBox(width: 8),
                      Text(
                        _playing ? '播放中…' : '立即播放',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 演职人员（分类 tab + 小方头像卡横滑，对齐 iOS `castSection`）。
  Widget _buildCast(PlaybackDetail d) {
    final (
      List<_CastMember> actors,
      List<_CastMember> directors,
      List<_CastMember> writers
    ) = _castData(d);
    final bool hasAny =
        actors.isNotEmpty || directors.isNotEmpty || writers.isNotEmpty;
    if (!hasAny) return const SizedBox.shrink();
    final List<_CastMember> people = switch (_castTab) {
      '演员' => actors,
      '导演' => directors,
      '编剧' => writers,
      _ => <_CastMember>[...actors, ...directors, ...writers],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          spacing: 12,
          children: <Widget>[
            for (final String tab in <String>['全部', '演员', '导演', '编剧'])
              if (_castAvailable(tab, actors, directors, writers))
                _castTabButton(tab),
          ],
        ),
        const SizedBox(height: 12),
        if (people.isEmpty)
          Text(
            '暂无$_castTab信息',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          )
        else
          SizedBox(
            height: 136,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: people.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: 14),
              itemBuilder: (BuildContext context, int index) =>
                  _CastPersonCard(person: people[index]),
            ),
          ),
      ],
    );
  }

  bool _castAvailable(
    String tab,
    List<_CastMember> actors,
    List<_CastMember> directors,
    List<_CastMember> writers,
  ) =>
      switch (tab) {
        '全部' => actors.isNotEmpty || directors.isNotEmpty || writers.isNotEmpty,
        '演员' => actors.isNotEmpty,
        '导演' => directors.isNotEmpty,
        '编剧' => writers.isNotEmpty,
        _ => false,
      };

  Widget _castTabButton(String tab) {
    final bool selected = _castTab == tab;
    return GestureDetector(
      onTap: () => setState(() => _castTab = tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withValues(alpha: 0.2) : null,
          borderRadius: BorderRadius.circular(VboxRadii.r6),
        ),
        child: Text(
          tab,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color:
                selected ? Colors.white : Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  /// 演职人员数据（TMDB 有则整体替换站点文本，对齐 iOS）。
  (
    List<_CastMember>,
    List<_CastMember>,
    List<_CastMember>,
  ) _castData(PlaybackDetail d) {
    final TmdbEnrichment? tmdb = _tmdb;
    if (tmdb != null && tmdb.hasCredits) {
      return (
        tmdb.actors
            .map((TmdbPerson p) => _CastMember(
                  name: p.name,
                  coverUrl: p.coverUrl,
                  role: p.character,
                ))
            .toList(growable: false),
        tmdb.directors
            .map((TmdbPerson p) => _CastMember(
                  name: p.name,
                  coverUrl: p.coverUrl,
                  role: p.character ?? '导演',
                ))
            .toList(growable: false),
        tmdb.writers
            .map((TmdbPerson p) => _CastMember(
                  name: p.name,
                  coverUrl: p.coverUrl,
                  role: p.character ?? '编剧',
                ))
            .toList(growable: false),
      );
    }
    // TMDB 无演职 / 未启用 → 回退豆瓣演职（对齐 iOS `loadDoubanData` 写入后展示）。
    final DoubanCredits? douban = _doubanCredits;
    if (douban != null && !douban.isEmpty) {
      return (
        douban.actors.map(_doubanToCast).toList(growable: false),
        douban.directors.map(_doubanToCast).toList(growable: false),
        douban.writers.map(_doubanToCast).toList(growable: false),
      );
    }
    // 站点 `vodActor` 纯文本不兜底（对齐 iOS：演职区块只渲染带头像的
    // TMDB / 豆瓣数据，两边皆无 → 整块隐藏，而非显示无名氏文本卡）。
    return (
      const <_CastMember>[],
      const <_CastMember>[],
      const <_CastMember>[]
    );
  }

  /// 豆瓣演职人员 → 卡片模型（角色文案对齐 iOS `DoubanCelebrity.roleText`）。
  _CastMember _doubanToCast(DoubanCelebrity p) =>
      _CastMember(name: p.name, coverUrl: p.coverUrl, role: p.roleText);

  /// 剧情简介 + 收藏心形（对齐 iOS `synopsisSection`）。
  Widget _buildSynopsis(PlaybackDetail d) {
    final String content = d.vod.vodContent?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text(
              '剧情简介',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            // E5-3 Semantics 补点：收藏切换（状态透传 selected）。
            GestureDetector(
              onTap: _toggleFavorite,
              behavior: HitTestBehavior.opaque,
              child: Semantics(
                button: true,
                selected: _favorite,
                label: _favorite ? '取消收藏' : '加入收藏',
                child: Icon(
                  _favorite ? Icons.favorite : Icons.favorite_border,
                  size: 24,
                  color: _favorite
                      ? VboxColors.detailSelected
                      : Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          content.isEmpty ? '暂无简介' : content,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
      ],
    );
  }

  /// 网盘源区块（对齐 iOS `panSection`）：云源（☁️）时内联展示网盘 tab 栏 +
  /// 当前网盘的剧集列表；非云源返回空。
  Widget _buildPanSection() {
    if (!_isCloudVideo) return const SizedBox.shrink();
    if (_rawCloudLinks.isEmpty && !_isLoadingPan) {
      return const SizedBox.shrink();
    }
    final List<String> drives = _cloudDriveNames;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.cloud,
                size: 14,
                color: VboxColors.selected,
              ),
              const SizedBox(width: 6),
              if (_isLoadingPan && _rawCloudLinks.isEmpty) ...<Widget>[
                Expanded(
                  child: Text(
                    '正在加载网盘资源…',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ] else if (_rawCloudLinks.isEmpty)
                Text(
                  '未找到网盘链接',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                )
              else
                Text(
                  '网盘源 (${drives.length} 个)',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: VboxColors.selected,
                  ),
                ),
            ],
          ),
          if (_rawCloudLinks.isNotEmpty && drives.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _buildDriveTabs(drives),
            const SizedBox(height: 10),
            _buildDriveEpisodeSection(
              _selectedCloudDrive != null &&
                      drives.contains(_selectedCloudDrive)
                  ? _selectedCloudDrive!
                  : drives.first,
            ),
          ],
        ],
      ),
    );
  }

  /// 网盘 tab 栏（对齐 iOS `panSection` 的横向 ScrollView）。
  Widget _buildDriveTabs(List<String> drives) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: drives.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final String drive = drives[index];
          final bool selected = (_selectedCloudDrive ?? drives.first) == drive;
          final _DriveExpandState? state = _driveExpandStates[drive];
          final String countText = switch (state?.kind) {
            _DriveExpandKind.loaded => '${state!.links.length}',
            _DriveExpandKind.loading => '...',
            _ => '-',
          };
          return GestureDetector(
            onTap: () => setState(() => _selectedCloudDrive = drive),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? VboxColors.detailSelected
                    : Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(VboxRadii.r8),
              ),
              child: Row(
                children: <Widget>[
                  Icon(_driveIcon(drive), size: 13, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    drive,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    countText,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 单个网盘的剧集列表（对齐 iOS `driveEpisodeSection` 的四种状态）。
  Widget _buildDriveEpisodeSection(String driveName) {
    final _DriveExpandState state =
        _driveExpandStates[driveName] ?? _DriveExpandState.loading;
    switch (state.kind) {
      case _DriveExpandKind.loading:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: <Widget>[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                '正在加载 $driveName 剧集列表…',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        );
      case _DriveExpandKind.failed:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: VboxColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ),
        );
      case _DriveExpandKind.empty:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.all_inbox,
                size: 14,
                color: Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Text(
                '$driveName 暂无视频文件',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        );
      case _DriveExpandKind.loaded:
        final List<_CloudPanLink> links = state.links;
        if (links.isEmpty) return const SizedBox.shrink();
        final List<_CloudPanLink> ordered =
            _episodesReversed ? links.reversed.toList(growable: false) : links;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '$driveName 剧集列表',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () =>
                      setState(() => _episodesReversed = !_episodesReversed),
                  icon: Icon(
                    Icons.swap_vert,
                    size: 18,
                    color: _episodesReversed
                        ? VboxColors.detailSelected
                        : Colors.white.withValues(alpha: 0.7),
                  ),
                ),
                Text(
                  '共 ${links.length} 集',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                IconButton(
                  onPressed: () => _showEpisodePopup(),
                  icon: Icon(
                    Icons.grid_view,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 独立滚动区域（对齐 iOS `ScrollView(.vertical).frame(maxHeight: 300)`）。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 76,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.9,
                ),
                itemCount: ordered.length,
                itemBuilder: (BuildContext context, int index) => _EpisodeCell(
                  label: _cloudEpisodeTitle(ordered[index], index),
                  selected: false,
                  onTap: () => unawaited(_playPanLink(ordered[index])),
                ),
              ),
            ),
          ],
        );
    }
  }

  /// 网盘图标（对齐 iOS `driveIcon`：按盘名关键词匹配）。
  IconData _driveIcon(String drive) {
    if (drive.contains('115')) return Icons.cloud_outlined;
    if (drive.contains('阿里')) return Icons.cloud;
    return Icons.link;
  }

  /// 剧集列表（对齐 iOS `episodeSection`）。
  Widget _buildEpisodeSection(PlaybackDetail d) {
    final List<PlaybackEpisode> episodes = _episodesForLine(_fromIndex);
    final List<PlaybackEpisode> ordered = _episodesReversed
        ? episodes.reversed.toList(growable: false)
        : episodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text(
              '剧集列表',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            if (episodes.isNotEmpty)
              IconButton(
                onPressed: () =>
                    setState(() => _episodesReversed = !_episodesReversed),
                icon: Icon(
                  Icons.swap_vert,
                  size: 18,
                  color: _episodesReversed
                      ? VboxColors.detailSelected
                      : Colors.white.withValues(alpha: 0.7),
                ),
              ),
            Text(
              episodes.isEmpty ? '暂无集数' : '共 ${episodes.length} 集',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
            if (episodes.isNotEmpty)
              // E5-3 Semantics 补点：选集入口。
              IconButton(
                tooltip: '选集',
                onPressed: () => _showEpisodePopup(),
                icon: Icon(
                  Icons.grid_view,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            if (episodes.isNotEmpty)
              // E5-3 Semantics 补点：批量下载入口。
              IconButton(
                tooltip: '批量下载',
                onPressed: () => _showEpisodePopup(downloadMode: true),
                icon: Icon(
                  Icons.download_outlined,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
        if (d.froms.length > 1) ...<Widget>[
          const SizedBox(height: 12),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: d.froms.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int index) =>
                  _lineChip(d.froms[index], index == _fromIndex, () {
                if (index == _fromIndex) return;
                setState(() {
                  _fromIndex = index;
                  _episodeIndex = 0;
                });
              }),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (episodes.isEmpty)
          Text(
            '暂无剧集',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          )
        else
          // 独立滚动区域（对齐 iOS `ScrollView(.vertical).frame(maxHeight: 300)`）：
          // 集数多时宫格内部上下滑动，页面其余部分不跟着拉长。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 76,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.9,
              ),
              itemCount: ordered.length,
              itemBuilder: (BuildContext context, int index) {
                final PlaybackEpisode ep = ordered[index];
                final int visibleIndex = episodes.indexWhere(
                  (PlaybackEpisode e) => e.url == ep.url && e.name == ep.name,
                );
                final bool selected = visibleIndex == _episodeIndex;
                return _EpisodeCell(
                  label: ep.name.isEmpty ? '第${index + 1}集' : ep.name,
                  selected: selected,
                  // 点击即播（对齐 iOS `Button { handleEpisodeSelect(episode) }`，
                  // 此前只改选中态不起播）。
                  onTap: () => unawaited(_playEpisode(ep)),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _lineChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? VboxColors.detailSelected
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(VboxRadii.r8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: Colors.white.withValues(alpha: selected ? 1.0 : 0.8),
          ),
        ),
      ),
    );
  }
}

/// 演职人员卡片（对齐 iOS `CastPersonCard`：60×90 头像 + 姓名 + 角色）。
class _CastPersonCard extends StatelessWidget {
  const _CastPersonCard({required this.person});

  final _CastMember person;

  @override
  Widget build(BuildContext context) {
    final String? role = person.role;
    return Column(
      spacing: 6,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(VboxRadii.r8),
          child: SizedBox(
            width: 60,
            height: 90,
            child: PlatformAsyncImage(
              url: person.coverUrl,
              fit: BoxFit.cover,
              placeholderColor: Colors.grey.withValues(alpha: 0.3),
              placeholder:
                  ColoredBox(color: Colors.grey.withValues(alpha: 0.3)),
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: Colors.grey.withValues(alpha: 0.3)),
            ),
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        ),
        if (role != null && role.isNotEmpty)
          SizedBox(
            width: 60,
            child: Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
  }
}

/// 演职人员项（名称 + 可选头像 / 角色）。
class _CastMember {
  const _CastMember({required this.name, this.coverUrl, this.role});

  final String name;
  final String? coverUrl;
  final String? role;
}

/// 原始网盘链接（对齐 iOS `rawCloudLinks` 元组：url / name / driveType / driveName）。
class _RawCloudLink {
  const _RawCloudLink({
    required this.url,
    required this.name,
    this.driveType,
    required this.driveName,
  });

  /// 分享链接（Node 派生盘带 `#vbox_nd=1` 标记）。
  final String url;

  /// 链接名（展示用；用于推断盘别）。
  final String name;

  /// 识别出的网盘类型（无法识别为 null）。
  final CloudDriveType? driveType;

  /// 网盘显示名（tab 栏 / 分组键）。
  final String driveName;
}

/// 网盘条目（对齐 iOS `CloudPanLink`）：单集 + F-P27 定位 fragment。
class _CloudPanLink {
  const _CloudPanLink({
    required this.id,
    required this.url,
    required this.name,
    this.driveType,
    required this.driveName,
  });

  /// 唯一 id（`driveName|index|name|url`）。
  final String id;

  /// 条目地址（分享链接 + `#vbox_*` 定位参数）。
  final String url;

  /// 文件名。
  final String name;

  /// 网盘类型。
  final CloudDriveType? driveType;

  /// 网盘显示名。
  final String driveName;
}

/// 网盘展开状态（对齐 iOS `DriveExpandState`）。
enum _DriveExpandKind {
  /// 加载中。
  loading,

  /// 已加载。
  loaded,

  /// 加载失败。
  failed,

  /// 空（无视频文件）。
  empty,
}

/// 网盘展开状态载体。
class _DriveExpandState {
  const _DriveExpandState(
    this.kind, {
    this.links = const <_CloudPanLink>[],
    this.message = '',
  });

  /// 状态种类。
  final _DriveExpandKind kind;

  /// 已加载条目（[kind] 为 loaded 时有效）。
  final List<_CloudPanLink> links;

  /// 失败文案（[kind] 为 failed 时有效）。
  final String message;

  /// 加载中。
  static const _DriveExpandState loading =
      _DriveExpandState(_DriveExpandKind.loading);

  /// 空。
  static const _DriveExpandState empty =
      _DriveExpandState(_DriveExpandKind.empty);

  /// 已加载。
  factory _DriveExpandState.loaded(List<_CloudPanLink> links) =>
      _DriveExpandState(_DriveExpandKind.loaded, links: links);

  /// 失败。
  factory _DriveExpandState.failed(String message) =>
      _DriveExpandState(_DriveExpandKind.failed, message: message);
}

/// 单集宫格项（对齐 iOS 剧集网格：白色 12% 底 + 白字）。
class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VboxRadii.r8),
        side: selected
            ? const BorderSide(color: VboxColors.detailSelected, width: 1.5)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
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

/// 剧集展开弹窗（对齐 iOS `EpisodeExpandPopup`：排序 + 下载多选）。
class _EpisodeExpandDialog extends StatefulWidget {
  const _EpisodeExpandDialog({
    required this.title,
    required this.episodes,
    required this.initialReversed,
    required this.initialDownloadMode,
    required this.onReversedChanged,
    required this.onPlay,
    required this.onDownload,
  });

  final String title;
  final List<PlaybackEpisode> episodes;
  final bool initialReversed;
  final bool initialDownloadMode;
  final ValueChanged<bool> onReversedChanged;
  final ValueChanged<PlaybackEpisode> onPlay;
  final ValueChanged<List<PlaybackEpisode>> onDownload;

  @override
  State<_EpisodeExpandDialog> createState() => _EpisodeExpandDialogState();
}

class _EpisodeExpandDialogState extends State<_EpisodeExpandDialog> {
  late bool _reversed = widget.initialReversed;
  late bool _downloadMode = widget.initialDownloadMode;
  final Set<int> _selected = <int>{};

  List<PlaybackEpisode> get _ordered => _reversed
      ? widget.episodes.reversed.toList(growable: false)
      : widget.episodes;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.of(context).size;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<PlaybackEpisode> ordered = _ordered;
    // 长名占比高 → 双列（对齐 iOS `useTwoColumns`）。
    final int longCount =
        ordered.where((PlaybackEpisode e) => e.name.length > 8).length;
    final bool twoColumns =
        ordered.isNotEmpty && longCount / ordered.length > 0.3;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VboxRadii.r16),
      ),
      child: SizedBox(
        width: (screen.width - 32).clamp(0, 380).toDouble(),
        height: (screen.height * 0.58).clamp(360.0, screen.height * 0.72),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                spacing: 10,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _downloadMode
                              ? '已选 ${_selected.length} 集'
                              : '共 ${ordered.length} 集',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _reversed = !_reversed;
                      _selected.clear();
                      widget.onReversedChanged(_reversed);
                    }),
                    icon: Icon(
                      Icons.swap_vert,
                      size: 18,
                      color: _reversed
                          ? VboxColors.detailSelected
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      if (_downloadMode && _selected.isNotEmpty) {
                        final List<PlaybackEpisode> picked = _selected
                            .map((int i) => ordered[i])
                            .toList()
                          ..sort((PlaybackEpisode a, PlaybackEpisode b) =>
                              ordered.indexOf(a).compareTo(ordered.indexOf(b)));
                        widget.onDownload(picked);
                      } else {
                        _downloadMode = !_downloadMode;
                        if (!_downloadMode) _selected.clear();
                      }
                    }),
                    icon: Icon(
                      _downloadMode
                          ? (_selected.isEmpty
                              ? Icons.check_circle_outline
                              : Icons.check_circle)
                          : Icons.download_outlined,
                      size: 18,
                      color: _downloadMode && _selected.isNotEmpty
                          ? VboxColors.selected
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: twoColumns ? 2 : 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: twoColumns ? 3.0 : 2.0,
                  ),
                  itemCount: ordered.length,
                  itemBuilder: (BuildContext context, int index) {
                    final PlaybackEpisode ep = ordered[index];
                    final bool checked = _selected.contains(index);
                    final String label =
                        ep.name.isEmpty ? '第${index + 1}集' : ep.name;
                    return Material(
                      color: _downloadMode && checked
                          ? VboxColors.selected.withValues(alpha: 0.15)
                          : scheme.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(VboxRadii.r8),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          if (_downloadMode) {
                            setState(() {
                              if (checked) {
                                _selected.remove(index);
                              } else {
                                _selected.add(index);
                              }
                            });
                          } else {
                            widget.onPlay(ep);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: twoColumns ? 2 : 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: _downloadMode && checked
                                        ? VboxColors.selected
                                        : scheme.onSurface,
                                  ),
                                ),
                              ),
                              if (_downloadMode) ...<Widget>[
                                const SizedBox(width: 4),
                                Icon(
                                  checked
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  size: 12,
                                  color: checked
                                      ? VboxColors.selected
                                      : scheme.outline,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
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
            const Icon(Icons.error_outline, size: 40, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
