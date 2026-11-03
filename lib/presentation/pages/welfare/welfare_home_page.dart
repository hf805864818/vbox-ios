/// 福利专区首页（批次 H · H-06）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/RemoteWelfareHomeView.swift`
///   · `tabBar`（L119-L154）：三段等宽分段，选中 = 实心渐变 + 白字；
///   · `platformGrid(for:)`（L174-L243）：`LazyVGrid` 4 列 + `RemotePlatformIconCard`，
///     空态 = `square.grid.3x3`（40）+「此分类下暂无平台」（15, secondary）；
///   · 网格内边距 `.horizontal 16 / .top 8 / .bottom 100`。
///
/// 数据来自 [WelfarePlatformController]（H-01）：进入页面 `bootstrap()`（幂等）
/// 恢复缓存并后台刷新；分段切换只切**当前分类的网格**，不重新联网。
///
/// 与 iOS 的差异（如实登记）：
///   · iOS 平台图标为 SF Symbol（`platform.icon`），Flutter 无法渲染 → 按
///     [welfarePlatformIcon] 映射 Material 近似图标，未知符号回退 `apps`。
///
/// 编辑排序（H-07，对齐 iOS `RemoteWelfareHomeView` 编辑模式）：
///   · 长按卡片 0.5s 进入编辑（medium 震动），提示条「长按卡片拖动排序，
///     拖到边缘自动滚动」+「完成」退出并持久化；
///   · 编辑态卡片长按 0.4s 拾取（light 震动）→ 拖拽跟手 + 最近格换位
///     （selection 震动）→ 松手落位（medium 震动），三级反馈对齐 iOS；
///   · 拖到视口上下 100pt 边缘自动滚动（3pt/帧 × 速度因子 0.3~1.0）；
///   · 排序按分类持久化至 `fuli_remote_platform_order_v2`（iOS 同键同结构：
///     `{categoryKey: [platformKey, ...]}`，远端新增平台追加在末尾）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/welfare/welfare.dart';
import '../../../domain/services/banana_xjsp_service.dart';
import '../../../domain/services/daily_battle_service.dart';
import '../../../domain/services/fuli_base_service.dart';
import '../../../domain/services/kanliao_service.dart';
import '../../../domain/services/welfare_js_spider_service.dart';
import '../../../domain/services/welfare_python_spider_service.dart';
import '../../lifecycle/vbox_lifecycle_mixin.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/vbox_haptics.dart';
import '../../welfare/welfare_platform_controller.dart';
import '../../welfare/welfare_platform_router.dart';
import '../../widgets/vbox/vbox.dart';
import 'banana_xjsp_home_page.dart';
import 'daily_battle_home_page.dart';
import 'kanliao_home_page.dart';
import 'unsupported_platform_page.dart';
import 'welfare_spider_home_page.dart';
import 'welfare_spider_main_page.dart';

/// 福利专区首页（远程源版，三栏目 + 平台网格）。
class WelfareHomePage extends StatefulWidget {
  /// 构造。
  const WelfareHomePage({super.key});

  @override
  State<WelfareHomePage> createState() => _WelfareHomePageState();
}

