/// 直播播放接入 Sheet（批次 E · E-02；Wave A · R-渲1 画面输出）。
///
/// 对齐 iOS `LivePlayerSheet`：点击频道卡弹出，自动解析线路并连接首线路
/// （`resolveAllSources` = 直接取 [LiveChannel.sources]）。顶部 16:9 预览区
/// 内联渲染视频画面（对齐 iOS `MiniPlayerView`：sheet 内小窗，非全屏播放页），
/// 下方为线路列表切换。
///
/// [onPlayRoute] 供测试注入，避免单测触碰真实方法通道；缺省走
/// [PlayerController.instance]（live 路由）并订阅其纹理输出面。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/entities/live/live.dart';
import '../../../domain/entities/player/player.dart';
import '../../../platform/player/player_controller.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/player/video_surface.dart';
import 'epg_sheet.dart';

/// 直播线路播放回调（url → 打开并播放）。
typedef LiveRoutePlayHandler = Future<void> Function(String url);

/// 截断长 URL 显示（中段省略）。
String _truncateUrl(String url) {
  if (url.length <= 48) return url;
  return '${url.substring(0, 24)}...${url.substring(url.length - 20)}';
}

/// 直播播放 Sheet（线路解析 + 连接 + 线路切换）。
class LivePlayerSheet extends StatefulWidget {
  /// 构造。
  const LivePlayerSheet({super.key, required this.channel, this.onPlayRoute});

  /// 待播放频道。
  final LiveChannel channel;

  /// 播放回调（null → [PlayerController.instance]）。
  final LiveRoutePlayHandler? onPlayRoute;

  @override
  State<LivePlayerSheet> createState() => _LivePlayerSheetState();
}

class _LivePlayerSheetState extends State<LivePlayerSheet> {
  late final List<String> _routes;
  int _current = 0;
  bool _connecting = true;
  String? _error;

  /// 输出面纹理句柄（R-渲1；null = 无纹理 → 状态占位）。
  int? _textureId;

  /// 视频纵横比（宽 / 高；null = 未上报 → 按 16:9 容器铺满）。
  double? _aspectRatio;

  /// 是否订阅了 [PlayerController] 输出面（仅缺省回调时；注入回调不订阅）。
  bool _bindController = false;

  /// 控制条显隐（对齐 iOS `MiniPlayerView`：点击画面切换，3s 自动隐藏）。
  bool _showControls = false;
  Timer? _hideTimer;

  /// 播放中标记（对齐 iOS 控制条播放/暂停按钮）。
  bool _playing = true;

