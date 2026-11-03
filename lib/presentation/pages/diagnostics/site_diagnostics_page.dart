/// 表现层：站点诊断页面（批次 G · G-08）。
///
/// 唯一真相源：iOS `vbox/Views/SiteDiagnosticsView.swift`（326 行）
///   · 标题「接口状态诊断」· 关闭 + 刷新
///   · 顶部摘要卡（gray.opacity(0.06) 底 · 圆角12 · 内边距16 · h16 v10）
///   · 9 项筛选器横滚（字号13 · 选中 white+#E11D48 圆角16 · 未选中 primary+gray.opacity(0.12)）
///   · 空态 / 诊断中 / 列表（plain）+ 行可展开详情
///
/// 差异登记（对齐 iOS 语义，非偏离）：
/// - 额外显示「远程源状态 + configVersion」（用户明确要求，iOS 该页无此展示），
///   以信息行形式置于摘要卡上方，不改变原有 UI 结构。
/// - 图标逐字保留 emoji（✅/📡/❌/🌐/📄/🔧/❓/⏭️/🍎/⚡）。
/// - 全部 UI 值走令牌（VboxColors / VboxTypography / VboxRadii / VboxSpacing）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/entities/spider/site_config.dart';
import '../../../domain/entities/spider/engine_type.dart';
import '../../../domain/entities/remote_source/remote_strategy.dart';
import '../../../domain/usecases/remote_source_usecases.dart';
import '../../../domain/usecases/content_browse_usecases.dart';
import '../../../core/utils/result.dart';
import 'site_diagnostics_manager.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/typography.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';

// ── 筛选器类型（对齐 iOS SiteStatusFilter 9 项）───────────────────

enum SiteStatusFilter {
  all,
  searchable,
  failed,
  jscOnly,
  qjsOnly,
  type0,
  type1,
  type2,
  type3,
}

extension on SiteStatusFilter {
  String get label {
    switch (this) {
      case SiteStatusFilter.all:
        return '全部';
      case SiteStatusFilter.searchable:
        return '可搜索';
      case SiteStatusFilter.failed:
        return '有异常';
      case SiteStatusFilter.jscOnly:
        return '仅JSC';
      case SiteStatusFilter.qjsOnly:
        return '仅QJS';
      case SiteStatusFilter.type0:
        return 'API(type0)';
      case SiteStatusFilter.type1:
        return 'API(type1)';
      case SiteStatusFilter.type2:
        return '站源';
      case SiteStatusFilter.type3:
        return 'JS蜘蛛';
    }
  }

  bool applies(SiteDiagnosticResult r) {
    switch (this) {
      case SiteStatusFilter.all:
        return true;
      case SiteStatusFilter.searchable:
        return r.canSearch;
      case SiteStatusFilter.failed:
        return const <SiteDiagnosticStatus>[
          SiteDiagnosticStatus.downloadFailed,
          SiteDiagnosticStatus.invalidContent,
          SiteDiagnosticStatus.registerFailed,
          SiteDiagnosticStatus.noApi,
        ].contains(r.status);
      case SiteStatusFilter.jscOnly:
        return r.status == SiteDiagnosticStatus.jscOnly;
      case SiteStatusFilter.qjsOnly:
        return r.status == SiteDiagnosticStatus.qjsOnly;
      case SiteStatusFilter.type0:
        return r.type == 0;
      case SiteStatusFilter.type1:
        return r.type == 1;
      case SiteStatusFilter.type2:
        return r.type == 2;
      case SiteStatusFilter.type3:
        return r.type == 3;
    }
  }
}

// ── 类型徽标颜色（对齐 iOS typeColor）───────────────────────────

Color _typeColor(int type) {
  switch (type) {
    case 0:
    case 1:
      return VboxColors.selected;
    case 2:
      return VboxColors.skinPrimaryPurple;
    case 3:
      return VboxColors.success;
    default:
      return VboxColors.systemGray2Light;
  }
}

String _typeLabel(int type) {
  switch (type) {
    case 0:
    case 1:
      return 'API';
    case 2:
      return '站源';
    case 3:
      return 'JS蜘蛛';
    default:
      return '未知';
  }
}

