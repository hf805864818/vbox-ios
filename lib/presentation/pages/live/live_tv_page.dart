/// 直播页（批次 E · E-01 / E-02 / E-03）。
///
/// 对齐 iOS `LiveTVView`：顶部**频道源胶囊**（当前源 + 切换源浮层）、
/// **分类胶囊**（横向滚动，按 `cat_N` 取循环调色板）、**双列频道卡**
/// （16:9 台标封面 + 频道名 + 线路数）。点击频道卡弹出 [LivePlayerSheet]
/// 接入播放（线路解析 + 切换，见 E-02）；长按弹出 [EpgSheet] 节目单
/// （日期切换 + 节目列表，见 E-03）。数据由 [LiveTvController] 提供
/// （源持久化 + 订阅源拉取/解析 + 动态分类 + 分组合并多线路）。
///
/// 契约键：`live_tv_current_source`（LiveTvController 内部读写）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/entities/live/live.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/vbox_haptics.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/vbox/vbox.dart';
import 'epg_sheet.dart';
import 'import_export.dart';
import 'live_player_sheet.dart';
import 'live_tv_controller.dart';

/// 直播页（频道源胶囊 + 分类胶囊 + 双列频道卡）。
class LiveTVPage extends StatefulWidget {
  /// 构造（[controller] 供测试注入；缺省自建并自管生命周期）。
  const LiveTVPage({
    super.key,
    this.controller,
    this.onPlayRoute,
    this.fileBridge,
  });

  /// 外部注入的控制器（null → 页面自建）。
  final LiveTvController? controller;

  /// 播放接入回调（null → 走 `PlayerController.instance`；测试注入）。
  final LiveRoutePlayHandler? onPlayRoute;

  /// 本地文件导入/导出桥（null → [MethodChannelLiveFileBridge]；测试注入）。
  final LiveFileBridge? fileBridge;

  @override
  State<LiveTVPage> createState() => _LiveTVPageState();
}

class _LiveTVPageState extends State<LiveTVPage> {
  late final LiveTvController _controller;
  late final LiveFileBridge _fileBridge;
  late final bool _ownsController;

  /// 当前选中分类（tid）与首帧加载中标记。
  String? _selectedTid;
  bool _loading = true;

