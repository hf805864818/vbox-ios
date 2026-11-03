/// 短剧详情专页（对齐 iOS `ShortDramaDetailView.swift`，逐区块复刻）。
///
/// 唯一真相源：`vbox/Views/ShortDramaDetailView.swift`（557 行）+
/// iOS 列表页传参 `vbox/Views/ShortDramaView.swift` L140-142
/// （`.sheet(item: $selectedDrama) { ShortDramaDetailView(drama: drama) }`：传整条 `VodItem`）。
///
/// 区块落地位置（与 iOS 行号一一对应）：
/// - **骨架** L16-65：`Scaffold` + AppBar「短剧详情」；内容纵向 4 区块、底部 padding 40；
///   loading 时覆盖 `CircularProgressIndicator`（对齐 `.overlay { ProgressView() }`）。
/// - **封面信息区** L67-133：`Row`(top, spacing 16, h16)；左封面 120×170 圆角 8；
///   右信息列（标题 18 bold 最多 2 行 / 备注 clock 12 / 年份 calendar 12 / 演员 person 12 最多 2 行，列间距 6）。
/// - **简介区** L135-148：`vodContent` 非空才显示；「剧情简介」15 semibold + 正文 13 次要色最多 5 行。
/// - **选集区** L150-202：标题「选集 (N集)」15 semibold；宫格 `maxHeight 200` 自身可滚动、
///   单元 70×36 圆角 8、选中=强调色实心+白字、未选=灰 0.12；点击=选中并立即全屏播放；
///   空态「暂无播放地址」14。
/// - **操作行** L204-259：两枚并排按钮（间距 12，padding h16/top8）——「立即播放」主色填充、
///   「下载」灰 0.6 底；圆角 12、16 semibold 白字、垂直内边距 14。
/// - **下载选集弹窗** L474-557：底部弹窗、头部「选择下载集数 / 共 N 集，已选 M 集」+「全选」、
///   4 列多选宫格（单元 60×36）、底部「下载选中(N)」空选禁用。
/// - **数据加载** L261-290：先本地解析 `drama.vodPlayUrl` → 剧集或简介为空时按 `engineKey`
///   重排源列表、逐源加载详情、首个成功即采用；**批量下载** L293-323：名称「剧名 集号」、来源
///   「短剧」、`sourceType=normal`、传 `engineKey`/`vodId`/原 `playurl`（对齐 iOS `handleBatchDownload`）。
///
/// ── 已登记的差异（Flutter ↔ iOS）───────────────────────────────────────────────
/// 1. **模态形态**：iOS 为 sheet 模态（`.sheet`）；Flutter 用 `Navigator.push`
///    （`MaterialPageRoute`）打开整页（语义等价，任务授权自行裁定）。
/// 2. **数据通路**：iOS `ShortDramaService.fetchDetail(vodId:api:engineKey:)` 按源
///    （API 直取 CMS / 蜘蛛走 `SpiderManager.getDetail(engineKey:)`）；Flutter 统一走
///    `DetailPlaybackUseCases.loadDetail(siteKey:vodId:)`（用例层内按 `SiteMode` 分流）。
/// 3. **剧集解析**：iOS `parseEpisodes` 含非标准启发式（`parseDollar3AsEpisodes` /
///    `isLineName` / `looksLikeEpisodeName`）；Flutter 复用契约标准解析器
///    `PlaybackUrlParser`（`$$$` 分线路 / `#` 分集 / `$` 分名址），非标准启发式未移植。
/// 4. **字号档位映射**（取本仓库 `VboxTypography` 就近档位）：18→s18、16→s16、15→s15、
///    14→s14、13→s13、12→s12、10→s10 —— 与 iOS `.system(size:)` 完全一致，无降级。
/// 5. **播放承载**：iOS `fullScreenCover` + `VideoPlayerViewV2(preParsedEpisodes:)`；
///    Flutter 复用仓库既有全屏播放页 `PlayerPage`（push），播放前经 `resolvePlayUrl` 二次解析
///    （需 `site`；详情未加载成功时退化为直接播放原始地址）。
/// 6. **复用组件未采用登记**：`VboxButton`（圆角 8 / 14pt / 无灰 0.6 形态）、
///    `VboxEpisodeChip`（选中=20% 填充+描边，非实心填充）、`VboxSectionHeader`（16pt 且带
///    vertical padding，非 15pt）与本页 iOS 规格（圆角 12 / 16pt 白字实心、选中实心填充、
///    标题 15pt semibold）不一致，故按 iOS 规格内联实现以严格对齐（差异如实登记）。
/// 7. **源列表 `engineKey`**：iOS `ShortDramaSource.engineKey` 为蜘蛛引擎 key；Flutter
///    `ShortDramaSource` 原无该字段，本页为对齐「按 engineKey 重排源」逻辑新增可选字段并在
///    列表页扫描时回填（蜘蛛源=站点 key，API/站源=null）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/failures.dart';
import '../../../core/utils/result.dart';
import '../../../core/utils/time_utils.dart';
import '../../../data/models/download.dart';
import '../../../domain/entities/player/player.dart';
import '../../../domain/entities/playback/playback.dart';
import '../../../domain/entities/spider/spider.dart';
import '../../../domain/usecases/usecases.dart';
import '../../../platform/download/download.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../player/player_page.dart';
import 'short_drama_page.dart' show ShortDramaSource;