// ── 状态颜色（对齐 iOS statusColor）─────────────────────────────

Color _statusColor(SiteDiagnosticStatus status) {
  switch (status) {
    case SiteDiagnosticStatus.loaded:
    case SiteDiagnosticStatus.engineReady:
      return VboxColors.success;
    case SiteDiagnosticStatus.apiOnly:
      return VboxColors.selected;
    case SiteDiagnosticStatus.noApi:
    case SiteDiagnosticStatus.downloadFailed:
    case SiteDiagnosticStatus.invalidContent:
    case SiteDiagnosticStatus.registerFailed:
      return VboxColors.warning;
    case SiteDiagnosticStatus.unknown:
    case SiteDiagnosticStatus.skipped:
      return VboxColors.systemGray2Light;
    case SiteDiagnosticStatus.jscOnly:
      return VboxColors.warning;
    case SiteDiagnosticStatus.qjsOnly:
      return VboxColors.skinPrimaryPurple;
  }
}

// ── 次级文字（按亮度取 Light / Dark）────────────────────────────

Color _secondaryLabel(BuildContext context) {
  final bool isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark
      ? VboxColors.secondaryLabelDark
      : VboxColors.secondaryLabelLight;
}

// ── 页面────────────────────────────────────────────────────────────

/// 站点诊断页面。
class SiteDiagnosticsPage extends StatefulWidget {
  /// 构造（[manager] 可注入便于测试）。
  const SiteDiagnosticsPage({super.key, SiteDiagnosticsManager? manager})
      : _manager = manager;

  final SiteDiagnosticsManager? _manager;

  @override
  State<SiteDiagnosticsPage> createState() => _SiteDiagnosticsPageState();
}

class _SiteDiagnosticsPageState extends State<SiteDiagnosticsPage> {
  late SiteDiagnosticsManager _manager;
  SiteStatusFilter _filter = SiteStatusFilter.all;
  String _configVersion = '';
  String _remoteStatus = '';

  @override
  void initState() {
    super.initState();
    _manager = widget._manager ?? SiteDiagnosticsManager();
    _loadInfo();
    if (_manager.results.isEmpty && !_manager.isDiagnosing) {
      _runDiagnostics();
    }
  }

  @override
  void dispose() {
    // 仅释放本页自建的管理器；注入实例的生命周期归调用方。
    if (widget._manager == null) _manager.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    final RemoteSourceUseCases useCases =
        Provider.of<RemoteSourceUseCases>(context, listen: false);
    final RemoteLoadStatus status = await useCases.status();
    if (mounted) {
      setState(() {
        _remoteStatus = status.displayText;
        _configVersion = status.version ?? '';
      });
    }
  }

  Future<void> _runDiagnostics() async {
    final ContentBrowseUseCases browse =
        Provider.of<ContentBrowseUseCases>(context, listen: false);
    final Result<List<SiteConfig>> result = await browse.listSites();
    final List<SiteConfig> sites = result.valueOrNull ?? const <SiteConfig>[];
    await _manager.diagnoseAll(sites);
  }

  List<SiteDiagnosticResult> get _filtered {
    if (_filter == SiteStatusFilter.all) return _manager.results;
    return _manager.results
        .where((SiteDiagnosticResult r) => _filter.applies(r))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color cardBg = isDark
        ? VboxColors.secondarySystemGroupedBackgroundDark
            .withValues(alpha: 0.06)
        : VboxColors.secondarySystemGroupedBackgroundLight
            .withValues(alpha: 0.06);

    return Scaffold(
      appBar: AppBar(
        title: const Text('接口状态诊断'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: <Widget>[
          ListenableBuilder(
            listenable: _manager,
            builder: (BuildContext context, Widget? _) => IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _manager.isDiagnosing ? null : _runDiagnostics,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _manager,
        builder: (BuildContext context, Widget? _) => ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: VboxSpacing.lg,
            vertical: VboxSpacing.lg,
          ),
          children: <Widget>[
            // 信息行：远程源状态 + configVersion（用户要求）
            _InfoRow(status: _remoteStatus, version: _configVersion),
            const SizedBox(height: VboxSpacing.md),

            // 摘要卡
            _SummaryCard(summary: _manager.summary, cardBg: cardBg),
            const SizedBox(height: VboxSpacing.md),

            // 筛选器
            _FilterChips(
              selected: _filter,
              onSelected: (SiteStatusFilter f) => setState(() => _filter = f),
            ),
            const SizedBox(height: VboxSpacing.md),

            // 列表区
            if (_manager.isDiagnosing)
              const _LoadingState()
            else if (_filtered.isEmpty && _manager.results.isEmpty)
              const _EmptyState()
            else
              _ResultList(results: _filtered),
          ],
        ),
      ),
    );
  }
}

// ── 信息行──────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.status, required this.version});