  /// 右下角源切换浮动按钮的显隐（对齐 iOS `isFloatingButtonVisible`：
  /// 默认显示，10s 无交互后淡出，交互后重新显示）。
  bool _floatingVisible = true;
  DateTime _lastInteraction = DateTime.now();
  Timer? _floatingTimer;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? LiveTvController();
    _fileBridge = widget.fileBridge ?? MethodChannelLiveFileBridge();
    _startFloatingTimer();
    _bootstrap();
  }

  @override
  void dispose() {
    _floatingTimer?.cancel();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  /// 启动浮动按钮自动隐藏计时（对齐 iOS `startHideTimer`：每秒检查，
  /// 距上次交互 ≥ 10s 则淡出）。
  void _startFloatingTimer() {
    _floatingTimer?.cancel();
    _lastInteraction = DateTime.now();
    _floatingTimer = Timer.periodic(const Duration(seconds: 1), (Timer _) {
      if (!mounted) return;
      if (DateTime.now().difference(_lastInteraction).inSeconds >= 10 &&
          _floatingVisible) {
        setState(() => _floatingVisible = false);
      }
    });
  }

  /// 记录交互并重新显示浮动按钮（对齐 iOS `resetHideTimer`）。
  void _bumpFloating() {
    _lastInteraction = DateTime.now();
    if (!_floatingVisible && mounted) {
      setState(() => _floatingVisible = true);
    }
  }

  Future<void> _bootstrap() async {
    if (_ownsController) await _controller.init();
    await _controller.ensureLoaded();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _retry() async {
    final String? url = _controller.currentSource.sourceURL;
    if (url == null) return;
    if (mounted) setState(() => _loading = true);
    await _controller.fetchSubscribeChannels(url);
    if (mounted) setState(() => _loading = false);
  }

  LiveCategory? _activeCategory(List<LiveCategory> categories) {
    if (categories.isEmpty) return null;
    for (final LiveCategory c in categories) {
      if (c.tid == _selectedTid) return c;
    }
    return categories.first;
  }

  Future<void> _selectSource(LiveSourceType source) async {
    if (source.id == _controller.currentSource.id) return;
    setState(() => _selectedTid = null);
    await _controller.switchSource(source);
  }

  Future<void> _showSourceSheet() async {
    final LiveSourceType? picked = await showModalBottomSheet<LiveSourceType>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _SourceSheet(
        controller: _controller,
        fileBridge: _fileBridge,
      ),
    );
    if (picked != null) await _selectSource(picked);
  }

  /// 点击频道卡：弹出播放接入 Sheet（线路自动解析 + 连接首线路）。
  Future<void> _openChannel(LiveChannel channel) {
    // E5-2 触感补点：直播频道选择 light（对齐 iOS 频道点击）。
    VboxHaptics.light();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) =>
          LivePlayerSheet(channel: channel, onPlayRoute: widget.onPlayRoute),
    );
  }

  /// 长按频道卡：弹出节目单 Sheet（EPG，见 E-03）。
  Future<void> _openEpg(LiveChannel channel) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => EpgSheet(channel: channel),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('直播')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) {
          return Stack(
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_buildCategories() != null) _buildCategories()!,
                  Expanded(child: _buildBody()),
                ],
              ),
              // 右下角浮动源切换按钮（对齐 iOS `LiveTVView`：天线图标 +
              // 10s 无交互自动隐藏）。
              Positioned(
                right: VboxSpacing.lg,
                bottom: 80,
                child: AnimatedOpacity(
                  opacity: _floatingVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: !_floatingVisible,
                    child: _buildFloatingSourceButton(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ──────────────────────────── 右下角源切换浮动按钮 ────────────────────────────

  /// 浮动源切换按钮（对齐 iOS：44×44 圆形、天线图标、accent 色）。
  Widget _buildFloatingSourceButton() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.92),
      elevation: 3,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          _bumpFloating();
          _showSourceSheet();
        },
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            Icons.settings_input_antenna,
            size: VboxTypography.s18,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }

  // ──────────────────────────── 分类胶囊 ────────────────────────────

  Widget? _buildCategories() {
    final List<LiveCategory> categories = _controller.categories;
    if (categories.isEmpty) return null;
    final LiveCategory active = _activeCategory(categories)!;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: VboxSpacing.symmetric(
            horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm),
        itemCount: categories.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: VboxSpacing.md),
        itemBuilder: (BuildContext context, int index) {
          final LiveCategory c = categories[index];
          return _CategoryCapsule(
            category: c,
            selected: c.tid == active.tid,
            // E5-2 触感补点：频道分组切换 selection（对齐 iOS 分组 tab）。
            onTap: () {
              VboxHaptics.selection();
              setState(() => _selectedTid = c.tid);
            },
          );
        },
      ),
    );
  }

  // ──────────────────────────── 双列频道卡 ────────────────────────────

  Widget _buildBody() {
    if (_loading && _controller.categories.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _controller.lastError;
    if (error != null && _controller.categories.isEmpty) {
      return _ErrorRetry(message: error, onRetry: _retry);
    }
    final List<LiveCategory> categories = _controller.categories;
    if (categories.isEmpty) {
      return const _EmptyHint(text: '暂无频道\n点击右下角按钮切换直播源');
    }
    final LiveCategory active = _activeCategory(categories)!;
    final List<LiveChannel> channels = _controller.channelsForGroup(active.tid);
    if (channels.isEmpty) {
      return const _EmptyHint(text: '该分类暂无频道');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
          VboxSpacing.lg, VboxSpacing.sm, VboxSpacing.lg, VboxSpacing.lg),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: VboxSpacing.md,
        crossAxisSpacing: VboxSpacing.md,
        childAspectRatio: 16 / 11,
      ),
      itemCount: channels.length,
      itemBuilder: (BuildContext context, int index) => GestureDetector(
        onLongPress: () => _openEpg(channels[index]),
        child: _ChannelCard(
          channel: channels[index],
          onTap: () => _openChannel(channels[index]),
        ),
      ),
    );
  }
}

