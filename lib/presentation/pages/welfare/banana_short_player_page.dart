/// 表现层：香蕉秀短视频竖屏全屏播放器（抖音式上下滑切换）。
///
/// 唯一真相源：iOS `vbox/Views/WelfareSubViews.swift`
///   · `YBoxBananaShortVideoTab`（L298-L363）：短视频入口页（黑底 +
///     `play.rectangle.on.rectangle`(50) + 「短视频」(20 semibold) + 「开始浏览」
///     按钮（`play.fill` + 16 medium，h40/v12，主色底，圆角 25）；
///     API 探测中 → 白色转圈 + 「加载中...」；失败 → 天线斜杠(50) + 文案 + 「重试」）；
///   · `YBoxBananaShortPlayerView`（L367-L818）：竖屏全屏播放器真源。
///     - 单卡渲染（仅渲染 currentIndex）+ 位移切换（阈值 `cellHeight*0.2`，
///       `0.25s easeOut`）；播放器层 `allowsHitTesting(false)`；
///     - 封面 `blur(20)` 加载层（黑 0.25 遮罩）+ 失败重试；
///     - 左上返回（`chevron.left` 20 semibold，内边距 10）；
///     - 底部渐变信息区（`clear → 黑 0.75`）：头像 44 圆形 + 白 0.3 描边、
///       用户名 15 semibold、标题 13 两行、`当前/总数+`、**只读进度条**
///       （3pt 白 0.25 底 + 白填充，圆角 1.5）、时间（11 等宽）、倍速组
///       `[1.0,1.25,1.5,2.0]`（`%.2fx`，选中 bold 白 / 未选中白 0.45）；
///     - 播放结束 → 自动下一个；预加载邻域 `[-2,-1,1,2,3]`；
///     - 请求失败 1.5s 自动跳过（末尾提示「播放失败，上滑重试」）；
///     - `hasMore = count >= 10`；接近末尾（`index >= count-4`）加载更多。
///
/// 字号映射（iOS → [VboxTypography] 就近档位，全部命中档位）：
///   · 15 semibold → [VboxTypography.s15]；13 → s13；11 → s11；10 → s10；
///   · 倍速/时间等宽 → s11（时间）/ s11（倍速），`fontFamily: 'monospace'`。
///
/// 与 iOS 的差异（如实登记）：
///   · **竖向切换**：iOS 自实现 `DragGesture`（单卡 + offset + 阈值判定），
///     Flutter 用 `PageView.builder(scrollDirection: Axis.vertical)`——滚动吸附
///     物理替代「手动位移 + 0.2 阈值 + 0.25s easeOut 动画」，语义（上下滑切换）
///     等价，但无 `cellHeight*0.2` / `0.25s` 常量；自动切下一个经
///     `animateToPage(0.25s easeOut)` 与 iOS 时长一致；
///   · **播放器复用**：画面层复用 [VideoSurface]（`PlayerController.instance`
///     原生纹理，`Texture` 不拦手势，对齐 `allowsHitTesting(false)`）；
///     iOS 每卡新建 `AVPlayer` 并注入 iPhone UA / Referer，Flutter 播放地址与
///     请求头由服务 `fetchPlayerURL` 统一注入（`mini:` 前缀 → Referer + UA）；
///   · **只读进度条**：iOS 自绘 3pt 条；Flutter 亦自绘（**未**复用可拖拽的
///     `PlayerProgressBar`，以严格对齐「只读」语义与白底 / 3pt 规格）；
///   · **预加载**：预取播放地址缓存到 `Map<int, PlayerSource>`（对齐 iOS
///     `playURLs` 字典）；邻域 `[-2,-1,1,2,3]` 与首批 `1..min(6,…)` 一致；
///   · **分页口径**：`hasMore = 每页返回 >= 10`；接近末尾阈值 `index >= count-4`
///     一致；
///   · **退出释放**：iOS `player?.pause(); player = nil`；Flutter 复用全局
///     [PlayerController] 单例（同 `PlayerPage` 口径），退出仅暂停 + 解绑回调，
///     不调用 `dispose()`（避免拆掉全局控制器，交由上层复用）；
///   · **返回按钮定位**：iOS 绝对 `.top 50 / .leading 16`；Flutter 以
///     `SafeArea` 适配刘海 + 同侧内边距 16 / 上 10。
library;

