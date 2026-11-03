/// 福利平台设置页（批次 H · H-07）。
///
/// 唯一真相源：iOS `vbox/Views/WelfareSettingsView.swift`（内置版）与
/// `vbox/WelfareRemote/RemoteWelfareSettingsView.swift`（远程源版）。
///
/// 结构对齐（远程源版为主，与 Flutter 远程源驱动的福利专区一致）：
///   · ①「使用福利远程源」开关（`fuli_remote_source_enabled`，默认开）；
///   · ②「远程源状态」行 + 「立即同步」（拉取中显示进度圈；副标题展示
///     `version: x` 或「上次成功：…」，W-福8 对齐 iOS `statusDetail`）；
///   · ③「代理设置」：代理 URL 输入 + 保存 / 清除 + 「平台代理开关」折叠列表
///     （未设置代理时置灰禁用）；
///   · ④ 平台列表按分类（视频 / 直播 / 漫画）分组：图标 + 名称 + `[platformKey]`
///     + 描述 + 当前域名（自定义优先，回退默认首个）+ 进入「编辑域名」；
///   · ⑤「调试」：清空远程源缓存。
///
/// 关闭远程源开关 → 远程源关闭态（沿用 iOS `builtinSettingsBody` 的「开关 + 代理」
/// 布局）：开关 + 代理设置 + 「请开启上方「使用福利远程源」」提示。
/// 差异登记：Flutter 端**只保留远程源一套**，不移植内置资源版，故关闭时既不渲染
/// 也不回退任何内置平台列表。
///
/// 数据与差异登记：
///   · 平台配置 / 开关来自 [WelfarePlatformController]（H-01，App 级 Provider）；
///   · 代理与自定义域名来自 [WelfareProxyStore] / [WelfareDomainStore]
///     （H-07，契约键 `welfare_proxy_url_v1` / `welfare_proxy_enabled_platforms_v1`
///     / `welfare_custom_domains_v2`）；
///   · 域名 / 代理变更即经 [WelfarePlatformRouter.triggerServiceReset] 触发对应
///     Service 重探测（W-福6，对齐 iOS）。纯 JS 脚本仍「下次进入」重新解析
///     （对齐 iOS JS Spider 语义，避免设置页初始化脚本引擎）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/time_utils.dart';
import '../../../data/datasources/local/welfare_domain_store.dart';
import '../../../data/datasources/local/welfare_proxy_store.dart';
import '../../../domain/entities/welfare/welfare.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../welfare/welfare_platform_controller.dart';
import '../../welfare/welfare_platform_router.dart';
import '../../widgets/vbox/vbox.dart';
import 'welfare_home_page.dart' show welfarePlatformIcon;

/// 福利平台设置页。
class WelfareSettingsPage extends StatefulWidget {
  /// 构造（依赖可注入，便于单测；缺省走上层 Provider / 共享实例）。
  const WelfareSettingsPage({
    super.key,
    this.controller,
    this.proxyStore,
    this.domainStore,
    this.router,
  });

  /// 平台配置控制器（缺省取上层 `Provider<WelfarePlatformController>`）。
  final WelfarePlatformController? controller;

  /// 代理存储（缺省 [WelfareProxyStore.shared]）。
  final WelfareProxyStore? proxyStore;

  /// 域名存储（缺省 [WelfareDomainStore.shared]）。
  final WelfareDomainStore? domainStore;

  /// 福利平台路由（域名 / 代理变更触发 Service 重探测；缺省自建）。
  final WelfarePlatformRouter? router;

  @override
  State<WelfareSettingsPage> createState() => _WelfareSettingsPageState();
}

class _WelfareSettingsPageState extends State<WelfareSettingsPage> {
  late final TextEditingController _proxyInput;

  WelfarePlatformController get _controller =>
      widget.controller ?? context.read<WelfarePlatformController>();

  WelfareProxyStore get _proxyStore =>
      widget.proxyStore ?? WelfareProxyStore.shared;

  WelfareDomainStore get _domainStore =>
      widget.domainStore ?? WelfareDomainStore.shared;

  /// 福利平台路由（`late final`：避免每次调用新建实例）。
  late final WelfarePlatformRouter _router;

  bool _proxyExpanded = false;