class _WelfareHomePageState extends State<WelfareHomePage>
    with VboxLifecycleMixin {
  /// 当前栏目（默认「视频」，对齐 iOS `selectedTab = .video`）。
  VboxWelfareCategory _tab = VboxWelfareCategory.video;

  /// 平台路由分发器（H-02）。
  final WelfarePlatformRouter _router = WelfarePlatformRouter();

  // ─────────────── 编辑排序状态（对齐 iOS `isEditMode` / `orderedPlatforms`） ───────────────

  /// 是否处于编辑排序模式。
  bool _isEditMode = false;

  /// 用户拖拽后的平台顺序（按分类缓存；`null` → 用远程默认顺序）。
  final Map<WelfarePlatformCategory, List<WelfarePlatform>> _ordered =
      <WelfarePlatformCategory, List<WelfarePlatform>>{};

  /// 编辑网格滚动控制器（边缘自动滚动用）。
  final ScrollController _gridScroll = ScrollController();

  /// 边缘自动滚动定时器（16ms/帧，对齐 iOS CADisplayLink）。
  Timer? _autoScrollTimer;

  /// 当前自动滚动速度因子（-1 ~ 1，0 停止）。
  double _autoScrollSpeed = 0;

  @override
  void initState() {
    super.initState();
    // 幂等：仅在首次进入时恢复缓存 + 后台刷新。
    context.read<WelfarePlatformController>().bootstrap();
    // 对齐 iOS `onAppear` → `loadOrder()`：恢复用户排序。
    unawaited(_loadOrder());
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _gridScroll.dispose();
    super.dispose();
  }

  /// 回前台重引导（UI-E4，对齐 iOS `RemoteWelfareHomeView.onAppear` 的
  /// `bootstrap()` + `refresh()` + `loadOrder()`；bootstrap 幂等）。
  @override
  void onAppResumed() {
    context.read<WelfarePlatformController>().bootstrap();
    unawaited(_loadOrder());
  }

  /// 当前栏目对应的领域分类（枚举名与契约 key 一致：video / live / comic）。
  WelfarePlatformCategory get _category =>
      WelfarePlatformCategory.fromKey(_tab.name) ??
      WelfarePlatformCategory.video;

  @override
  Widget build(BuildContext context) {
    final WelfarePlatformController controller =
        context.watch<WelfarePlatformController>();
    final List<WelfarePlatform> platforms =
        _currentOrderedPlatforms(_category, controller.platformsIn(_category));

    return Scaffold(
      appBar: AppBar(
        title: const Text('福利专区'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _onRefresh(controller),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          VboxWelfareTabs(
            selected: _tab,
            onSelected: (VboxWelfareCategory tab) {
              _stopAutoScroll();
              setState(() => _tab = tab);
            },
          ),
          // 编辑模式提示条（对齐 iOS `editModeBar`）。
          if (_isEditMode) _buildEditModeBar(),
          Expanded(child: _content(controller, platforms)),
        ],
      ),
    );
  }

  /// 编辑模式提示条（对齐 iOS `editModeBar`：左提示 12pt secondary +
  /// 右「完成」14pt semibold accent）。
  Widget _buildEditModeBar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 6,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '长按卡片拖动排序，拖到边缘自动滚动',
              style: TextStyle(
                fontSize: 12,
                color: scheme.outline,
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _exitEditMode,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                '完成',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onRefresh(WelfarePlatformController controller) {
    if (!controller.switchEnabled) {
      VboxToast.show(context, '请先在「我的 → 福利专区」启用远程源');
      return;
    }
    controller.refresh();
  }

  // ─────────────── 排序持久化（对齐 iOS `saveOrder` / `loadOrder`） ───────────────

  /// 恢复用户排序（key: `fuli_remote_platform_order_v2`；结构
  /// `{categoryKey: [platformKey, ...]}` 与 iOS 完全一致）。
  Future<void> _loadOrder() async {
    final WelfarePlatformController controller =
        context.read<WelfarePlatformController>();
    final String raw =
        await PrefsManager.instance.getString('fuli_remote_platform_order_v2');
    if (raw.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final Map<WelfarePlatformCategory, List<WelfarePlatform>> next =
        <WelfarePlatformCategory, List<WelfarePlatform>>{};
    decoded.forEach((String key, Object? value) {
      final WelfarePlatformCategory? cat = WelfarePlatformCategory.fromKey(key);
      if (cat == null || value is! List<dynamic>) return;
      final List<WelfarePlatform> all = controller.platformsIn(cat);
      if (all.isEmpty) return;
      // 按 key 顺序恢复（对齐 iOS `order.compactMap`）。
      final List<WelfarePlatform> ordered = <WelfarePlatform>[];
      for (final Object? pk in value) {
        if (pk is! String) continue;
        for (final WelfarePlatform p in all) {
          if (p.platformKey == pk) ordered.add(p);
        }
      }
      // 追加远端新增平台（对齐 iOS `ordered + remaining`）。
      final List<WelfarePlatform> remaining = <WelfarePlatform>[
        for (final WelfarePlatform p in all)
          if (!ordered
              .any((WelfarePlatform o) => o.platformKey == p.platformKey))
            p,
      ];
      next[cat] = <WelfarePlatform>[...ordered, ...remaining];
    });
    if (next.isEmpty || !mounted) return;
    setState(() {
      _ordered
        ..clear()
        ..addAll(next);
    });
  }

  /// 保存用户排序（对齐 iOS `saveOrder`：无排序数据不写）。
  Future<void> _saveOrder() async {
    if (_ordered.isEmpty) return;
    final Map<String, List<String>> data = <String, List<String>>{
      for (final MapEntry<WelfarePlatformCategory, List<WelfarePlatform>> e
          in _ordered.entries)
        e.key.key: <String>[
          for (final WelfarePlatform p in e.value) p.platformKey,
        ],
    };
    await PrefsManager.instance.set(
      'fuli_remote_platform_order_v2',
      jsonEncode(data),
    );
  }

  // ─────────────── 编辑模式（对齐 iOS 编辑提示条 + 三级震动） ───────────────

  /// 长按进入编辑（对齐 iOS `onLongPressGesture` → medium 震动）。
  void _enterEditMode() {
    VboxHaptics.medium();
    setState(() => _isEditMode = true);
  }

  /// 点「完成」退出编辑并持久化（对齐 iOS `isEditMode = false; saveOrder()`）。
  void _exitEditMode() {
    _stopAutoScroll();
    setState(() => _isEditMode = false);
    unawaited(_saveOrder());
  }

  /// 编辑态当前展示的平台（用户排序优先，远端默认兜底）。
  List<WelfarePlatform> _currentOrderedPlatforms(
    WelfarePlatformCategory category,
    List<WelfarePlatform> fallback,
  ) =>
      _ordered[category] ?? fallback;

  /// 拖拽换位（对齐 iOS `movePlatform`：remove + insert；首次拖拽时以
  /// 当前展示列表初始化该分类缓存）。
  void _movePlatform(
    WelfarePlatformCategory category,
    int from,
    int to,
    List<WelfarePlatform> fallback,
  ) {
    final List<WelfarePlatform> list =
        List<WelfarePlatform>.of(_ordered[category] ?? fallback);
    if (from < 0 || to < 0 || from >= list.length || to >= list.length) return;
    final WelfarePlatform item = list.removeAt(from);
    list.insert(to, item);
    setState(() => _ordered[category] = list);
  }

  // ─────────────── 边缘自动滚动（对齐 iOS `handleEdgeProximity`） ───────────────

  /// direction：-1 上 / 0 停 / 1 下；绝对值 = 速度因子（0.3 ~ 1.0）。
  void _handleEdgeProximity(double direction) {
    if (direction == 0) {
      _stopAutoScroll();
      return;
    }
    final double speed = 3.0 * (direction.abs() < 0.3 ? 0.3 : direction.abs());
    if (_autoScrollTimer != null && _autoScrollSpeed.sign == direction.sign) {
      _autoScrollSpeed = direction;
      return;
    }
    _stopAutoScroll();
    _autoScrollSpeed = direction;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_gridScroll.hasClients) return;
      final double target = _gridScroll.offset + speed * _autoScrollSpeed.sign;
      _gridScroll.jumpTo(
        target.clamp(0.0, _gridScroll.position.maxScrollExtent),
      );
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollSpeed = 0;
  }

  Widget _content(
    WelfarePlatformController controller,
    List<WelfarePlatform> platforms,
  ) {
    if (platforms.isNotEmpty) {
      if (_isEditMode) {
        // 编辑排序态（对齐 iOS `RemotePlatformSortableCard` 网格）。
        return _SortablePlatformGrid(
          controller: _gridScroll,
          platforms: platforms,
          onMove: (int from, int to) =>
              _movePlatform(_category, from, to, platforms),
          onEdgeProximity: _handleEdgeProximity,
        );
      }
      final Map<String, WelfarePlatform> byKey = <String, WelfarePlatform>{
        for (final WelfarePlatform p in platforms) p.platformKey: p,
      };
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          VboxSpacing.lg,
          VboxSpacing.sm,
          VboxSpacing.lg,
          100,
        ),
        child: VboxWelfarePlatformGrid(
          platforms: platforms
              .map((WelfarePlatform p) => VboxWelfarePlatform(
                    name: p.name,
                    icon: welfarePlatformIcon(p.icon),
                    platformKey: p.platformKey,
                  ))
              .toList(growable: false),
          onTap: (VboxWelfarePlatform p) {
            final WelfarePlatform? target = byKey[p.platformKey];
            if (target != null) _onPlatformTap(target);
          },
          // 长按进入编辑排序（对齐 iOS `onLongPressGesture` 0.5s）。
          onLongPress: _enterEditMode,
        ),
      );
    }

    if (controller.loadState == WelfarePlatformLoadState.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final bool failed = controller.loadState == WelfarePlatformLoadState.failed;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VboxSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              failed ? Icons.cloud_off_rounded : Icons.grid_view_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: VboxSpacing.md),
            Text(
              failed ? (controller.errorMessage ?? '福利内容加载失败') : '此分类下暂无平台',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: VboxTypography.s15,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            if (failed) ...<Widget>[
              const SizedBox(height: VboxSpacing.md),
              VboxButton(
                label: '重试',
                onPressed: () =>
                    context.read<WelfarePlatformController>().refresh(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 按 [WelfarePlatformRouter] 解析并跳转（H-02）。
  ///
  /// 未支持（`unknown` / `fuli_base` 未注册 / 隔离违规）→ [UnsupportedPlatformPage]；
  /// 福利 JS Spider（H-03 续段）→ [WelfareSpiderMainPage]（JS 引擎执行页，
  /// 对齐 iOS `FuliPlatformMainView + WelfareJSSpiderService`）；
  /// 福利 Python Spider → [WelfareSpiderMainPage]（Python 桥执行页，
  /// 对齐 iOS `WelfarePythonSpiderService`）；
  /// 其余福利 Spider 脚本 → [WelfareSpiderHomePage]（脚本状态页）。
  void _onPlatformTap(WelfarePlatform platform) {
    final WelfareRoute route = _router.resolve(platform);
    if (route is WelfareUnsupportedRoute) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => UnsupportedPlatformPage(
            platform: platform,
            reason: route.reason,
          ),
        ),
      );
      return;
    }
    if (route is WelfareWelfareSpiderRoute) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => WelfareSpiderMainPage(
            platform: platform,
            service: WelfareJSSpiderService.serviceFor(platform),
          ),
        ),
      );
      return;
    }
    if (route is WelfarePythonSpiderRoute) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => WelfareSpiderMainPage(
            platform: platform,
            service: WelfarePythonSpiderService.serviceFor(platform),
          ),
        ),
      );
      return;
    }
    if (route is WelfareSpiderHomeRoute) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              WelfareSpiderHomePage(platform: platform),
        ),
      );
      return;
    }
    // Fuli-S1 / W-福1：fuli_base（服务已注册）→ 通用福利平台页。
    if (route is WelfareFuliBaseRoute) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => WelfareSpiderMainPage(
            platform: platform,
            service: route.service,
          ),
        ),
      );
      return;
    }
    // 艾旦（aidan_video）：取「aidan_video」原生服务；未注册则明确未支持。
    if (route is WelfareAidanVideoRoute) {
      final FuliBaseService? service =
          FuliBaseServiceRegistry.shared.serviceFor('aidan_video');
      if (service != null) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => WelfareSpiderMainPage(
              platform: platform,
              service: service,
            ),
          ),
        );
        return;
      }
      _pushUnsupported(platform, 'aidan_video 服务未注册');
      return;
    }
    // UI-C1c：远程 CMS V10（服务已就绪）→ 通用福利平台页（与 fuli_base 同页族）。
    if (route is WelfareRemoteCmsV10Route) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => WelfareSpiderMainPage(
            platform: platform,
            service: route.service,
          ),
        ),
      );
      return;
    }
    // 原生专用页：UI-C1a 香蕉秀 XJSP + UI-C1b 每日大乱斗 / 每日大赛 +
    // UI-C1e 今日看料均已落地 → 各进专页。
    if (route is WelfareNativeRoute) {
      if (route.kind == WelfareNativeKind.bananaXjsp) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                BananaXjspHomePage(service: BananaXjspFuliService.serviceFor()),
          ),
        );
        return;
      }
      if (route.kind == WelfareNativeKind.kanliao) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                KanliaoHomePage(service: KanliaoFuliService.serviceFor()),
          ),
        );
        return;
      }
      if (route.kind == WelfareNativeKind.dailyBattle) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => DailyBattleHomePage(
              service: DailyBattleFuliService.serviceFor(
                platformKey: platform.platformKey,
                platformName: platform.name,
              ),
            ),
          ),
        );
        return;
      }
      _pushUnsupported(platform, '${route.kind.label}尚未接入（UI-C1）');
      return;
    }
    VboxToast.show(context, '「${platform.name}」路由至 ${route.destinationLabel}');
  }

  /// 进入未支持页（明确原因，替代静默 Toast）。
  void _pushUnsupported(WelfarePlatform platform, String reason) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => UnsupportedPlatformPage(
          platform: platform,
          reason: reason,
        ),
      ),
    );
  }
}