import 'dart:async';
import 'dart:math' show min;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../domain/entities/player/player.dart';
import '../../../domain/entities/welfare/banana_mini_video.dart';
import '../../../domain/entities/welfare/fuli_models.dart';
import '../../../domain/services/banana_xjsp_service.dart';
import '../../../platform/player/player_controller.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/player/video_surface.dart';

/// 香蕉秀短视频竖屏全屏播放器（对齐 iOS `YBoxBananaShortPlayerView`）。
class BananaShortPlayerPage extends StatefulWidget {
  /// 构造（[controller] 供测试注入假播放器；生产缺省 `PlayerController.instance`）。
  const BananaShortPlayerPage({
    super.key,
    required this.service,
    this.controller,
  });

  /// 香蕉秀服务。
  final BananaXjspFuliService service;

  /// 播放器控制器（缺省 `PlayerController.instance`）。
  final PlayerController? controller;

  @override
  State<BananaShortPlayerPage> createState() => _BananaShortPlayerPageState();
}

class _BananaShortPlayerPageState extends State<BananaShortPlayerPage> {
  /// 每页条数阈值（对齐 iOS `hasMore = result.count >= 10`）。
  static const int _pageSize = 10;

  /// 失败自动跳过延时（对齐 iOS `DispatchQueue…after(1.5)`）。
  static const Duration _autoSkipDelay = Duration(milliseconds: 1500);

  /// 自动切下一个动画时长（对齐 iOS `withAnimation(.easeOut(duration: 0.25))`）。
  static const Duration _advanceDuration = Duration(milliseconds: 250);

  /// 倍速档位（对齐 iOS `[1.0, 1.25, 1.5, 2.0]`）。
  static const List<double> _speeds = <double>[1.0, 1.25, 1.5, 2.0];

  late final PlayerController _player;
  final PageController _pageController = PageController();

  List<BananaMiniVideo> _videos = <BananaMiniVideo>[];
  int _index = 0;

  /// 播放源预取缓存（`index → PlayerSource`；对齐 iOS `playURLs` 字典）。
  final Map<int, PlayerSource> _sources = <int, PlayerSource>{};

  /// 当前视频错误文案（非 null 时显示错误 / 跳过提示）。
  String? _error;

  bool _initialLoading = true;
  int _page = 1;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  /// 当前视频是否已就绪（对齐 iOS `isPlayerReady`）。
  bool _ready = false;

  int? _textureId;
  double? _aspectRatio;

  double _rate = 1.0;
  int _positionMs = 0;
  int _durationMs = 0;

  Timer? _skipTimer;

  @override
  void initState() {
    super.initState();
    _player = widget.controller ?? PlayerController.instance;
    _bindPlayer();
    unawaited(_loadInitial());
  }

  @override
  void dispose() {
    _skipTimer?.cancel();
    _pageController.dispose();
    // 退出仅暂停 + 解绑（对齐 iOS `player?.pause(); player = nil`；全局单例不销毁）。
    _player.onStateChanged = null;
    _player.onProgress = null;
    _player.onVideoSize = null;
    _player.onSurfaceChanged = null;
    _player.onError = null;
    unawaited(_player.pause());
    super.dispose();
  }

  // ─────────────── 播放器接线 ───────────────