  @override
  void initState() {
    super.initState();
    _router = widget.router ?? WelfarePlatformRouter();
    _proxyInput = TextEditingController(text: _proxyStore.proxyURL);
    // 恢复落盘数据（幂等，对齐 iOS `onAppear` 预填代理输入框）。
    _hydrate();
  }

  @override
  void dispose() {
    _proxyInput.dispose();
    super.dispose();
  }

  Future<void> _hydrate() async {
    await _proxyStore.load();
    await _domainStore.load();
    if (!mounted) return;
    if (_proxyInput.text.isEmpty) {
      _proxyInput.text = _proxyStore.proxyURL;
    }
  }

  // ─────────────── 动作 ───────────────

  void _saveProxy() {
    final String trimmed = _proxyInput.text.trim();
    if (trimmed.isEmpty) return;
    _proxyStore.setProxyURL(trimmed);
    VboxToast.show(context, '代理已保存');
    FocusScope.of(context).unfocus();
  }

  void _clearProxy(List<WelfarePlatform> allPlatforms) {
    _proxyStore.clearProxyURL();
    _proxyInput.clear();
    // 对齐 iOS `clearProxy`：重置所有平台服务（代理已无 → 各服务回落直连域名）。
    for (final WelfarePlatform platform in allPlatforms) {
      _router.triggerServiceReset(platform);
    }
    VboxToast.show(context, '代理已清除');
  }

  Future<void> _manualRefresh() async {
    final WelfarePlatformController controller = _controller;
    await controller.refresh();
    if (!mounted) return;
    if (controller.loadState == WelfarePlatformLoadState.loaded) {
      VboxToast.show(context, '已同步 · ${controller.totalPlatformCount} 个平台');
    } else {
      VboxToast.show(context, '同步失败：${controller.errorMessage ?? '未知错误'}');
    }
  }

  void _clearCache() {
    _controller.clearCache();
    VboxToast.show(context, '已清空远程源缓存');
  }

