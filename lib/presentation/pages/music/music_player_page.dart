/// 表现层：全屏音乐播放器（批次 G · G-音1）。
///
/// 唯一真相源：iOS `MusicPlayerFullView`
/// （`vbox/Views/MusicPlayerViews.swift:256`，含 `MusicQueueSheet` L723 与
/// `PlaybackNoticeBanner` L699）。
///
/// 对齐口径：
///  - 主色渐变兜底背景（`accent` 0.92 → 0.55，顶 → 底）+ 封面模糊铺底
///    （blur 20 + 黑 0.4 叠层；加载中黑 0.25，失败透出渐变）；
///  - 顶栏：下拉箭头（关闭）· 「正在播放」· 播放模式循环按钮（主色）；
///  - 封面 260×260 圆角 16 + 投影（无封面时灰底 + 音符占位）；
///  - 歌名 20 bold + 来源 14（白 0.6）；进度条 + 两端等宽时间；
///  - 控制：上一首 32 / 播放暂停 40（加载中转沙漏）/ 下一首 32，队列 ≤1 时禁用切歌；
///  - 「播放队列 (n)」入口 + 歌词/封面切换；歌词主导态空歌词显示「该来源暂无歌词」，
///    封面主导态底部滚动歌词（无歌词整区隐藏）；
///  - 顶部播放提示横幅（3s 自动消失）；
///  - 下拉 > 80pt 且垂直为主 → 关闭全屏页。
///
/// 落地差异（如实登记）：iOS 歌词经 LX 插件异步拉取；Flutter 侧消费队列条目自带
/// 的 `lyric`（LRC）字段同步解析，无数据即隐藏（与 iOS「无歌词整区隐藏」一致）。
/// 音质切换条（E4-1）条件显示：`availQualities.length > 1` 时出现（数据由音乐域
/// resolver 注入；未注入时 `switchQuality` 降级提示，条目无多档音质则不显示）。
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../domain/entities/music/music.dart';
import '../../../platform/player/music_player.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/music/music_queue_sheet.dart';
import '../../widgets/platform_async_image.dart';

/// 全屏音乐播放器页。
class MusicPlayerPage extends StatefulWidget {
  /// 构造。
  const MusicPlayerPage({super.key, this.controller});

  /// 播放控制器（缺省取全局单例）。
  final MusicPlayerController? controller;

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  late final MusicPlayerController _player =
      widget.controller ?? MusicPlayerController.instance;

  double _seekValue = 0;
  bool _isSeeking = false;
  bool _showLyrics = false;