  void _bindPlayer() {
    _player.onStateChanged = (PlayerState s) {
      if (!mounted) return;
      if (s == PlayerState.playing && !_ready) {
        setState(() => _ready = true);
      }
      // 播放结束 → 自动下一个（对齐 iOS `AVPlayerItemDidPlayToEndTime`）。
      if (s == PlayerState.ended) unawaited(_advance());
    };
    _player.onProgress = (PlaybackProgress p) {
      if (!mounted) return;
      setState(() {
        _positionMs = p.positionMs;
        if (p.durationMs > 0) _durationMs = p.durationMs;
      });
    };
    _player.onVideoSize = (int width, int height) {
      if (!mounted || height <= 0) return;
      setState(() => _aspectRatio = width / height);
    };
    _player.onSurfaceChanged = (int? id) {
      if (!mounted) return;
      setState(() => _textureId = id);
    };
    _player.onError = (String message, {required bool fatal}) {
      if (!mounted || !fatal) return;
      // 运行期播放失败（对齐 iOS status=failed / 播放中断）：显示错误 + 重试。
      setState(() {
        _error = message.isEmpty ? '播放失败' : message;
        _ready = false;
      });
    };
  }

  // ─────────────── 首屏 / 切换 / 分页 ───────────────

  Future<void> _loadInitial() async {
    final List<BananaMiniVideo> list =
        await widget.service.fetchMiniVideos(page: 1);
    if (!mounted) return;
    setState(() {
      _videos = list;
      _page = 1;
      // 对齐 iOS `hasMore = result.count >= 10`。
      _hasMore = list.length >= _pageSize;
      _initialLoading = false;
    });
    if (list.isEmpty) return;
    _switchTo(0);
    // 首批预加载（对齐 iOS `for i in 1...min(6, count-1)`）。
    for (int i = 1; i <= min(6, list.length - 1); i++) {
      _preload(i);
    }
    if (list.length < 20 && _hasMore) unawaited(_loadMore());
  }

  void _switchTo(int index) {
    if (index < 0 || index >= _videos.length) return;
    _skipTimer?.cancel();
    setState(() {
      _index = index;
      _error = null;
      _ready = false;
      _positionMs = 0;
      _durationMs = 0;
    });
    // 预加载邻域 [-2,-1,1,2,3]（对齐 iOS）。
    for (final int offset in <int>[-2, -1, 1, 2, 3]) {
      final int target = index + offset;
      if (target >= 0 && target < _videos.length) _preload(target);
    }
    // 接近末尾（index >= count-4）且还有更多 → 加载更多（对齐 iOS）。
    if (index >= _videos.length - 4 && _hasMore && !_isLoadingMore) {
      unawaited(_loadMore());
    }
    final PlayerSource? cached = _sources[index];
    if (cached != null) {
      unawaited(_startPlay(index, cached));
    } else {
      unawaited(_loadAndPlay(index));
    }
  }

  /// 取（或现取并缓存）指定索引的播放源；失败返回 null。
  Future<PlayerSource?> _ensureSource(int index) async {
    if (index < 0 || index >= _videos.length) return null;
    final PlayerSource? cached = _sources[index];
    if (cached != null) return cached;
    // `mini:` 前缀 → 服务侧走 `/minivod/reqplay` 并注入 Referer / UA 头。
    final FuliPlayerResult r = await widget.service.fetchPlayerURL(
      FuliEpisode(
        name: '正片',
        url: '${BananaXjspFuliService.miniVodPrefix}${_videos[index].vodId}',
      ),
    );
    if (r.url.isEmpty) return null;
    final PlayerSource source = PlayerSource(
      url: r.url,
      headers: r.headers,
      title: _videos[index].title,
    );
    if (index < _videos.length) _sources[index] = source;
    return source;
  }

  /// 预取播放地址（失败静默降级，不影响当前播放）。
  void _preload(int index) {
    if (index < 0 || index >= _videos.length) return;
    if (_sources.containsKey(index)) return;
    unawaited(_ensureSource(index));
  }

  Future<void> _loadAndPlay(int index) async {
    final PlayerSource? source = await _ensureSource(index);
    if (!mounted || index != _index) return;
    if (source == null) {
      _onSourceFailed(index);
      return;
    }
    await _startPlay(index, source);
  }

  /// 播放地址获取失败：非末尾 → 1.5s 自动跳过；末尾 → 提示上滑重试（对齐 iOS）。
  void _onSourceFailed(int index) {
    if (index != _index) return;
    if (index < _videos.length - 1) {
      setState(() => _error = '加载失败，即将跳过');
      _skipTimer = Timer(_autoSkipDelay, () {
        if (mounted && _index == index) unawaited(_advance());
      });
    } else {
      setState(() => _error = '播放失败，上滑重试');
    }
  }