  void _openDomainEdit(WelfarePlatform platform) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) => WelfareDomainEditPage(
        platform: platform,
        domainStore: widget.domainStore,
        router: widget.router,
      ),
    ));
  }

  // ─────────────── 构建 ───────────────

  @override
  Widget build(BuildContext context) {
    final WelfarePlatformController controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('福利平台设置'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          controller,
          _proxyStore,
          _domainStore,
          _proxyInput,
        ]),
        builder: (BuildContext context, Widget? _) {
          return controller.switchEnabled
              ? _remoteBody(context, controller)
              : _remoteDisabledBody(context, controller);
        },
      ),
    );
  }

  /// 远程源版主体（对齐 iOS `RemoteWelfareSettingsView`）。
  Widget _remoteBody(
    BuildContext context,
    WelfarePlatformController controller,
  ) {
    final List<WelfarePlatform> allPlatforms = <WelfarePlatform>[
      for (final WelfarePlatformCategory category
          in WelfarePlatformCategory.values)
        ...controller.platformsIn(category),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: VboxSpacing.xxl),
      children: <Widget>[
        _switchSection(context, controller),
        _statusSection(context, controller),
        _proxySection(context, allPlatforms),
        for (final WelfarePlatformCategory category
            in WelfarePlatformCategory.values) ...<Widget>[
          if (controller.platformsIn(category).isNotEmpty) ...<Widget>[
            _sectionHeader(context, category.displayName),
            for (final WelfarePlatform platform
                in controller.platformsIn(category))
              _platformRow(context, platform),
          ],
        ],
        _sectionHeader(context, '调试'),
        ListTile(
          leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
          title: Text(
            '清空远程源缓存',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          onTap: _clearCache,
        ),
      ],
    );
  }

  /// 远程源关闭态（沿用 iOS `WelfareSettingsView.builtinSettingsBody` 的布局骨架）。
  Widget _remoteDisabledBody(
    BuildContext context,
    WelfarePlatformController controller,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: VboxSpacing.xxl),
      children: <Widget>[
        _switchSection(context, controller),
        _proxySection(context, const <WelfarePlatform>[]),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VboxSpacing.lg,
            VboxSpacing.xl,
            VboxSpacing.lg,
            VboxSpacing.sm,
          ),
          child: Column(
            children: <Widget>[
              Icon(
                Icons.arrow_upward_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: VboxSpacing.sm),
              const Text(
                '请开启上方「使用福利远程源」',
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: VboxSpacing.xs),
              Text(
                '开启后可在远程源设置页管理各平台的域名和代理',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────── 分区 ───────────────

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(
            VboxSpacing.lg, VboxSpacing.xl, VboxSpacing.lg, VboxSpacing.sm),
        child: Text(
          title,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Widget _sectionFooter(BuildContext context, String text) => Padding(
        padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
        child: Text(
          text,
          style: TextStyle(
            fontSize: VboxTypography.s12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );

  /// ① 远程源开关。
  Widget _switchSection(
    BuildContext context,
    WelfarePlatformController controller,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        ListTile(
          title: const Text(
            '使用福利远程源',
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            controller.switchEnabled
                ? '开启：使用远程源中的福利平台列表'
                : '关闭：暂不加载远程源平台列表',
            style: TextStyle(fontSize: VboxTypography.s12, color: scheme.outline),
          ),
          trailing: Switch.adaptive(
            value: controller.switchEnabled,
            activeTrackColor: scheme.primary,
            onChanged: (bool value) => controller.setSwitchEnabled(value),
          ),
        ),
        _sectionFooter(
          context,
          '关闭后不再加载远程源平台列表，福利专区将显示为「远程源已关闭」。',
        ),
      ],
    );
  }

  /// ② 远程源状态行 + 立即同步。
  Widget _statusSection(
    BuildContext context,
    WelfarePlatformController controller,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String title) = switch (controller.loadState) {
      WelfarePlatformLoadState.idle => (
          Icons.cloud_off_rounded,
          scheme.outline,
          '未加载',
        ),
      WelfarePlatformLoadState.loading => (
          Icons.cloud_download_rounded,
          Colors.blue,
          '正在拉取…',
        ),
      WelfarePlatformLoadState.loaded => (
          Icons.cloud_done_rounded,
          Colors.green,
          '已就绪 · ${controller.totalPlatformCount} 个平台',
        ),
      WelfarePlatformLoadState.failed => (
          Icons.cloud_off_rounded,
          Colors.red,
          '拉取失败',
        ),
    };
    final String? detail = _statusDetail(controller);
    return Column(
      children: <Widget>[
        _sectionHeader(context, '远程源状态'),
        ListTile(
          leading: Icon(icon, color: color),
          title: Text(
            title,
            style: const TextStyle(
              fontSize: VboxTypography.s14,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: detail == null || detail.isEmpty
              ? null
              : Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: VboxTypography.s12, color: scheme.outline),
                ),
          trailing: controller.loadState == WelfarePlatformLoadState.loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton.icon(
                  onPressed: _manualRefresh,
                  icon: const Icon(Icons.sync_rounded, size: VboxTypography.s16),
                  label: const Text('立即同步'),
                ),
        ),
      ],
    );
  }

  /// 状态副标题（W-福8，对齐 iOS `RemoteWelfareSettingsView.statusDetail`）：
  /// 已就绪且有 version → `version: x`；失败 → 错误信息；其余（含未加载 / 拉取中）
  /// → 「上次成功：…」（无记录则为 null，不渲染副标题）。
  String? _statusDetail(WelfarePlatformController controller) {
    switch (controller.loadState) {
      case WelfarePlatformLoadState.loaded:
        final String? version = controller.lastConfigVersion;
        if (version != null && version.isNotEmpty) return 'version: $version';
        return _lastSuccessText(controller);
      case WelfarePlatformLoadState.failed:
        return controller.errorMessage;
      case WelfarePlatformLoadState.idle:
      case WelfarePlatformLoadState.loading:
        return _lastSuccessText(controller);
    }
  }

  /// 「上次成功：yyyy-MM-dd HH:mm」（Unix 秒 ≤ 0 视为从未成功）。
  String? _lastSuccessText(WelfarePlatformController controller) {
    final int seconds = controller.lastSuccessTimeSeconds;
    if (seconds <= 0) return null;
    return '上次成功：'
        '${TimeUtils.formatUnixSeconds(seconds, pattern: 'yyyy-MM-dd HH:mm')}';
  }

  /// ③ 代理设置（输入 + 保存/清除 + 平台代理开关折叠列表）。
  Widget _proxySection(
    BuildContext context,
    List<WelfarePlatform> allPlatforms,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasProxy = _proxyStore.hasValidProxy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _sectionHeader(context, '代理设置'),
        Padding(
          padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
          child: Row(
            children: <Widget>[
              Icon(Icons.network_check, size: 20, color: scheme.primary),
              const SizedBox(width: VboxSpacing.sm),
              Expanded(
                child: TextField(
                  controller: _proxyInput,
                  style: const TextStyle(fontSize: VboxTypography.s14),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: '输入代理地址，如 https://your-proxy.com/?url=',
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    border: const OutlineInputBorder(
                      borderRadius: VboxRadii.card,
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _saveProxy(),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
          child: Row(
            children: <Widget>[
              Expanded(
                child: VboxButton(
                  label: '保存代理',
                  expanded: true,
                  onPressed: _proxyInput.text.trim().isEmpty ? null : _saveProxy,
                ),
              ),
              const SizedBox(width: VboxSpacing.md),
              if (hasProxy)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _clearProxy(allPlatforms),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: VboxColors.danger,
                      side: BorderSide(color: VboxColors.danger.withValues(alpha: 0.4)),
                    ),
                    child: const Text('清除代理'),
                  ),
                ),
            ],
          ),
        ),
        _sectionFooter(context, '支持 URL 转发代理格式，在代理地址末尾拼接原始URL'),
        const SizedBox(height: VboxSpacing.lg),
        const Divider(),
        // 平台代理开关（折叠）
        ListTile(
          dense: true,
          leading: Icon(
            _proxyExpanded ? Icons.expand_more : Icons.chevron_right,
            size: VboxTypography.s16,
            color: scheme.outline,
          ),
          title: const Text(
            '平台代理开关',
            style: TextStyle(fontSize: VboxTypography.s14, fontWeight: FontWeight.w500),
          ),
          trailing: Text(
            hasProxy ? '${_proxyStore.enabledProxyCount(allPlatforms.map((WelfarePlatform p) => p.name))}/${allPlatforms.length} 已开启' : '未设置代理',
            style: TextStyle(fontSize: VboxTypography.s12, color: scheme.outline),
          ),
          onTap: () => setState(() => _proxyExpanded = !_proxyExpanded),
        ),
        if (_proxyExpanded)
          Column(
            children: <Widget>[
              for (int i = 0; i < allPlatforms.length; i++) ...<Widget>[
                _proxyPlatformRow(context, allPlatforms[i], hasProxy),
                if (i < allPlatforms.length - 1)
                  const Divider(height: 1, indent: VboxSpacing.xxl),
              ],
            ],
          )
        else
          const SizedBox.shrink(),
        const SizedBox(height: VboxSpacing.sm),
      ],
    );
  }

  /// 单平台代理开关行（未设置代理时置灰禁用）。
  Widget _proxyPlatformRow(
    BuildContext context,
    WelfarePlatform platform,
    bool hasProxy,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: hasProxy ? 1.0 : 0.5,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: VboxSpacing.xxl, right: VboxSpacing.lg),
        leading: Icon(welfarePlatformIcon(platform.icon), size: 18, color: scheme.primary),
        title: Text(
          platform.name,
          style: const TextStyle(fontSize: VboxTypography.s14),
        ),
        trailing: Switch.adaptive(
          value: _proxyStore.isProxyEnabled(platform.name),
          activeTrackColor: scheme.primary,
          onChanged: hasProxy
              ? (bool value) {
                  _proxyStore.setProxyEnabled(value, platform.name);
                  // 对齐 iOS：开启代理即触发该平台 Service 重探测（关闭不触发）。
                  if (value) _router.triggerServiceReset(platform);
                }
              : null,
        ),
      ),
    );
  }

  /// ④ 平台行（对齐 iOS `platformRow`：名称 + 代理标识 + 当前域名 + 进入编辑）。
  Widget _platformRow(BuildContext context, WelfarePlatform platform) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String currentDomain = _currentDomain(platform);
    return ListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          welfarePlatformIcon(platform.icon),
          size: 18,
          color: scheme.primary,
        ),
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              platform.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: VboxTypography.s15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (_proxyStore.isProxyEnabled(platform.name)) ...<Widget>[
            const SizedBox(width: VboxSpacing.xs),
            const Icon(Icons.network_check, size: VboxTypography.s12, color: Colors.green),
          ],
          const SizedBox(width: VboxSpacing.xs),
          Text(
            '[${platform.platformKey}]',
            style: TextStyle(
              fontSize: VboxTypography.s10,
              color: scheme.outline.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
      subtitle: Text(
        platform.desc,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: VboxTypography.s12, color: scheme.outline),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Text(
              currentDomain,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s11,
                fontFamily: 'monospace',
                color: scheme.outline,
              ),
            ),
          ),
          Icon(Icons.chevron_right, size: VboxTypography.s16, color: scheme.outline),
        ],
      ),
      onTap: () => _openDomainEdit(platform),
    );
  }

  /// 当前域名：自定义域名优先，回退默认首个（对齐 iOS `currentDomain(for:)`）。
  String _currentDomain(WelfarePlatform platform) {
    final List<String> customs = _domainStore.domains(platform.name);
    return customs.isNotEmpty ? customs.first : platform.primaryHost;
  }
}

