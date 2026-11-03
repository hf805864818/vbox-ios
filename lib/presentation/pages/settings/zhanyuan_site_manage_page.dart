/// 站源管理页（Wave D · O-源3）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift` `ZhanyuanSiteManageView`
/// （L3052-L3125）：
///   · 顶部搜索框（L3065-L3069）—— 占位「搜索站点」（14），按名称不区分大小写过滤；
///   · 站点分组（L3071-L3093）—— 分组头「启用 X/Y 个站点」；行 = 站点名
///     （15 medium）+ 搜索地址（11 gray · 单行）+ 右侧开关；
///   · 导航栏右上「全选」（L3098-L3107，14）—— 把未启用站点全部置为启用。
///
/// 落地口径：
/// - 状态权威 = SQLite `zhanyuan.isActive`（对齐 iOS
///   `DatabaseManager.queryAllZhanyuanSites` / `updateZhanyuanActive`）；
/// - 订阅配置站点作内存补齐（对齐 iOS「DB 优先 → 内存回退」语义）。
///
/// 差异登记：iOS 以 sheet 呈现（含嵌套 NavigationView）；Flutter 用标准
/// `AppBar`（保留返回键），与订阅配置页口径一致。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/datasources/local/source_governance_store.dart';
import '../../../data/models/zhanyuan.dart';
import '../../../domain/usecases/source_governance_usecases.dart';
import '../../theme/theme.dart';

/// 站源管理页。
class ZhanyuanSiteManagePage extends StatefulWidget {
  /// 构造（[governance] / [store] 可注入；为 null 时消费全局单例，便于单测）。
  const ZhanyuanSiteManagePage({super.key, this.governance, this.store});

  /// 源治理用例（可注入；为 null 时列表降级为空）。
  final SourceGovernanceUseCases? governance;

  /// 源治理存储（可注入）。
  final SourceGovernanceStore? store;

  @override
  State<ZhanyuanSiteManagePage> createState() => _ZhanyuanSiteManagePageState();
}

class _ZhanyuanSiteManagePageState extends State<ZhanyuanSiteManagePage> {
  final TextEditingController _search = TextEditingController();

  List<Zhanyuan> _sites = const <Zhanyuan>[];
  String _keyword = '';

  /// 源治理用例：优先取注入项，缺省从 Provider 读取（设置页以路由跳转时不带参）。
  SourceGovernanceUseCases? _governance;

  SourceGovernanceStore get _store =>
      widget.store ?? SourceGovernanceStore.instance;

  /// 过滤后的站点（对齐 iOS `filteredSites`：按名称不区分大小写包含）。
  List<Zhanyuan> get _filtered {
    if (_keyword.isEmpty) return _sites;
    final String k = _keyword.toLowerCase();
    return _sites
        .where((Zhanyuan z) => z.name.toLowerCase().contains(k))
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _governance = widget.governance ?? _readGovernance();
    unawaited(_load());
  }

  /// 读取可选源治理用例（未注入 Provider 时返回 null，便于 widget 测试）。
  SourceGovernanceUseCases? _readGovernance() {
    try {
      return context.read<SourceGovernanceUseCases>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final SourceGovernanceUseCases? uc = _governance;
    final List<Zhanyuan> sites = uc == null
        ? await _store.allZhanyuanSites()
        : await uc.listZhanyuanSites();
    if (!mounted) return;
    setState(() => _sites = sites);
  }

  @override
  Widget build(BuildContext context) {
    final List<Zhanyuan> filtered = _filtered;
    final int activeCount = _sites.where((Zhanyuan z) => z.isActive).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('站源管理'),
        actions: <Widget>[
          TextButton(
            onPressed: _sites.isEmpty ? null : () => unawaited(_selectAll()),
            child: const Text(
              '全选',
              style: TextStyle(fontSize: VboxTypography.s14),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: VboxSpacing.lg),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
            child: TextField(
              controller: _search,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontSize: VboxTypography.s14),
              decoration: const InputDecoration(
                hintText: '搜索站点',
                isDense: true,
                border: OutlineInputBorder(borderRadius: VboxRadii.button),
              ),
              onChanged: (String value) => setState(() => _keyword = value.trim()),
            ),
          ),
          const SizedBox(height: VboxSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
            child: Text(
              '启用 $activeCount/${_sites.length} 个站点',
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          if (filtered.isEmpty) _buildEmpty(context) else _buildRows(filtered),
        ],
      ),
    );
  }

  /// 站点行列表（对齐 iOS L3072-L3092）。
  Widget _buildRows(List<Zhanyuan> sites) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < sites.length; i++) ...<Widget>[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: VboxSpacing.md,
                color: Theme.of(context).dividerColor,
              ),
            _row(sites[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(Zhanyuan site) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: VboxSpacing.xs),
                Text(
                  site.searchUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: VboxSpacing.md),
          Switch.adaptive(
            value: site.isActive,
            onChanged: (bool value) => unawaited(_toggle(site, value)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final Color gray = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.xxxl,
      ),
      child: Center(
        child: Text(
          _sites.isEmpty ? '暂无站源' : '未找到匹配站点',
          style: TextStyle(fontSize: VboxTypography.s14, color: gray),
        ),
      ),
    );
  }

  /// 切换单个站点（对齐 iOS `toggleSite`：落库 + 本地即时更新）。
  Future<void> _toggle(Zhanyuan site, bool active) async {
    await _store.setZhanyuanActive(
      name: site.name,
      searchUrl: site.searchUrl,
      active: active,
    );
    if (!mounted) return;
    setState(() {
      _sites = _sites
          .map(
            (Zhanyuan z) => z.name == site.name ? z.copyWith(isActive: active) : z,
          )
          .toList(growable: false);
    });
  }

  /// 全选（对齐 iOS L3099-L3105：仅把未启用站点置为启用）。
  Future<void> _selectAll() async {
    final List<Zhanyuan> inactive =
        _sites.where((Zhanyuan z) => !z.isActive).toList(growable: false);
    if (inactive.isEmpty) return;
    await _store.setZhanyuanActiveAll(
      inactive
          .map((Zhanyuan z) => (z.name, z.searchUrl))
          .toList(growable: false),
      true,
    );
    if (!mounted) return;
    setState(() {
      _sites = _sites
          .map((Zhanyuan z) => z.copyWith(isActive: true))
          .toList(growable: false);
    });
  }
}