  Future<void> _startPlay(int index, PlayerSource source) async {
    if (index != _index) return;
    try {
      await _player.open(source);
      await _player.setSpeed(_rate);
      await _player.play();
      if (!mounted || index != _index) return;
      setState(() => _ready = true);
    } catch (_) {
      // 打开异常（含无宿主 / 后端不可用）→ 按播放失败处理（末尾提示重试）。
      if (!mounted || index != _index) return;
      setState(() => _error = '播放失败，上滑重试');
    }
  }

  /// 切到下一个（播放结束 / 跳过）；末尾且有更多 → 先加载再前进（对齐 iOS）。
  Future<void> _advance() async {
    final int next = _index + 1;
    if (next < _videos.length) {
      _animateTo(next);
      return;
    }
    if (!_hasMore) return;
    await _loadMore();
    if (!mounted) return;
    if (_index + 1 < _videos.length) _animateTo(_index + 1);
  }

  void _animateTo(int index) {
    if (!_pageController.hasClients) {
      _switchTo(index);
      return;
    }
    unawaited(_pageController.animateToPage(
      index,
      duration: _advanceDuration,
      curve: Curves.easeOut,
    ));
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    final int next = _page + 1;
    final List<BananaMiniVideo> list =
        await widget.service.fetchMiniVideos(page: next);
    if (!mounted) return;
    final int oldCount = _videos.length;
    setState(() {
      if (list.isNotEmpty) {
        _videos = <BananaMiniVideo>[..._videos, ...list];
        _page = next;
        // 对齐 iOS `hasMore = result.count >= 10`。
        _hasMore = list.length >= _pageSize;
      } else {
        _hasMore = false;
      }
      _isLoadingMore = false;
    });
    // 预加载新视频播放地址（对齐 iOS `oldCount..<min(oldCount+5, count)`）。
    for (int i = oldCount; i < min(oldCount + 5, _videos.length); i++) {
      _preload(i);
    }
  }

  // ─────────────── 交互 ───────────────

  void _setRate(double rate) {
    setState(() => _rate = rate);
    unawaited(_player.setSpeed(rate));
  }

  void _onBack() {
    unawaited(_player.pause());
    Navigator.of(context).maybePop();
  }

  void _retry() {
    _skipTimer?.cancel();
    setState(() {
      _error = null;
      _ready = false;
    });
    unawaited(_loadAndPlay(_index));
  }