/// SF Symbol 名 → Material 近似图标（未知符号回退 `apps`）。
///
/// iOS 平台图标为远程配置的 SF Symbol 字符串，Flutter 侧无法解析；
/// 仅覆盖远程配置中的常见符号，其余统一兜底，避免整格空白。
IconData welfarePlatformIcon(String? symbol) {
  switch (symbol) {
    case 'play.rectangle.fill':
      return Icons.smart_display_rounded;
    case 'antenna.radiowaves.left.and.right':
      return Icons.podcasts;
    case 'books.vertical.fill':
      return Icons.menu_book_rounded;
    case 'leaf.fill':
      return Icons.eco_rounded;
    case 'film.fill':
      return Icons.movie_rounded;
    case 'tv.fill':
      return Icons.tv_rounded;
    case 'music.note':
      return Icons.music_note_rounded;
    case 'video.fill':
      return Icons.videocam_rounded;
    case 'photo.fill':
      return Icons.photo_rounded;
    case 'flame.fill':
      return Icons.local_fire_department_rounded;
    case 'star.fill':
      return Icons.star_rounded;
    default:
      return Icons.apps_rounded;
  }
}

// ─────────────────────── 编辑排序网格（对齐 iOS `RemotePlatformSortableCard`） ───────────────────────

/// 编辑态可排序网格：4 列 + 间距 16（对齐 iOS `LazyVGrid`）。
///
/// 交互对齐 iOS：
///   · 长按 0.4s 拾取（light 震动）→ 拖拽跟手（浮卡 + scale 1.15 + 阴影）；
///   · 手指移入新格即换位（selection 震动 + 数据 remove/insert 重排）；
///   · 松手落位（medium 震动）；
///   · 手指进入视口上下 100pt 边缘 → 触发自动滚动（速度因子 0.3~1.0），
///     自动滚动中持续重算换位（对齐 iOS 拖拽中滚动仍可排序）。
class _SortablePlatformGrid extends StatefulWidget {
  const _SortablePlatformGrid({
    required this.controller,
    required this.platforms,
    required this.onMove,
    required this.onEdgeProximity,
  });