/// 福利平台域名编辑页（批次 H · H-07）。
///
/// 对齐 iOS `RemoteWelfareSettingsView.domainEditSheet`（Form 五段）：
///   · 平台信息（图标 + 名称 + `[platformKey]`）；
///   · 添加新域名（URL 校验：`http(s)://` 前缀 + 可解析）；
///   · 默认域名（按优先级编号 + 当前域名打勾）；
///   · 自定义域名（删除单项 / 全部删除，空态提示）；
///   · 完成（整行主色按钮）。
///
/// 域名写入 [WelfareDomainStore]（契约键 `welfare_custom_domains_v2`），
/// 变更即经 [WelfarePlatformRouter.triggerServiceReset] 触发对应 Service 重探测
/// （W-福6，对齐 iOS `addCustomDomain` / `removeCustomDomain` / `clearCustomDomains`）。
class WelfareDomainEditPage extends StatefulWidget {
  /// 构造。
  const WelfareDomainEditPage({
    super.key,
    required this.platform,
    this.domainStore,
    this.router,
  });

  /// 目标平台。
  final WelfarePlatform platform;

  /// 域名存储（缺省 [WelfareDomainStore.shared]）。
  final WelfareDomainStore? domainStore;

  /// 福利平台路由（域名变更触发 Service 重探测；缺省自建）。
  final WelfarePlatformRouter? router;