  @override
  void initState() {
    super.initState();
    _routes = _resolveRoutes();
    if (widget.onPlayRoute == null) {
      _bindController = true;
      final PlayerController controller = PlayerController.instance;
      controller.onSurfaceChanged = (int? id) {
        if (mounted) setState(() => _textureId = id);
      };
      controller.onVideoSize = (int width, int height) {
        if (mounted) setState(() => _aspectRatio = width / height);
      };
    }
    _autoPlay();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_bindController) {
      final PlayerController controller = PlayerController.instance;
      controller.onSurfaceChanged = null;
      controller.onVideoSize = null;
    }
    super.dispose();
  }

  /// 点击画面：切换控制条显隐并重置自动隐藏计时（对齐 iOS `MiniPlayerView`）。
  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    _resetHideTimer();
  }

  /// 3s 无操作自动隐藏控制条（对齐 iOS `resetHideTimer`）。
  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _showControls) setState(() => _showControls = false);
    });
  }

  /// 播放 / 暂停（仅缺省控制器绑定时生效）。
  Future<void> _togglePlay() async {
    _resetHideTimer();
    if (!_bindController) {
      setState(() => _playing = !_playing);
      return;
    }
    final PlayerController controller = PlayerController.instance;
    if (_playing) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() => _playing = !_playing);
  }

  /// 进入全屏播放（对齐 iOS `MiniPlayerView.showFullScreen`）。
  Future<void> _openFullScreen() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _showControls = false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) => _LiveFullScreen(
          textureId: _textureId,
          aspectRatio: _aspectRatio,
        ),
      ),
    );
    if (mounted) _resetHideTimer();
  }

  List<String> _resolveRoutes() {
    final List<String> sources = widget.channel.sources;
    if (sources.isNotEmpty) return List<String>.of(sources);
    final String playURL = widget.channel.playURL;
    if (playURL.isNotEmpty) return <String>[playURL];
    return <String>[];
  }

  Future<void> _autoPlay() {
    if (_routes.isEmpty) {
      setState(() {
        _connecting = false;
        _error = '暂无可用线路';
      });
      return Future<void>.value();
    }
    return _play(_current);
  }

  Future<void> _play(int index) async {
    if (index < 0 || index >= _routes.length) return;
    setState(() {
      _current = index;
      _connecting = true;
      _error = null;
    });
    try {
      final LiveRoutePlayHandler handler = widget.onPlayRoute ?? _defaultPlay;
      await handler(_routes[index]);
      if (mounted) setState(() => _connecting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '连接失败：$e';
        });
      }
    }
  }

  Future<void> _defaultPlay(String url) async {
    final PlayerController controller = PlayerController.instance;
    await controller.open(
      PlayerSource(url: url, title: widget.channel.name, isLive: true),
    );
    await controller.play();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: maxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _titleRow(scheme),
            Flexible(flex: 9, child: _preview()),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  VboxSpacing.lg, VboxSpacing.md, VboxSpacing.lg, VboxSpacing.xs),
              child: Text(
                '共 ${_routes.length} 条线路',
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Flexible(flex: 11, child: _routeList(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _titleRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          VboxSpacing.lg, VboxSpacing.sm, VboxSpacing.sm, VboxSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              widget.channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s18,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          // 对齐 iOS：16:9 小窗（黑底 + 画面层 + 状态层叠加）。
          aspectRatio: 16 / 9,
          child: GestureDetector(
            onTap: _toggleControls,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                VideoSurface(
                  textureId: _textureId,
                  aspectRatio: _aspectRatio,
                ),
                if (_textureId == null) Center(child: _previewBody()),
                if (_showControls) _controlsOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 控制条叠加层（对齐 iOS `MiniPlayerView`：右上全屏 + 居中播放/暂停；
  /// E4-2 左上补「回看」入口，对齐 iOS `LiveTVView.swift:1693-1702`
  /// 控制条「回看」按钮 → 打开 [EpgSheet]）。
  Widget _controlsOverlay() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.28),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: 2,
            left: 2,
            child: IconButton(
              tooltip: '回看',
              onPressed: () {
                _resetHideTimer();
                showModalBottomSheet<void>(
                  context: context,
                  useSafeArea: true,
                  isScrollControlled: true,
                  showDragHandle: true,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  builder: (BuildContext sheetContext) => SizedBox(
                    height: MediaQuery.of(sheetContext).size.height * 0.75,
                    child: EpgSheet(channel: widget.channel),
                  ),
                );
              },
              icon: const Icon(
                Icons.history_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: '全屏',
              onPressed: _openFullScreen,
              icon: const Icon(
                Icons.arrow_outward,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          Center(
            child: IconButton(
              tooltip: _playing ? '暂停' : '播放',
              onPressed: _togglePlay,
              iconSize: 40,
              icon: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewBody() {
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 40, color: Colors.orange),
          const SizedBox(height: VboxSpacing.sm),
          Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => _play(_current),
            child: const Text('重试', style: TextStyle(color: Colors.orange)),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_connecting) ...<Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
                color: Colors.white70, strokeWidth: 2.5),
          ),
          const SizedBox(height: VboxSpacing.sm),
          const Text('正在连接直播流…',
              style: TextStyle(fontSize: 13, color: Colors.white70)),
        ] else ...<Widget>[
          const Icon(Icons.play_circle_outline, size: 48, color: Colors.white54),
          const SizedBox(height: VboxSpacing.sm),
          const Text('线路已就绪',
              style: TextStyle(fontSize: 13, color: Colors.white70)),
        ],
      ],
    );
  }

  Widget _routeList(ColorScheme scheme) {
    if (_routes.isEmpty) return const SizedBox.shrink();
    return ListView.separated(
      padding: VboxSpacing.symmetric(
          horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm),
      itemCount: _routes.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: VboxSpacing.sm),
      itemBuilder: (BuildContext context, int index) {
        final bool active = index == _current;
        return _RouteItem(
          index: index,
          url: _routes[index],
          active: active,
          scheme: scheme,
          onTap: () => _play(index),
        );
      },
    );
  }
}

/// 单条线路项（对齐 iOS：编号圆 + 线路名/截断 URL + 播放指示）。
class _RouteItem extends StatelessWidget {
  const _RouteItem({
    required this.index,
    required this.url,
    required this.active,
    required this.scheme,
    required this.onTap,
  });

  final int index;
  final String url;
  final bool active;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color accent = scheme.primary;
    return Material(
      color: active ? accent.withValues(alpha: 0.08) : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VboxRadii.r12),
        side: BorderSide(
          color: active ? accent.withValues(alpha: 0.3) : scheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(VboxSpacing.sm),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 16,
                backgroundColor: active ? accent : scheme.surfaceContainerHighest,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: VboxTypography.s14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: VboxSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '线路 ${index + 1}',
                      style: TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w500,
                        color: active ? accent : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _truncateUrl(url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: VboxTypography.s11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                active ? Icons.play_circle_fill : Icons.play_circle,
                size: 24,
                color: active ? accent : scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 直播全屏播放页（对齐 iOS `FullScreenPlayerView`：黑底铺满 + 退出按钮）。
///
/// 复用 [LivePlayerSheet] 已订阅的 [PlayerController] 纹理输出面（[textureId]
/// / [aspectRatio] 快照传入），不重复订阅避免抢回调。
class _LiveFullScreen extends StatelessWidget {
  const _LiveFullScreen({
    required this.textureId,
    this.aspectRatio,
  });

  /// 输出面纹理句柄（null → 显示无画面占位）。
  final int? textureId;

  /// 视频纵横比（宽 / 高；null → 铺满）。
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          VideoSurface(textureId: textureId, aspectRatio: aspectRatio),
          if (textureId == null)
            const Center(
              child: Text(
                '正在连接直播流…',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: '退出全屏',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(
                  Icons.fullscreen_exit,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}