/// 短剧详情专页（对齐 iOS `ShortDramaDetailView`）。
class ShortDramaDetailPage extends StatefulWidget {
  /// 构造。
  const ShortDramaDetailPage({
    super.key,
    required this.drama,
    this.sources = const <ShortDramaSource>[],
  });

  /// 短剧条目（对齐 iOS `ShortDramaDetailView.drama: VodItem`）。
  final VodItem drama;

  /// 短剧源列表（对齐 iOS `ShortDramaService.shortDramaSources`；由列表页传入）。
  final List<ShortDramaSource> sources;

  @override
  State<ShortDramaDetailPage> createState() => _ShortDramaDetailPageState();
}

class _ShortDramaDetailPageState extends State<ShortDramaDetailPage> {
  late final DetailPlaybackUseCases _uc;

  /// 加载成功后的详情条目（对齐 iOS `detailItem`）。
  PlaybackDetail? _detail;

  /// 剧集列表（对齐 iOS `episodes`）。
  List<PlaybackEpisode> _episodes = const <PlaybackEpisode>[];

  /// 加载中（对齐 iOS `isLoading`，初值 true）。
  bool _loading = true;

  /// 当前选中集索引（对齐 iOS `selectedEpisodeIndex`）。
  int _selectedIndex = 0;