/// 分类胶囊（对齐 iOS `CategoryTabButton`：未选中 tint@10% 底 + tint 字，
/// 选中 tint 填充 + 白字；图标优先台标，缺省 tv 图标）。
class _CategoryCapsule extends StatelessWidget {
  const _CategoryCapsule({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final LiveCategory category;
  final bool selected;
  final VoidCallback onTap;

  static Color _tint(LiveCategory c) => VboxColors.liveCategoryPalette[
      c.paletteIndex % VboxColors.liveCategoryPalette.length];

  @override
  Widget build(BuildContext context) {
    final Color tint = _tint(category);
    final Color foreground = selected ? Colors.white : tint;
    final Color background = selected ? tint : tint.withValues(alpha: 0.10);

    return Material(
      color: background,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: VboxSpacing.symmetric(
              horizontal: VboxSpacing.lg, vertical: VboxSpacing.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (category.logo != null && category.logo!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: VboxSpacing.xs),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: PlatformAsyncImage(
                      url: category.logo,
                      fit: BoxFit.contain,
                      placeholderColor: Colors.transparent,
                      placeholder: Icon(Icons.live_tv,
                          size: VboxTypography.s14, color: foreground),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: VboxSpacing.xs),
                  child: Icon(Icons.live_tv,
                      size: VboxTypography.s14, color: foreground),
                ),
              Text(
                category.name,
                style: TextStyle(
                  fontSize: VboxTypography.s15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 频道卡（对齐 iOS `ChannelGridItem`：16:9 台标封面 + 线路数 + 频道名）。
class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.channel, required this.onTap});

  final LiveChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // E5-3 Semantics 补点：TV 焦点频道卡 label（频道名）。
    return Semantics(
      button: true,
      label: '直播频道 ${channel.name}',
      child: VboxCard(
        padding: EdgeInsets.zero,
        radius: VboxRadii.r12,
        onTap: onTap,
        child: Column(
          children: <Widget>[
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(VboxRadii.r12 - 1),
              ),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: scheme.surfaceContainerHighest,
                  child: PlatformAsyncImage(
                    url: channel.logo,
                    fit: BoxFit.contain,
                    placeholderColor: scheme.surfaceContainerHighest,
                    placeholder: Center(
                      child: Icon(
                        Icons.live_tv,
                        size: VboxTypography.s24,
                        color: Colors.orange.withValues(alpha: 0.60),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.sm, vertical: VboxSpacing.xs + 2),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${channel.routeCount}条线路',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: VboxTypography.s11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: VboxTypography.s14,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 56),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 切换源浮层（列出全部可用源 + 添加/删除/导入/导出，对齐 iOS
/// `LiveSourcePickerView`）。
class _SourceSheet extends StatefulWidget {
  const _SourceSheet({required this.controller, required this.fileBridge});

  final LiveTvController controller;
  final LiveFileBridge fileBridge;

  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  LiveTvController get _controller => widget.controller;

  Future<void> _addCustom(String name, String url) =>
      _controller.addCustomSource(name, url);

  Future<void> _removeCustom(LiveSourceType source) async {
    final int index = _customIndex(source);
    if (index >= 0) await _controller.removeCustomSourceAt(index);
  }

  int _customIndex(LiveSourceType source) => _controller.customSources
      .indexWhere((LiveSourceType s) => s.id == source.id);

  void _showAddDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => _AddSourceDialog(onSubmit: _addCustom),
    );
  }

  Future<void> _importLocal() async {
    final SelectedLiveFile? file = await widget.fileBridge.pickTextFile();
    if (file == null || !mounted) return;
    final List<SubscribeChannel> channels =
        LiveSourceImportExport.parseContent(file.content);
    if (channels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件内容解析为空')),
      );
      return;
    }
    await _controller.addLocalChannels(file.name, channels);
    await _controller.switchSource(LiveSourceType(
      kind: LiveSourceKind.custom,
      name: file.name,
      url: 'local://${file.name}',
    ));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _exportCustom(LiveSourceType source) async {
    final String name = source.name ?? 'custom';
    final String? url = source.url;
    if (url == null) return;
    try {
      String content;
      String fileName;
      if (url.startsWith('local://')) {
        final String localName = url.substring('local://'.length);
        final List<SubscribeChannel> channels =
            _controller.localChannelsMap[localName] ??
                const <SubscribeChannel>[];
        if (channels.isEmpty) {
          _toast('本地源已失效，请重新导入');
          return;
        }
        content = _controller.exportM3U(channels);
        fileName =
            LiveSourceImportExport.exportFileName(localName, isM3U: true);
      } else {
        final String? raw = await _controller.fetchRawContent(url);
        if (raw == null || raw.trim().isEmpty) {
          _toast('无法获取直播源内容');
          return;
        }
        content = raw;
        fileName = LiveSourceImportExport.exportFileName(
          name,
          isM3U: raw.trim().startsWith('#EXTM3U'),
        );
      }
      final String path =
          await LiveSourceImportExport.writeExportFile(fileName, content);
      await widget.fileBridge.shareFile(path);
      _toast('已导出：$fileName');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListenableBuilder(
          listenable: _controller,
          builder: (BuildContext context, Widget? _) {
            final List<LiveSourceType> sources = _controller.availableSources;
            final String currentId = _controller.currentSource.id;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    '选择直播源 ${sources.length}',
                    style: TextStyle(
                      fontSize: VboxTypography.s18,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                Flexible(
                    child: _sourceList(context, scheme, sources, currentId)),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.add_circle_outline,
                      color: Colors.orange.shade600),
                  title: const Text('添加自定义源'),
                  onTap: _showAddDialog,
                ),
                ListTile(
                  leading: Icon(Icons.folder_open, color: scheme.primary),
                  title: const Text('导入本地直播文件'),
                  onTap: _importLocal,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    '支持导入 M3U、TXT 等格式的直播源文件',
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sourceList(
    BuildContext context,
    ColorScheme scheme,
    List<LiveSourceType> sources,
    String currentId,
  ) {
    return ListView.separated(
      shrinkWrap: true,
      itemCount: sources.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final LiveSourceType source = sources[index];
        final bool selected = source.id == currentId;
        final bool isCustom = source.isCustom;
        return ListTile(
          leading: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isCustom ? Icons.link : Icons.settings_input_antenna,
              size: 20,
              color: scheme.primary,
            ),
          ),
          title: Text(
            source.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: isCustom
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      icon: Icon(Icons.ios_share, color: scheme.primary),
                      onPressed: () => _exportCustom(source),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: scheme.error),
                      onPressed: () => _removeCustom(source),
                    ),
                  ],
                )
              : (selected
                  ? Icon(Icons.check_circle, color: scheme.primary)
                  : null),
          onTap: () => Navigator.of(context).pop(source),
        );
      },
    );
  }
}

/// 添加自定义源对话框（对齐 iOS `showAddAlert`：源名称 + M3U/TXT URL）。
class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({required this.onSubmit});

  final Future<void> Function(String name, String url) onSubmit;

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();

  bool get _valid =>
      _name.text.trim().isNotEmpty && _url.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_valid) return;
    await widget.onSubmit(_name.text.trim(), _url.text.trim());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自定义源'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '源名称'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'M3U/TXT URL'),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
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