  @override
  State<WelfareDomainEditPage> createState() => _WelfareDomainEditPageState();
}

class _WelfareDomainEditPageState extends State<WelfareDomainEditPage> {
  late final TextEditingController _domainInput;

  WelfareDomainStore get _domainStore =>
      widget.domainStore ?? WelfareDomainStore.shared;

  /// 福利平台路由（`late final`：避免每次调用新建实例）。
  late final WelfarePlatformRouter _router;

  @override
  void initState() {
    super.initState();
    _router = widget.router ?? WelfarePlatformRouter();
    _domainInput = TextEditingController();
    // 恢复落盘数据（幂等；默认共享实例已由 App 装配预加载）。
    _domainStore.load();
  }

  @override
  void dispose() {
    _domainInput.dispose();
    super.dispose();
  }

  // ─────────────── 动作 ───────────────

  void _addDomain() {
    final String domain = _domainInput.text.trim();
    final bool valid = domain.isNotEmpty &&
        (domain.startsWith('http://') || domain.startsWith('https://')) &&
        Uri.tryParse(domain) != null;
    if (!valid) {
      VboxToast.show(context, '域名格式错误');
      return;
    }
    _domainStore.addDomain(widget.platform.name, domain);
    _domainInput.clear();
    // 对齐 iOS：域名变更即触发对应 Service 重新探测。
    _router.triggerServiceReset(widget.platform);
    VboxToast.show(context, '域名已添加');
  }

  void _removeDomain(String domain) {
    _domainStore.removeDomain(widget.platform.name, domain);
    _router.triggerServiceReset(widget.platform);
    VboxToast.show(context, '域名已删除');
  }