  final ScrollController controller;
  final List<WelfarePlatform> platforms;
  final void Function(int from, int to) onMove;
  final ValueChanged<double> onEdgeProximity;

  @override
  State<_SortablePlatformGrid> createState() => _SortablePlatformGridState();
}

class _SortablePlatformGridState extends State<_SortablePlatformGrid> {
  static const int _columns = 4;
  static const double _hPadding = 16;
  static const double _crossSpacing = 16;
  static const double _mainSpacing = 16;
  static const double _topPadding = 8;
  static const double _edgeThreshold = 100;

  final GlobalKey _boxKey = GlobalKey();

  /// 正在拖拽的卡（当前数据 index）；null = 未拖拽。
  int? _dragIndex;

  /// 手指最近一次全局坐标（自动滚动重算换位用）。
  Offset? _lastFinger;

  @override
  void initState() {
    super.initState();
    // 边缘自动滚动改变 offset 时持续重算换位与浮卡位置（对齐 iOS
    // 「拖动到边缘自动滚动 + 滚动中仍可排序」）。
    widget.controller.addListener(_onScrollChanged);
  }

  @override
  void didUpdateWidget(_SortablePlatformGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScrollChanged);
      widget.controller.addListener(_onScrollChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScrollChanged);
    super.dispose();
  }

  void _onScrollChanged() {
    if (_dragIndex != null && _lastFinger != null) {
      _reconcileDrag(_lastFinger!);
    }
  }

  // 网格几何（对齐 iOS cardWidth 88 / cardHeight 102 步长）。
  double _cellW = 72;
  double _cellH = 86;

  double get _stepW => _cellW + _crossSpacing;
  double get _stepH => _cellH + _mainSpacing;

  void _updateMetrics(double viewportWidth) {
    final double inner = viewportWidth - _hPadding * 2;
    _cellW = (inner - (_columns - 1) * _crossSpacing) / _columns;
    _cellH = _cellW * 86 / 72;
  }

  /// 手指全局坐标 → 最近格 index（列不随滚动，行含滚动偏移）。
  int? _slotFor(Offset global) {
    final RenderBox? box =
        _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final Offset vp = box.localToGlobal(Offset.zero);
    final double scroll =
        widget.controller.hasClients ? widget.controller.offset : 0;
    final double contentX = global.dx - vp.dx;
    final double contentY = global.dy - vp.dy + scroll;
    if (contentX < 0 || contentY < 0) return null;
    final int col = ((contentX - _hPadding - _cellW / 2) / _stepW)
        .round()
        .clamp(0, _columns - 1);
    final int totalRows = (widget.platforms.length + _columns - 1) ~/ _columns;
    final int row = ((contentY - _topPadding - _cellH / 2) / _stepH)
        .round()
        .clamp(0, totalRows - 1);
    return (row * _columns + col).clamp(0, widget.platforms.length - 1);
  }

  void _onDragStart(int index, Offset global) {
    VboxHaptics.light();
    _lastFinger = global;
    setState(() => _dragIndex = index);
    _reconcileDrag(global);
  }

  void _onDragMove(Offset global) {
    _lastFinger = global;
    _reconcileDrag(global);
  }

  void _onDragEnd() {
    VboxHaptics.medium();
    widget.onEdgeProximity(0);
    _lastFinger = null;
    setState(() => _dragIndex = null);
  }

  /// 统一处理：换位判定 + 边缘自动滚动检测。
  void _reconcileDrag(Offset global) {
    if (_dragIndex == null) return;
    final int? target = _slotFor(global);
    if (target != null && target != _dragIndex) {
      VboxHaptics.selection();
      final int from = _dragIndex!;
      // 先更新本地 index（父级 setState 重建后本 State 保留）。
      _dragIndex = target;
      widget.onMove(from, target);
    }
    // 边缘检测（对齐 iOS：距上下边缘 100pt 内，越近越快）。
    final RenderBox? box =
        _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) {
      final Offset vp = box.localToGlobal(Offset.zero);
      final double distanceFromTop = global.dy - vp.dy;
      final double distanceFromBottom = vp.dy + box.size.height - global.dy;
      if (distanceFromTop < _edgeThreshold) {
        widget.onEdgeProximity(
          -(1 - distanceFromTop / _edgeThreshold).clamp(0.3, 1.0),
        );
      } else if (distanceFromBottom < _edgeThreshold) {
        widget.onEdgeProximity(
          (1 - distanceFromBottom / _edgeThreshold).clamp(0.3, 1.0),
        );
      } else {
        widget.onEdgeProximity(0);
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _updateMetrics(constraints.maxWidth);
        return Stack(
          key: _boxKey,
          clipBehavior: Clip.none,
          children: <Widget>[
            GridView.builder(
              controller: widget.controller,
              padding: const EdgeInsets.fromLTRB(
                _hPadding,
                _topPadding,
                _hPadding,
                100,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                crossAxisSpacing: _crossSpacing,
                mainAxisSpacing: _mainSpacing,
                childAspectRatio: 72 / 86,
              ),
              itemCount: widget.platforms.length,
              itemBuilder: (BuildContext context, int index) {
                // 被拖卡在格内隐藏，浮卡由顶层渲染跟手。
                if (_dragIndex == index) return const SizedBox.shrink();
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (LongPressStartDetails d) =>
                      _onDragStart(index, d.globalPosition),
                  onLongPressMoveUpdate: (LongPressMoveUpdateDetails d) =>
                      _onDragMove(d.globalPosition),
                  onLongPressEnd: (LongPressEndDetails _) => _onDragEnd(),
                  onLongPressCancel: _onDragEnd,
                  child: _SortableCard(
                    platform: widget.platforms[index],
                    dragging: false,
                  ),
                );
              },
            ),
            // 浮卡（跟手渲染，浮在所有格之上；对齐 iOS zIndex 999）。
            if (_dragIndex != null) _buildFloatingCard(),
          ],
        );
      },
    );
  }

  /// 顶层浮卡：渲染在手指位置（对齐 iOS「卡随手指」视觉）。
  Widget _buildFloatingCard() {
    final RenderBox? box =
        _boxKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset? finger = _lastFinger;
    if (box == null || finger == null) return const SizedBox.shrink();
    final Offset vp = box.localToGlobal(Offset.zero);
    // 视口坐标（Stack 坐标系，不含滚动）。
    final double localX = finger.dx - vp.dx;
    final double localY = finger.dy - vp.dy;
    final int index = _dragIndex!;
    return Positioned(
      left: localX - _cellW / 2,
      top: localY - _cellH / 2,
      width: _cellW,
      height: _cellH,
      child: _SortableCard(
        platform: widget.platforms[index],
        dragging: true,
      ),
    );
  }
}

/// 编辑态平台卡片（渐变图标 + 右上拖拽提示角标 + 名称；对齐 iOS
/// `RemotePlatformSortableCard.cardContent`）。
class _SortableCard extends StatelessWidget {
  const _SortableCard({required this.platform, required this.dragging});

  final WelfarePlatform platform;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final List<Color> gradient =
        VboxColors.welfarePlatformGradient(platform.name);
    return AnimatedScale(
      scale: dragging ? 1.15 : 1.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(VboxRadii.r16),
          boxShadow: <BoxShadow>[
            if (dragging)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Stack(
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: gradient,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(VboxRadii.r16),
                  ),
                  child: Icon(
                    welfarePlatformIcon(platform.icon),
                    size: 24,
                    color: Colors.white,
                  ),
                ),
                // 右上角可拖拽提示（对齐 iOS `arrow.up.and.down` 小角标）。
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.black26,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.swap_vert,
                      size: 9,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              platform.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