  final String status;
  final String version;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md,
        vertical: VboxSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: (isDark
                ? VboxColors.secondarySystemGroupedBackgroundDark
                : VboxColors.secondarySystemGroupedBackgroundLight)
            .withValues(alpha: 0.5),
        borderRadius: VboxRadii.chip,
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.signal_cellular_alt_rounded,
              size: VboxTypography.s16),
          const SizedBox(width: VboxSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  status.isEmpty ? '远程源待同步' : status,
                  style: const TextStyle(
                    fontSize: VboxTypography.s13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (version.isNotEmpty)
                  Text(
                    'v$version',
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: _secondaryLabel(context),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 摘要卡──────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.cardBg});

  final DiagnosticSummary summary;
  final Color cardBg;

  @override
  Widget build(BuildContext context) {
    final bool hasFailed = summary.failed > 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.segmentVertical,
      ),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: VboxRadii.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 第一行：总计 / 引擎就绪 / 仅API / 可搜索
          Row(
            spacing: VboxSpacing.xs,
            children: <Widget>[
              _SummaryItem(
                value: summary.total.toString(),
                title: '总计',
                valueColor: Theme.of(context).colorScheme.primary,
              ),
              _SummaryItem(
                value: summary.engineReady.toString(),
                title: '引擎就绪',
                valueColor: VboxColors.success,
              ),
              _SummaryItem(
                value: summary.apiOnly.toString(),
                title: '仅API',
                valueColor: VboxColors.selected,
              ),
              _SummaryItem(
                value: summary.searchableCount.toString(),
                title: '可搜索',
                valueColor: VboxColors.skinPrimaryRose,
              ),
            ],
          ),
          const SizedBox(height: VboxSpacing.sm),
          // 第二行：JSC引擎 / QJS引擎
          Row(
            spacing: VboxSpacing.xs,
            children: <Widget>[
              _SummaryItem(
                value: summary.jscCount.toString(),
                title: 'JSC引擎',
                valueColor: VboxColors.warning,
              ),
              _SummaryItem(
                value: summary.qjsCount.toString(),
                title: 'QJS引擎',
                valueColor: VboxColors.skinPrimaryPurple,
              ),
            ],
          ),
          // 失败警告
          if (hasFailed) ...<Widget>[
            const SizedBox(height: VboxSpacing.sm),
            Divider(
              height: 1,
              color: VboxColors.warning.withValues(alpha: 0.3),
            ),
            const SizedBox(height: VboxSpacing.sm),
            Row(
              children: <Widget>[
                const Icon(
                  Icons.warning_amber_rounded,
                  size: VboxTypography.s16,
                  color: VboxColors.warning,
                ),
                const SizedBox(width: VboxSpacing.xs),
                Expanded(
                  child: Text(
                    '${summary.failed} 个接口加载失败，请查看详情',
                    style: const TextStyle(
                      fontSize: VboxTypography.s13,
                      color: VboxColors.warning,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.value,
    required this.title,
    required this.valueColor,
  });

  final String value;
  final String title;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: VboxTypography.s18,
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
          Text(
            title,
            style: TextStyle(
              fontSize: VboxTypography.s11,
              color: _secondaryLabel(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 筛选器──────────────────────────────────────────────────────────

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.selected,
    required this.onSelected,
  });

  final SiteStatusFilter selected;
  final ValueChanged<SiteStatusFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final SiteStatusFilter f in SiteStatusFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: VboxSpacing.sm),
              child: FilterChip(
                selected: f == selected,
                label: Text(f.label),
                labelStyle: TextStyle(
                  fontSize: VboxTypography.s13,
                  color: f == selected
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface,
                ),
                selectedColor: VboxColors.skinPrimaryRose,
                checkmarkColor: Colors.white,
                showCheckmark: false,
                shape:
                    const RoundedRectangleBorder(borderRadius: VboxRadii.chip),
                side: f == selected
                    ? null
                    : BorderSide(
                        color: (isDark
                                ? VboxColors.secondaryLabelDark
                                : VboxColors.secondaryLabelLight)
                            .withValues(alpha: 0.12),
                      ),
                padding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.md,
                  vertical: VboxSpacing.sm,
                ),
                onSelected: (_) => onSelected(f),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 空态 / 加载中───────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.search,
              size: 40,
              color: _secondaryLabel(context),
            ),
            const SizedBox(height: VboxSpacing.md),
            Text(
              '点击开始检测接口状态',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                color: _secondaryLabel(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: VboxSpacing.md),
            Text(
              '正在检测接口状态...',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                color: _secondaryLabel(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 结果列表────────────────────────────────────────────────────────

class _ResultList extends StatefulWidget {
  const _ResultList({required this.results});

  final List<SiteDiagnosticResult> results;

  @override
  State<_ResultList> createState() => _ResultListState();
}

class _ResultListState extends State<_ResultList> {
  final Set<int> _expanded = <int>{};

  void _toggleExpand(int index) {
    setState(() {
      if (_expanded.contains(index)) {
        _expanded.remove(index);
      } else {
        _expanded.add(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: VboxSpacing.sm),
          child: Text(
            '共 ${widget.results.length} 个接口',
            style: TextStyle(
              fontSize: VboxTypography.s14,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        for (int i = 0; i < widget.results.length; i++)
          _ResultTile(
            result: widget.results[i],
            expanded: _expanded.contains(i),
            onTap: () => _toggleExpand(i),
          ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.expanded,
    required this.onTap,
  });

  final SiteDiagnosticResult result;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final bool hasError =
        result.errorMessage != null && result.errorMessage!.isNotEmpty;
    final Color statusColor = _statusColor(result.status);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
      child: Material(
        color: (isDark
                ? VboxColors.secondarySystemGroupedBackgroundDark
                : VboxColors.secondarySystemGroupedBackgroundLight)
            .withValues(alpha: 0.5),
        borderRadius: VboxRadii.card,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ListTile(
              leading: Text(
                result.status.icon,
                style: const TextStyle(fontSize: 18),
              ),
              title: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      result.siteName,
                      style: const TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: VboxSpacing.sm),
                  // 类型徽标
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VboxSpacing.sm,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _typeColor(result.type),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _typeLabel(result.type),
                      style: const TextStyle(
                        fontSize: VboxTypography.s10,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: VboxSpacing.xs),
                  Text(
                    result.status.title,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: statusColor,
                    ),
                  ),
                  // 引擎徽标
                  if (result.engineType != null) ...<Widget>[
                    const SizedBox(height: 2),
                    _EngineBadge(type: result.engineType!),
                  ],
                  // type 3 双引擎标签
                  if (result.type == 3) ...<Widget>[
                    const SizedBox(height: 2),
                    _DualEngineLabel(
                      jscCompatible: result.jscCompatible,
                      qjsCompatible: result.qjsCompatible,
                    ),
                  ],
                  // 可搜索徽标
                  if (result.canSearch) ...<Widget>[
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color:
                            VboxColors.skinPrimaryRose.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '可搜索',
                        style: TextStyle(
                          fontSize: VboxTypography.s10,
                          color: VboxColors.skinPrimaryRose,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              trailing: hasError
                  ? const Icon(Icons.chevron_right_rounded, size: 18)
                  : null,
              onTap: onTap,
            ),
            // 展开详情
            if (expanded && hasError)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: VboxSpacing.md,
                ).add(const EdgeInsets.only(bottom: VboxSpacing.sm)),
                child: _ErrorDetail(result: result),
              ),
          ],
        ),
      ),
    );
  }
}

class _EngineBadge extends StatelessWidget {
  const _EngineBadge({required this.type});

  final SpiderEngineType type;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (type) {
      SpiderEngineType.javaScriptCore => ('JSC', VboxColors.warning),
      SpiderEngineType.quickJS => ('QJS', VboxColors.skinPrimaryPurple),
      SpiderEngineType.node => ('Node', VboxColors.selected),
      SpiderEngineType.nodeLX => ('NodeLX', VboxColors.selected),
      SpiderEngineType.python => ('Python', VboxColors.success),
    };
    return Text(
      label,
      style: TextStyle(
        fontSize: VboxTypography.s11,
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _DualEngineLabel extends StatelessWidget {
  const _DualEngineLabel({
    required this.jscCompatible,
    required this.qjsCompatible,
  });

  final bool jscCompatible;
  final bool qjsCompatible;

  @override
  Widget build(BuildContext context) {
    if (jscCompatible && qjsCompatible) {
      return const Text(
        '🍎JSC  ⚡QJS',
        style: TextStyle(
          fontSize: VboxTypography.s11,
          color: VboxColors.success,
        ),
      );
    }
    if (jscCompatible) {
      return const Text(
        '🍎JSC',
        style: TextStyle(
          fontSize: VboxTypography.s11,
          color: VboxColors.warning,
        ),
      );
    }
    if (qjsCompatible) {
      return const Text(
        '⚡QJS',
        style: TextStyle(
          fontSize: VboxTypography.s11,
          color: VboxColors.skinPrimaryPurple,
        ),
      );
    }
    return const Text(
      '❌ 双引擎均不兼容',
      style: TextStyle(
        fontSize: VboxTypography.s11,
        color: VboxColors.danger,
      ),
    );
  }
}

class _ErrorDetail extends StatelessWidget {
  const _ErrorDetail({required this.result});

  final SiteDiagnosticResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(VboxSpacing.md),
      decoration: BoxDecoration(
        color: VboxColors.warning.withValues(alpha: 0.06),
        borderRadius: VboxRadii.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '问题详情:',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              fontWeight: FontWeight.w600,
              color: VboxColors.warning,
            ),
          ),
          const SizedBox(height: VboxSpacing.xs),
          Text(
            result.errorMessage ?? '',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: _secondaryLabel(context),
            ),
          ),
          if (result.api.isNotEmpty) ...<Widget>[
            const SizedBox(height: VboxSpacing.xs),
            Text(
              'API: ${result.api}',
              style: TextStyle(
                fontSize: VboxTypography.s11,
                color: _secondaryLabel(context).withValues(alpha: 0.7),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // type 3 双引擎勾选图标
          if (result.type == 3) ...<Widget>[
            const SizedBox(height: VboxSpacing.sm),
            Row(
              children: <Widget>[
                Icon(
                  result.jscCompatible
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: VboxTypography.s16,
                  color: result.jscCompatible
                      ? VboxColors.success
                      : VboxColors.danger,
                ),
                const SizedBox(width: VboxSpacing.xs),
                Text(
                  'JSC兼容',
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: result.jscCompatible
                        ? VboxColors.success
                        : VboxColors.danger,
                  ),
                ),
                const SizedBox(width: VboxSpacing.md),
                Icon(
                  result.qjsCompatible
                      ? Icons.check_circle_rounded
                      : Icons.cancel_rounded,
                  size: VboxTypography.s16,
                  color: result.qjsCompatible
                      ? VboxColors.success
                      : VboxColors.danger,
                ),
                const SizedBox(width: VboxSpacing.xs),
                Text(
                  'QJS兼容',
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: result.qjsCompatible
                        ? VboxColors.success
                        : VboxColors.danger,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