  int get _positionSec => _positionMs ~/ 1000;
  int get _durationSec => _durationMs ~/ 1000;
  double get _progress => _durationMs > 0
      ? (_positionMs / _durationMs).clamp(0.0, 1.0)
      : 0.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 视频 / 封面层（竖向 PageView 切换）。
          if (_videos.isNotEmpty)
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              physics: const PageScrollPhysics(),
              onPageChanged: _switchTo,
              itemCount: _videos.length,
              itemBuilder: (BuildContext context, int index) =>
                  _buildPage(_videos[index], index),
            ),
          // 初始加载中（对齐 iOS `initialLoading` → 「准备中...」）。
          if (_initialLoading) _initialLoadingView(),
          // 左上返回按钮（对齐 iOS `chevron.left`）。
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(
                  left: VboxSpacing.lg,
                  top: VboxSpacing.sm + 2,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onBack,
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(
                      Icons.chevron_left,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _initialLoadingView() {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(height: VboxSpacing.lg),
            Text(
              '准备中...',
              style: TextStyle(
                fontSize: VboxTypography.s15,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单卡：画面层 + 底部信息区（对齐 iOS 单卡结构）。
  Widget _buildPage(BananaMiniVideo video, int index) {
    final bool isCurrent = index == _index;
    final bool showSurface = isCurrent && _ready && _error == null &&
        _textureId != null;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (showSurface)
          // 画面层（Texture 不拦手势，对齐 iOS `allowsHitTesting(false)`）。
          VideoSurface(textureId: _textureId, aspectRatio: _aspectRatio)
        else
          _coverLayer(video, isCurrent),
        _infoOverlay(video, isCurrent),
      ],
    );
  }

  /// 封面 `blur(20)` 加载层（黑 0.25 遮罩 + 加载指示 / 失败重试）。
  Widget _coverLayer(BananaMiniVideo video, bool isCurrent) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: PlatformAsyncImage(url: video.cover, fit: BoxFit.cover),
        ),
        ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
        if (isCurrent) Center(child: _centerStatus()),
      ],
    );
  }

  Widget _centerStatus() {
    final String? err = _error;
    if (err != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.play_disabled_rounded,
            size: 40,
            color: Colors.white.withValues(alpha: 0.6),
          ),
          const SizedBox(height: VboxSpacing.md),
          Text(
            err,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _retry,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: VboxSpacing.lg,
                vertical: VboxSpacing.compact,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(VboxRadii.r14),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.refresh, size: 14, color: Colors.white),
                  SizedBox(width: VboxSpacing.xs),
                  Text(
                    '重试',
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return const SizedBox(
      width: 30,
      height: 30,
      child: CircularProgressIndicator(
        strokeWidth: 3,
        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
      ),
    );
  }

  /// 底部渐变信息区（对齐 iOS：头像 / 用户名 / 标题 / 计数 / 进度条 / 时间 / 倍速）。
  Widget _infoOverlay(BananaMiniVideo video, bool isCurrent) {
    final int positionSec = isCurrent ? _positionSec : 0;
    final int durationSec = isCurrent ? _durationSec : 0;
    final double progress = isCurrent ? _progress : 0.0;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.only(
          left: VboxSpacing.lg,
          right: VboxSpacing.lg,
          bottom: 40,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Colors.transparent,
              Colors.black.withValues(alpha: 0.75),
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                if (video.userAvatar.isNotEmpty) _avatar(video.userAvatar),
                if (video.userAvatar.isNotEmpty)
                  const SizedBox(width: VboxSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        video.userName,
                        style: const TextStyle(
                          fontSize: VboxTypography.s15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: VboxTypography.s13,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: VboxSpacing.md),
                // 上/下一个提示 + 无限加载标识「当前/总数+」。
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.keyboard_arrow_up,
                      size: 12,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    Text(
                      '${_index + 1}/${_videos.length}${_hasMore ? '+' : ''}',
                      style: TextStyle(
                        fontSize: VboxTypography.s10,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 12,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: VboxSpacing.sm),
            // 只读进度条（白 0.25 底 + 白填充，3pt，圆角 1.5）。
            _progressBar(progress),
            const SizedBox(height: VboxSpacing.sm),
            Row(
              children: <Widget>[
                _timeText(positionSec),
                const Spacer(),
                for (final double speed in _speeds) _speedButton(speed),
                const Spacer(),
                _timeText(durationSec),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(String url) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: ClipOval(
        child: PlatformAsyncImage(url: url, fit: BoxFit.cover),
      ),
    );
  }

  Widget _progressBar(double progress) {
    return SizedBox(
      width: double.infinity,
      height: 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(VboxRadii.progressBar),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) => Stack(
            children: <Widget>[
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.white.withValues(alpha: 0.25),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: c.maxWidth * progress,
                child: const ColoredBox(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeText(int sec) {
    return Text(
      _formatTime(sec),
      style: TextStyle(
        fontSize: VboxTypography.s11,
        fontFamily: 'monospace',
        color: Colors.white.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _speedButton(double speed) {
    final bool selected = _rate == speed;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setRate(speed),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Text(
          '${speed.toStringAsFixed(2)}x',
          style: TextStyle(
            fontSize: VboxTypography.s11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? Colors.white : Colors.white.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }

  /// 时间文案（对齐 iOS `formatTime`：`m:ss`）。
  static String _formatTime(int sec) {
    if (sec < 0 || !sec.isFinite) return '0:00';
    final int m = sec ~/ 60;
    final int s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