  /// 下拉关闭手势累计位移（对齐 iOS `DragGesture.translation.height`）。
  double _dragDy = 0;
  List<_LyricLine> _lyricLines = const <_LyricLine>[];
  String? _lyricSourceId;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayerChanged);
    _loadLyric();
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    if (_player.currentSong?.id != _lyricSourceId) {
      setState(_loadLyric);
    }
  }

  /// 从当前条目解析 LRC 歌词（对齐 iOS `loadLyricForCurrent` 的同步分支）。
  void _loadLyric() {
    final MusicQueueItem? song = _player.currentSong;
    _lyricSourceId = song?.id;
    _lyricLines = _parseLrc(song?.lyric);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: _player,
        builder: (BuildContext context, Widget? _) {
          final MusicQueueItem? song = _player.currentSong;
          final Color accent = Theme.of(context).colorScheme.primary;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _dragDy = 0,
            onVerticalDragUpdate: (DragUpdateDetails d) =>
                _dragDy += d.delta.dy,
            onVerticalDragEnd: (DragEndDetails _) {
              // 下拉 > 80pt → 关闭（对齐 iOS `DragGesture(minimumDistance: 30)`）。
              if (_dragDy > 80) Navigator.of(context).maybePop();
              _dragDy = 0;
            },
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _background(accent, song)),
                SafeArea(
                  child: Column(
                    children: <Widget>[
                      _topBar(accent),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: <Widget>[
                              const SizedBox(height: VboxSpacing.xl),
                              _artwork(song, accent),
                              const SizedBox(height: VboxSpacing.xl),
                              _title(song),
                              const SizedBox(height: VboxSpacing.lg),
                              _progress(accent),
                              const SizedBox(height: VboxSpacing.md),
                              _controls(song),
                              const SizedBox(height: VboxSpacing.xs),
                              _qualityBar(song),
                              const SizedBox(height: VboxSpacing.md),
                              _queueAndLyricToggle(accent),
                              _lyricSection(accent),
                              const SizedBox(height: VboxSpacing.xl),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_player.notice != null)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 46,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _PlaybackNoticeBanner(text: _player.notice!),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ───────────────────────── 背景 ─────────────────────────

  Widget _background(Color accent, MusicQueueItem? song) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                accent.withValues(alpha: 0.92),
                accent.withValues(alpha: 0.55),
              ],
            ),
          ),
        ),
        if (song != null && song.coverURL.trim().isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                PlatformAsyncImage(url: song.coverURL, fit: BoxFit.cover),
                ColoredBox(color: Colors.black.withValues(alpha: 0.4)),
              ],
            ),
          ),
      ],
    );
  }

  // ───────────────────────── 顶栏 ─────────────────────────

  Widget _topBar(Color accent) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: VboxSpacing.xxl, vertical: 10),
      color: Colors.black.withValues(alpha: 0.15),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('music_full_close'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down,
                size: 28, color: Colors.white),
          ),
          const Spacer(),
          Text(
            '正在播放',
            style: TextStyle(
                fontSize: VboxTypography.s13,
                color: Colors.white.withValues(alpha: 0.7)),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey<String>('music_full_repeat'),
            onPressed: _player.cycleRepeatMode,
            icon:
                Icon(_repeatIcon(_player.repeatMode), size: 20, color: accent),
          ),
        ],
      ),
    );
  }

  IconData _repeatIcon(MusicRepeatMode mode) => switch (mode) {
        MusicRepeatMode.sequential => Icons.repeat,
        MusicRepeatMode.single => Icons.repeat_one,
        MusicRepeatMode.shuffle => Icons.shuffle,
      };

  // ───────────────────────── 封面 / 标题 ─────────────────────────

  Widget _artwork(MusicQueueItem? song, Color accent) {
    final bool hasCover = song != null && song.coverURL.trim().isNotEmpty;
    return Container(
      width: 260,
      height: 260,
      decoration: BoxDecoration(
        color: hasCover ? null : VboxColors.systemGray4Dark,
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: hasCover
          ? PlatformAsyncImage(url: song.coverURL, fit: BoxFit.cover)
          : Icon(
              Icons.music_note,
              size: 50,
              color: Colors.white.withValues(alpha: 0.5),
            ),
    );
  }

  Widget _title(MusicQueueItem? song) {
    return Column(
      children: <Widget>[
        Text(
          song?.name ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: VboxTypography.s18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: VboxSpacing.xs),
        Text(
          song?.artist ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  // ───────────────────────── 进度 ─────────────────────────

  Widget _progress(Color accent) {
    final double total = _player.duration.inMilliseconds > 0
        ? _player.duration.inMilliseconds.toDouble()
        : 1;
    final double value =
        (_isSeeking ? _seekValue : _player.position.inMilliseconds.toDouble())
            .clamp(0, total);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xxl),
      child: Column(
        children: <Widget>[
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.15),
              trackHeight: 3,
            ),
            child: Slider(
              value: value,
              max: total,
              onChangeStart: (double v) => setState(() {
                _isSeeking = true;
                _seekValue = v;
              }),
              onChanged: (double v) => setState(() => _seekValue = v),
              onChangeEnd: (double v) async {
                await _player.seek(Duration(milliseconds: v.round()));
                if (mounted) setState(() => _isSeeking = false);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.sm),
            child: Row(
              children: <Widget>[
                Text(
                    _formatTime(_isSeeking
                        ? Duration(milliseconds: _seekValue.round())
                        : _player.position),
                    style: _timeStyle),
                const Spacer(),
                Text(_formatTime(_player.duration), style: _timeStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static final TextStyle _timeStyle = TextStyle(
    fontSize: VboxTypography.s11,
    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    color: Colors.white.withValues(alpha: 0.6),
  );

  static String _formatTime(Duration d) {
    final int total = d.inSeconds;
    if (total <= 0) return '00:00';
    final String m = (total ~/ 60).toString().padLeft(2, '0');
    final String s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ───────────────────────── 控制 ─────────────────────────

  Widget _controls(MusicQueueItem? song) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // E5-3 Semantics 补点：上一首。
        Semantics(
          button: true,
          label: '上一首',
          child: IconButton(
            key: const ValueKey<String>('music_full_prev'),
            onPressed: _player.canSkip ? _player.playPrevious : null,
            icon: Icon(Icons.fast_rewind,
                size: 32,
                color: _player.canSkip ? Colors.white : Colors.white38),
          ),
        ),
        const SizedBox(width: VboxSpacing.xxl),
        // E5-3 Semantics 补点：播放 / 暂停（动态 label）。
        Semantics(
          button: true,
          label: _player.isLoading ? '加载中' : (_player.isPlaying ? '暂停' : '播放'),
          child: IconButton(
            key: const ValueKey<String>('music_full_play_pause'),
            onPressed: song == null ? null : _player.togglePlayPause,
            icon: Icon(
              _player.isLoading
                  ? Icons.hourglass_empty
                  : (_player.isPlaying ? Icons.pause : Icons.play_arrow),
              size: 44,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: VboxSpacing.xxl),
        // E5-3 Semantics 补点：下一首。
        Semantics(
          button: true,
          label: '下一首',
          child: IconButton(
            key: const ValueKey<String>('music_full_next'),
            onPressed: _player.canSkip ? _player.playNext : null,
            icon: Icon(Icons.fast_forward,
                size: 32,
                color: _player.canSkip ? Colors.white : Colors.white38),
          ),
        ),
      ],
    );
  }

  // ───────────────────────── 队列 / 歌词切换 ─────────────────────────

  /// 音质切换条（批次 E · E4-1；对齐 iOS 音质条：多档音质 > 1 时显示，
  /// 当前档高亮，点击 [MusicPlayerController.switchQuality]）。
  Widget _qualityBar(MusicQueueItem? song) {
    final List<String> qualities = song?.availQualities ?? const <String>[];
    if (qualities.length <= 1) return const SizedBox.shrink();
    final String current = song?.quality ?? qualities.first;
    final Color accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.xxl),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: VboxSpacing.sm,
        runSpacing: VboxSpacing.xs,
        children: <Widget>[
          for (final String q in qualities)
            ChoiceChip(
              key: ValueKey<String>('music_quality_$q'),
              label: Text(q),
              selected: q == current,
              onSelected: (_) => unawaited(_player.switchQuality(q)),
              labelStyle: TextStyle(
                fontSize: VboxTypography.s12,
                color:
                    q == current ? accent : Colors.white.withValues(alpha: 0.7),
              ),
              selectedColor: accent.withValues(alpha: 0.25),
              checkmarkColor: accent,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _queueAndLyricToggle(Color accent) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        TextButton.icon(
          key: const ValueKey<String>('music_full_queue'),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (BuildContext context) =>
                MusicQueueSheet(controller: widget.controller),
          ),
          icon: Icon(Icons.list,
              size: 14, color: Colors.white.withValues(alpha: 0.7)),
          label: Text(
            '播放队列 (${_player.queue.length})',
            style: TextStyle(
                fontSize: VboxTypography.s12,
                color: Colors.white.withValues(alpha: 0.7)),
          ),
        ),
        const SizedBox(width: VboxSpacing.md),
        TextButton.icon(
          key: const ValueKey<String>('music_full_lyric_toggle'),
          onPressed: () => setState(() => _showLyrics = !_showLyrics),
          icon: Icon(
            _showLyrics ? Icons.photo : Icons.format_quote,
            size: 14,
            color: _showLyrics ? accent : Colors.white.withValues(alpha: 0.7),
          ),
          label: Text(
            _showLyrics ? '封面' : '歌词',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: _showLyrics ? accent : Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }

  /// 歌词区（封面主导态底部滚动；歌词主导态由 [_lyricSection] 上方的空态承担）。
  Widget _lyricSection(Color accent) {
    if (_showLyrics) {
      if (_lyricLines.isEmpty) return _emptyLyricHint();
      return Padding(
        padding: const EdgeInsets.only(top: VboxSpacing.md),
        child: _lyricList(accent, height: 360),
      );
    }
    if (_lyricLines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: VboxSpacing.md),
      child: _lyricList(accent, height: 200),
    );
  }

  Widget _emptyLyricHint() {
    return Padding(
      padding: const EdgeInsets.only(top: VboxSpacing.xxl),
      child: Column(
        children: <Widget>[
          Icon(Icons.format_quote,
              size: 40, color: Colors.white.withValues(alpha: 0.35)),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            '该来源暂无歌词',
            style: TextStyle(
                fontSize: 14, color: Colors.white.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _lyricList(Color accent, {required double height}) {
    final int active = _activeLyricIndex;
    return SizedBox(
      height: height,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: VboxSpacing.sm),
        itemCount: _lyricLines.length,
        itemBuilder: (BuildContext context, int index) {
          final bool isActive = index == active;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              _lyricLines[index].text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: height > 250 ? 17 : 14,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? accent : Colors.white.withValues(alpha: 0.55),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 当前激活歌词行下标（对齐 iOS `activeLyricIndex`）。
  int get _activeLyricIndex {
    if (_lyricLines.isEmpty) return -1;
    final double t = _player.position.inMilliseconds / 1000;
    int active = 0;
    for (int i = 0; i < _lyricLines.length; i++) {
      if (_lyricLines[i].seconds <= t) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  /// 解析 LRC（对齐 iOS `parseLRC`，支持同行为多时间戳）。
  static List<_LyricLine> _parseLrc(String? lrc) {
    final String text = (lrc ?? '').trim();
    if (text.isEmpty) return const <_LyricLine>[];
    final RegExp tag = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');
    final List<_LyricLine> out = <_LyricLine>[];
    for (final String rawLine in text.split(RegExp(r'\r?\n'))) {
      final String line = rawLine.trim();
      if (line.isEmpty) continue;
      final Iterable<RegExpMatch> matches = tag.allMatches(line);
      if (matches.isEmpty) continue;
      int matchedEnd = 0;
      for (final RegExpMatch m in matches) {
        matchedEnd = m.end > matchedEnd ? m.end : matchedEnd;
      }
      final String content = line.substring(matchedEnd).trim();
      if (content.isEmpty) continue;
      for (final RegExpMatch m in matches) {
        final int mm = int.tryParse(m.group(1) ?? '0') ?? 0;
        final int ss = int.tryParse(m.group(2) ?? '0') ?? 0;
        double t = (mm * 60 + ss).toDouble();
        final String? frac = m.group(3);
        if (frac != null && frac.isNotEmpty) {
          t += (int.tryParse(frac) ?? 0) / _pow10(frac.length);
        }
        out.add(_LyricLine(t, content));
      }
    }
    out.sort((_LyricLine a, _LyricLine b) => a.seconds.compareTo(b.seconds));
    return out;
  }

  static double _pow10(int n) {
    double v = 1;
    for (int i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }
}

/// 一行歌词（时间 + 文本）。
class _LyricLine {
  const _LyricLine(this.seconds, this.text);

  /// 秒。
  final double seconds;

  /// 文本。
  final String text;
}

/// 顶部播放提示横幅（对齐 iOS `PlaybackNoticeBanner`）。
class _PlaybackNoticeBanner extends StatelessWidget {
  const _PlaybackNoticeBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: VboxSpacing.xxl),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius:
            const BorderRadius.all(Radius.circular(VboxRadii.capsule)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.warning_amber_rounded,
              size: 14, color: Colors.white),
          const SizedBox(width: VboxSpacing.sm),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