  /// 是否正在起播（防重复触发）。
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _uc = context.read<DetailPlaybackUseCases>();
    _loadDetail();
  }

  // ─────────────── 展示字段（对齐 iOS detailItem ?? drama 兜底）───────────────

  VodItem get _drama => widget.drama;

  /// 封面（iOS L77 `detailItem?.vodPic ?? drama.vodPic`）。
  String get _coverUrl => _detail?.vod.vodPic ?? _drama.vodPic;

  /// 年份（iOS L120 `detailItem?.vodYear ?? drama.vodYear`）。
  String? get _year => _detail?.vod.vodYear ?? _drama.vodYear;

  /// 演员（iOS L126 `detailItem?.vodActor ?? drama.vodActor`）。
  String? get _actor => _detail?.vod.vodActor ?? _drama.vodActor;

  /// 简介（iOS L137 `detailItem?.vodContent ?? drama.vodContent`）。
  String? get _content => _detail?.vod.vodContent ?? _drama.vodContent;

  /// 引擎 key（iOS L178/L223 `detailItem?.engineKey ?? drama.engineKey`）。
  String? get _engineKey => _detail?.vod.engineKey ?? _drama.engineKey;

  // ─────────────── 数据加载（对齐 iOS L261-290）───────────────

  Future<void> _loadDetail() async {
    // ① 先本地解析 `drama.vodPlayUrl`（对齐 iOS `parseEpisodes(from: drama.vodPlayUrl)`）。
    _episodes = PlaybackUrlParser.parse(
      _drama.vodPlayFrom,
      _drama.vodPlayUrl,
    ).episodes;

    // ② 判定是否需逐源加载（对齐 iOS L264）：剧集为空 或 详情简介为空。
    //    注意 iOS `detailItem?.vodContent?.isEmpty ?? true` 在首次加载（detailItem 为 nil）
    //    时恒为 true —— 故正常流程**总会**进入加载分支；本页同口径。
    final bool contentEmpty = _detail?.vod.vodContent?.isEmpty ?? true;
    if (!(_episodes.isEmpty || contentEmpty)) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // ③ 按 engineKey 重排源列表 → 逐源加载，首个成功即采用（对齐 iOS L266-285）。
    for (final ShortDramaSource source in _orderedSources()) {
      final Result<PlaybackDetail> result = await _uc.loadDetail(
        siteKey: source.siteKey,
        vodId: _drama.vodId,
      );
      if (!mounted) return;
      final PlaybackDetail? detail = result.valueOrNull;
      if (detail != null) {
        setState(() {
          _detail = detail;
          // 采用详情剧集（对齐 iOS `parseEpisodes(from: detail.vodPlayUrl)`）。
          _episodes = detail.episodes;
          _selectedIndex = 0;
          _loading = false;
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// 按 `engineKey` 重排源列表（对齐 iOS L267-273）：
  /// - `drama.engineKey != null` → engineKey 命中的源排前，其余在后；
  /// - `drama.engineKey == null` → engineKey 为 null 的源排前，其余在后。
  List<ShortDramaSource> _orderedSources() {
    final String? engineKey = _drama.engineKey;
    final List<ShortDramaSource> matched = <ShortDramaSource>[];
    final List<ShortDramaSource> others = <ShortDramaSource>[];
    for (final ShortDramaSource s in widget.sources) {
      if (s.engineKey == engineKey) {
        matched.add(s);
      } else {
        others.add(s);
      }
    }
    return <ShortDramaSource>[...matched, ...others];
  }

  // ─────────────── 播放（对齐 iOS L163-180 / L209-224）───────────────

  Future<void> _playEpisode(int index) async {
    if (_episodes.isEmpty || _playing) return;
    final int i = index.clamp(0, _episodes.length - 1);
    setState(() => _selectedIndex = i);
    final PlaybackEpisode episode = _episodes[i];
    final String title = '${_drama.vodName} ${episode.name}';

    setState(() => _playing = true);
    try {
      String url = episode.url;
      Map<String, String> headers = const <String, String>{};
      final PlaybackDetail? d = _detail;
      if (d != null) {
        final Result<PlayerContentResult> result =
            await _uc.resolvePlayUrl(detail: d, episode: episode);
        if (!mounted) return;
        final Failure? failure = result.failureOrNull;
        if (failure != null) {
          _toast('解析失败：$failure');
          return;
        }
        final PlayerContentResult? pc = result.valueOrNull;
        final String? resolved = _firstUrl(pc);
        if (resolved == null || resolved.isEmpty) {
          _toast('未解析到播放地址');
          return;
        }
        url = resolved;
        headers = pc?.header ?? const <String, String>{};
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PlayerPage(
            source: PlayerSource(url: url, title: title, headers: headers),
            title: title,
            subtitle: episode.name,
            vodId: _drama.vodId,
            episodes: _episodes,
            initialEpisodeIndex: i,
            onResolveEpisode: _resolveEpisode,
          ),
        ),
      );
    } catch (e) {
      if (mounted) _toast('播放失败：$e');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  /// 选集重开解析器（对齐 iOS 预解析集数 + 按需解析；详情未就绪时退化为原地址）。
  Future<PlayerSource?> _resolveEpisode(PlaybackEpisode episode) async {
    final String title = '${_drama.vodName} ${episode.name}';
    final PlaybackDetail? d = _detail;
    if (d == null) {
      return PlayerSource(url: episode.url, title: title);
    }
    final Result<PlayerContentResult> result =
        await _uc.resolvePlayUrl(detail: d, episode: episode);
    final PlayerContentResult? pc = result.valueOrNull;
    final String? url = _firstUrl(pc);
    if (url == null || url.isEmpty) return null;
    return PlayerSource(
      url: url,
      title: title,
      headers: pc?.header ?? const <String, String>{},
    );
  }

  /// 取播放地址（url > urls.first > playUrl，同详情页口径）。
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

  // ─────────────── 下载选集弹窗 + 批量下载（对齐 iOS L204-259 / L474-557）──────────

  Future<void> _openDownloadSheet() async {
    if (_episodes.isEmpty) return;
    final List<int>? picked = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => _DownloadSheet(episodes: _episodes),
    );
    if (picked == null || picked.isEmpty) return;
    await _enqueueDownloads(picked);
  }

  /// 逐集构造下载记录并入队（对齐 iOS `handleBatchDownload` L293-323）。
  ///
  /// 名称「剧名 集号」、来源「短剧」、`sourceType=normal`、传 `engineKey`/`vodId`
  /// 与**原始** `playurl`（执行时由下载管理端按 engineKey 解析，不预解析）。
  Future<void> _enqueueDownloads(List<int> indices) async {
    if (indices.isEmpty || _episodes.isEmpty) return;
    final DownloadManager manager = context.read<DownloadManager>();
    final String? engineKey = _engineKey;
    for (final int index in indices) {
      if (index < 0 || index >= _episodes.length) continue;
      final PlaybackEpisode episode = _episodes[index];
      final String label =
          episode.name.isEmpty ? '第${index + 1}集' : episode.name;
      await manager.enqueue(
        Download(
          name: '${_drama.vodName} $label',
          laiyuan: '短剧',
          imgurl: _coverUrl,
          detailurl: _drama.vodId,
          playurl: episode.url,
          jishu: index + 1,
          addedAt: TimeUtils.nowUnixSeconds(),
          sourceType: 'normal',
          engineKey: engineKey,
          vodId: _drama.vodId,
        ),
      );
    }
    if (!mounted) return;
    _toast('已添加 ${indices.length} 集到下载');
  }

  // ─────────────── UI（对齐 iOS L16-65 骨架 + L67-259 区块）───────────────

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = scheme.primary;

    final List<Widget> sections = <Widget>[
      _buildCoverInfo(scheme),
      if (_content?.isNotEmpty ?? false) _buildSynopsis(scheme),
      if (_episodes.isNotEmpty)
        _buildEpisodes(scheme, accent)
      else if (!_loading)
        _buildEmptyEpisodes(scheme),
      if (_episodes.isNotEmpty) _buildActions(accent),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('短剧详情')),
      body: Stack(
        children: <Widget>[
          SingleChildScrollView(
            // 对齐 iOS `.padding(.bottom, 40)` + VStack(spacing: 16)。
            padding: const EdgeInsets.only(bottom: 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _withSpacing(sections, 16),
            ),
          ),
          if (_loading)
            const Positioned.fill(
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  /// 按 [gap] 交错插入间距（等价 iOS `VStack(spacing:)` 仅对存在子项生效）。
  List<Widget> _withSpacing(List<Widget> children, double gap) {
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) out.add(SizedBox(height: gap));
      out.add(children[i]);
    }
    return out;
  }

  /// 封面信息区（对齐 iOS L67-133）。
  Widget _buildCoverInfo(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            // iOS `RoundedRectangle(cornerRadius: 8)`。
            borderRadius: BorderRadius.circular(VboxRadii.r8),
            child: SizedBox(
              width: 120,
              height: 170,
              child: PlatformAsyncImage(
                url: _coverUrl,
                fit: BoxFit.cover,
                // 空态（对齐 iOS `.empty`：灰 0.1 + ProgressView）。
                placeholder: Container(
                  color: Colors.grey.withValues(alpha: 0.1),
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(),
                ),
                // 失败态（对齐 iOS `.failure`：灰 0.2 + play.slash + 「加载失败」10pt 灰）。
                errorBuilder: (BuildContext context, Object error,
                        StackTrace? stackTrace) =>
                    Container(
                  color: Colors.grey.withValues(alpha: 0.2),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.play_disabled, color: scheme.outline),
                      const SizedBox(height: VboxSpacing.xs),
                      Text(
                        '加载失败',
                        style: TextStyle(
                          fontSize: VboxTypography.s10,
                          color: scheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: VboxSpacing.lg),
          Expanded(child: _buildMetadata(scheme)),
        ],
      ),
    );
  }

  /// 信息列（对齐 iOS L108-133，VStack spacing 6）。
  Widget _buildMetadata(ColorScheme scheme) {
    final TextStyle metaStyle = TextStyle(
      fontSize: VboxTypography.s12,
      color: scheme.onSurfaceVariant,
    );
    final String? remarks = _drama.vodRemarks;
    final String? year = _year;
    final String? actor = _actor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _drama.vodName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: VboxTypography.s18,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        if (remarks != null) ...<Widget>[
          const SizedBox(height: 6),
          _metaRow(Icons.access_time, remarks, metaStyle),
        ],
        if (year != null) ...<Widget>[
          const SizedBox(height: 6),
          _metaRow(Icons.calendar_today, year, metaStyle),
        ],
        if (actor != null && actor.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          _metaRow(Icons.person, actor, metaStyle, maxLines: 2),
        ],
      ],
    );
  }

  /// 元信息行（图标 12 + 次要色文本，`Label` 近似）。
  Widget _metaRow(IconData icon, String text, TextStyle style,
      {int maxLines = 1}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: VboxTypography.s12, color: style.color),
        const SizedBox(width: VboxSpacing.xs),
        Expanded(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }

  /// 简介区（对齐 iOS L135-148）。
  Widget _buildSynopsis(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '剧情简介',
            style: TextStyle(
              fontSize: VboxTypography.s15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _content!,
            // 最多 5 行截断（iOS `.lineLimit(5)`，无展开/收起）。
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 选集区（对齐 iOS L150-202）。
  Widget _buildEpisodes(ColorScheme scheme, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
          child: Text(
            '选集 (${_episodes.length}集)',
            style: TextStyle(
              fontSize: VboxTypography.s15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
        // 对齐 iOS VStack(spacing: 8)。
        const SizedBox(height: VboxSpacing.sm),
        // 独立滚动区域（对齐 iOS `ScrollView(.vertical).frame(maxHeight: 200)`）。
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: GridView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
                VboxSpacing.lg, 0, VboxSpacing.lg, VboxSpacing.xs),
            // 近似对齐 iOS `GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 10)`。
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 90,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 70 / 36,
            ),
            itemCount: _episodes.length,
            itemBuilder: (BuildContext context, int index) {
              final PlaybackEpisode ep = _episodes[index];
              final bool selected = index == _selectedIndex;
              return Center(
                child: SizedBox(
                  width: 70,
                  height: 36,
                  child: Material(
                    // 选中=强调色填充+白字；未选=灰 0.12 底（对齐 iOS L184-185）。
                    color: selected
                        ? accent
                        : Colors.grey.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(VboxRadii.r8),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      // 点击即选中并立即全屏播放（对齐 iOS L163-180）。
                      onTap: () => _playEpisode(index),
                      child: Center(
                        child: Text(
                          ep.name.isEmpty ? '第${index + 1}集' : ep.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: VboxTypography.s13,
                            fontWeight: FontWeight.w500,
                            color: selected ? Colors.white : scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 选集空态（对齐 iOS L196-201：非加载中才显示「暂无播放地址」14pt）。
  Widget _buildEmptyEpisodes(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Text(
        '暂无播放地址',
        style: TextStyle(
          fontSize: VboxTypography.s14,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 操作行（对齐 iOS L204-259）。
  Widget _buildActions(Color accent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          VboxSpacing.lg, VboxSpacing.sm, VboxSpacing.lg, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _actionButton(
              icon: Icons.play_arrow,
              label: '立即播放',
              background: accent,
              onTap: () => _playEpisode(_selectedIndex),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _actionButton(
              icon: Icons.arrow_circle_down,
              label: '下载',
              background: Colors.grey.withValues(alpha: 0.6),
              onTap: _openDownloadSheet,
            ),
          ),
        ],
      ),
    );
  }

  /// 大号操作按钮（16 semibold 白字、垂距 14、圆角 12，对齐 iOS L226-253）。
  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color background,
    required VoidCallback onTap,
  }) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(VboxRadii.r12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: VboxTypography.s16, color: Colors.white),
              const SizedBox(width: VboxSpacing.sm),
              Text(
                label,
                style: const TextStyle(
                  fontSize: VboxTypography.s16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 下载选集弹窗（对齐 iOS `ShortDramaDownloadSheet` L474-557）。
class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({required this.episodes});

  final List<PlaybackEpisode> episodes;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  final Set<int> _selected = <int>{};

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = scheme.primary;
    final int count = widget.episodes.length;
    final bool allSelected = count > 0 && _selected.length == count;

    return SafeArea(
      child: SizedBox(
        // 对齐 iOS `presentationDetents([.medium, .large])` 的 medium 量级。
        height: MediaQuery.sizeOf(context).height * 0.66,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 头部：标题 + 计数 + 全选（对齐 iOS L487-508）。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  VboxSpacing.lg, VboxSpacing.sm, VboxSpacing.lg, 0),
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
                          '共 $count 集，已选 ${_selected.length} 集',
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
                      if (allSelected) {
                        _selected.clear();
                      } else {
                        _selected
                          ..clear()
                          ..addAll(List<int>.generate(count, (int i) => i));
                      }
                    }),
                    child: Text(
                      '全选',
                      style: TextStyle(
                        fontSize: VboxTypography.s14,
                        fontWeight: FontWeight.w500,
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 4 列多选宫格（对齐 iOS L481-483 / L510-532）。
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(
                    VboxSpacing.lg, 0, VboxSpacing.lg, 80),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: VboxSpacing.sm,
                  crossAxisSpacing: VboxSpacing.sm,
                  childAspectRatio: 60 / 36,
                ),
                itemCount: count,
                itemBuilder: (BuildContext context, int index) {
                  final PlaybackEpisode ep = widget.episodes[index];
                  final bool checked = _selected.contains(index);
                  return Center(
                    child: SizedBox(
                      width: 60,
                      height: 36,
                      child: Material(
                        color: checked
                            ? accent
                            : Colors.grey.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(VboxRadii.r8),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => setState(() {
                            if (checked) {
                              _selected.remove(index);
                            } else {
                              _selected.add(index);
                            }
                          }),
                          child: Center(
                            child: Text(
                              ep.name.isEmpty ? '第${index + 1}集' : ep.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: VboxTypography.s13,
                                fontWeight: FontWeight.w500,
                                color:
                                    checked ? Colors.white : scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 底部确认按钮（对齐 iOS L534-554：`.background(.bar)` 底栏）。
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm),
              color: scheme.surfaceContainerHighest,
              child: Material(
                color: _selected.isEmpty ? Colors.grey : accent,
                borderRadius: BorderRadius.circular(VboxRadii.r12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _selected.isEmpty
                      ? null
                      : () {
                          final List<int> sorted = _selected.toList()..sort();
                          Navigator.of(context).pop(sorted);
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Text(
                        '下载选中(${_selected.length})',
                        style: const TextStyle(
                          fontSize: VboxTypography.s16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