  void _clearDomains() {
    _domainStore.clearDomains(widget.platform.name);
    _router.triggerServiceReset(widget.platform);
    VboxToast.show(context, '已恢复默认域名');
  }

  // ─────────────── 构建 ───────────────

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final WelfarePlatform platform = widget.platform;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑域名'),
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ),
      body: ListenableBuilder(
        // 同时监听输入控制器：输入非空时「添加域名」按钮实时可用（对齐 iOS 实时校验）。
        listenable: Listenable.merge(<Listenable>[_domainStore, _domainInput]),
        builder: (BuildContext context, Widget? _) {
          final List<String> customs = _domainStore.domains(platform.name);
          final String currentDomain =
              customs.isNotEmpty ? customs.first : platform.primaryHost;
          return ListView(
            padding: const EdgeInsets.only(bottom: VboxSpacing.xxl),
            children: <Widget>[
              // 平台信息
              _header(context, '平台'),
              ListTile(
                leading: Icon(
                  welfarePlatformIcon(platform.icon),
                  color: scheme.primary,
                ),
                title: Text(platform.name),
                trailing: Text(
                  '[${platform.platformKey}]',
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: scheme.outline,
                  ),
                ),
              ),
              // 添加新域名
              _header(context, '添加新域名'),
              Padding(
                padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextField(
                      controller: _domainInput,
                      style: const TextStyle(fontSize: VboxTypography.s14),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: 'https://example.com',
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        border: const OutlineInputBorder(
                          borderRadius: VboxRadii.card,
                          borderSide: BorderSide.none,
                        ),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addDomain(),
                    ),
                    const SizedBox(height: VboxSpacing.md),
                    VboxButton(
                      label: '添加域名',
                      expanded: true,
                      onPressed: _domainInput.text.trim().isEmpty ? null : _addDomain,
                    ),
                  ],
                ),
              ),
              // 默认域名（按优先级）
              _header(context, '默认域名（按优先级）'),
              if (platform.defaultHosts.isEmpty)
                Padding(
                  padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                  child: Text(
                    '该平台未配置默认域名',
                    style: TextStyle(fontSize: VboxTypography.s13, color: scheme.outline),
                  ),
                )
              else
                for (int i = 0; i < platform.defaultHosts.length; i++) ...<Widget>[
                  ListTile(
                    dense: true,
                    leading: Text(
                      '${i + 1}.',
                      style: TextStyle(fontSize: VboxTypography.s13, color: scheme.outline),
                    ),
                    title: Text(
                      platform.defaultHosts[i],
                      style: const TextStyle(fontSize: VboxTypography.s13),
                    ),
                    trailing: currentDomain == platform.defaultHosts[i]
                        ? const Icon(Icons.check_circle, size: VboxTypography.s18, color: Colors.green)
                        : null,
                  ),
                ],
              // 自定义域名
              _header(context, '自定义域名'),
              if (customs.isEmpty)
                Padding(
                  padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                  child: Text(
                    '暂无自定义域名。添加后会显示在这里，可随时删除。',
                    style: TextStyle(fontSize: VboxTypography.s13, color: scheme.outline),
                  ),
                )
              else ...<Widget>[
                for (final String domain in customs)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.link, size: VboxTypography.s14, color: scheme.primary),
                    title: Text(
                      domain,
                      style: const TextStyle(fontSize: VboxTypography.s13),
                    ),
                    trailing: IconButton(
                      tooltip: '删除',
                      icon: Icon(Icons.cancel, size: VboxTypography.s18, color: scheme.outline),
                      onPressed: () => _removeDomain(domain),
                    ),
                  ),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.restart_alt, size: VboxTypography.s16, color: scheme.error),
                  title: Text(
                    '全部删除自定义域名',
                    style: TextStyle(
                      fontSize: VboxTypography.s13,
                      color: scheme.error,
                    ),
                  ),
                  onTap: _clearDomains,
                ),
              ],
              // 完成
              const SizedBox(height: VboxSpacing.xl),
              Padding(
                padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                child: VboxButton(
                  label: '完成',
                  expanded: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(
            VboxSpacing.lg, VboxSpacing.xl, VboxSpacing.lg, VboxSpacing.sm),
        child: Text(
          title,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}
