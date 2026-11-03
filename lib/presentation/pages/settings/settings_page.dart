/// 设置页（批次 I · I-03 分区骨架 + I-04 显示模式 + I-05 更新入口；
/// Wave D · O-源1/O-源2/O-源3 接入源治理分区）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift`
///   · L106-L134（`titleBar` + `settingsContent` 分区顺序）；
///   · L136-L173（`skinSettingsSection`：皮肤四选 + 跟随系统）；
///   · L175-L220（`playbackSettingsSection`：自定义弹幕源 + 搜索调试面板）；
///   · L398-L493（`fallbackSection` 切片资源 + `zhanyuanSiteSection` 站源管理）；
///   · 各 `SettingsSection` / `SettingsToggleRow` / `SettingsNavigationRow`。
///
/// **落地范围（如实登记）**：本轮落地「皮肤（B4 组件 + 跟随系统）」「显示模式（I-04）」
/// 「播放设置」「切片资源（Wave D）」「站源管理（Wave D）」「TG 搜索」「订阅配置」
/// 「工具入口（网盘管理；书架已按 iOS 移除；备份还原仅在个人中心
/// 登录态，对齐 iOS；远程源独立页已按唯一真相源移除）」
/// 「TMDB（G-06）」「存储管理」「日志调试」「关于」十三个分区；
/// iOS 侧其余域分区（福利 / 账号等）在 Flutter 侧对应域功能尚未实现。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../../data/datasources/local/baidu_playback_cache_store.dart';
import '../../../data/datasources/local/cloud_play_item_cache_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../data/datasources/local/source_governance_store.dart';
import '../../../data/datasources/local/subscribe_config_store.dart';
import '../../../data/datasources/local/tg_search_config_store.dart';
import '../../../domain/entities/tg/tg_channel.dart';
import '../../../domain/entities/spider/site_config.dart';
import '../../../domain/usecases/content_browse_usecases.dart';
import '../../../domain/usecases/detail_playback_usecases.dart';
import '../../../domain/usecases/source_governance_usecases.dart';
import '../../../platform/update/update.dart';
import '../../theme/theme.dart';
import '../../ui_mode/ui_mode.dart';
import '../../widgets/log_viewer_page.dart';
import '../../widgets/settings/remote_default_source_section.dart';
import '../../widgets/update/update_sheet.dart';
import '../../widgets/vbox/vbox.dart';
import '../cloud/auth_center.dart';
import '../subscribe/subscribe_config_page.dart';
import 'fallback_slice_source_page.dart';
import 'parser_manage_page.dart';
import 'tg_channel_list_page.dart';
import '../diagnostics/site_diagnostics_page.dart';
import '../tmdb/tmdb_settings_section.dart';
import 'zhanyuan_site_manage_page.dart';

/// 设置页。
class SettingsPage extends StatefulWidget {
  /// 构造。
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _danmakuUrl = TextEditingController();
  final TextEditingController _tgProxy = TextEditingController();

  bool _danmakuEnabled = false;
  bool _searchDebug = false;
  bool _logEnabled = false;

  /// 双模式兼容（契约键 `enable_dual_mode`，默认开；对齐 iOS `SpiderManager.enableDualMode`）。
  bool _dualMode = true;

  /// 站点总数（G-08 站点诊断入口副文本；来自 `ContentBrowseUseCases.listSites()`）。
  int _siteTotal = 0;

  /// 已启用站源数（Wave D；来自 `SourceGovernanceUseCases.activeZhanyuanCount()`）。
  int _zhanyuanActive = 0;

  /// 缓存行副标题（对齐 iOS `cacheSize`：占位「256 MB」，清除后置「0 MB」）。
  String _cacheSize = '256 MB';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _danmakuUrl.dispose();
    _tgProxy.dispose();
    super.dispose();
  }

  /// 读取契约键初值（对齐 iOS `@AppStorage` 的初始绑定）。
  Future<void> _load() async {
    final PrefsManager prefs = PrefsManager.instance;
    final ContentBrowseUseCases browse = context.read<ContentBrowseUseCases>();
    final bool danmaku = await prefs.getBool('custom_danmaku_source_enabled');
    final String url = await prefs.getString('custom_danmaku_source_url');
    final bool debug = await prefs.getBool('show_search_debug');
    final bool log = await prefs.getBool('app_log_enabled');
    final bool dualMode = await prefs.getBool('enable_dual_mode');
    final String tgProxy =
        await prefs.getString(TGSearchConfigStore.proxyUrlKey);
    final Result<List<SiteConfig>> sites = await browse.listSites();
    // Wave D：恢复源治理配置（兜底开关 / 自定义切片源 / 解析器）。
    await SourceGovernanceStore.instance.load();
    final int active = await _maybeGovernance()?.activeZhanyuanCount() ?? 0;
    if (!mounted) return;
    setState(() {
      _danmakuEnabled = danmaku;
      _danmakuUrl.text = url;
      _searchDebug = debug;
      _logEnabled = log;
      _dualMode = dualMode;
      _tgProxy.text = tgProxy;
      _siteTotal = sites.valueOrNull?.length ?? 0;
      _zhanyuanActive = active;
    });
  }

  /// 读取可选源治理用例（未注入时返回 null，便于 widget 测试无源治理运行）。
  SourceGovernanceUseCases? _maybeGovernance() {
    try {
      return context.read<SourceGovernanceUseCases>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// 刷新站源启用计数（Wave D；从站源管理页返回后调用）。
  Future<void> _refreshZhanyuanCount() async {
    final int active = await _maybeGovernance()?.activeZhanyuanCount() ?? 0;
    if (!mounted) return;
    setState(() => _zhanyuanActive = active);
  }

  @override
  Widget build(BuildContext context) {
    final VboxSkinController skin = context.watch<VboxSkinController>();
    final UiFormController form = context.watch<UiFormController>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(
          top: VboxSpacing.lg,
          bottom: VboxSpacing.xxxl,
        ),
        children: <Widget>[
          _skinSection(skin),
          _displayModeSection(form),
          _playbackSection(),
          _tgSection(),
          _subscribeSection(),
          // Wave D：切片资源（O-源1 兜底开关 + O-源2 解析器 + O-源3 切片源）。
          _sliceSourceSection(),
          // Wave D：站源管理（O-源3 站源启停）。
          _zhanyuanSection(),
          _toolsSection(),
          _diagnosticsSection(),
          // G-06：TMDB 封面 / 演职增强设置。
          _tmdbSection(),
          _storageSection(),
          _developerSection(),
          _aboutSection(),
        ],
      ),
    );
  }

  /// 皮肤（四选 2×2 + 跟随系统；对齐 iOS `skinSettingsSection`）。
  Widget _skinSection(VboxSkinController skin) {
    final bool visual =
        skin.skin == VboxSkin.liquid || skin.skin == VboxSkin.frosted;
    return VboxSettingsSection(
      title: '皮肤',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(VboxSpacing.md),
          child: Column(
            children: <Widget>[
              VboxSkinPicker(
                selected: skin.skin,
                onSelected: skin.selectSkin,
              ),
              const SizedBox(height: VboxSpacing.md),
              Opacity(
                opacity: visual ? 0.55 : 1,
                child: VboxSettingsRow.toggle(
                  title: '黑暗/浅色跟随手机外观',
                  subtitle: '开启后随系统外观切换',
                  icon: Icons.brightness_6,
                  value: skin.followsSystem,
                  // 视觉皮肤（液态 / 磨砂）下禁用（对齐 iOS L163）。
                  onChanged: visual ? (_) {} : skin.setFollowsSystem,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 显示模式（I-04：自动 / 手机竖屏 / 大屏横屏，写入 `app_ui_form_override`）。
  Widget _displayModeSection(UiFormController form) {
    return VboxSettingsSection(
      title: '显示模式',
      children: <Widget>[
        VboxSettingsRow.navigation(
          title: '显示模式',
          subtitle: '当前：${form.override.title}',
          icon: Icons.aspect_ratio,
          onTap: () => _pickDisplayMode(form),
        ),
      ],
    );
  }

  /// 播放设置（自定义弹幕源 + 搜索调试面板；对齐 iOS `playbackSettingsSection`）。
  Widget _playbackSection() {
    final PrefsManager prefs = PrefsManager.instance;
    return VboxSettingsSection(
      title: '播放设置',
      children: <Widget>[
        VboxSettingsRow.toggle(
          title: '自定义弹幕源',
          subtitle: _danmakuEnabled ? '已开启 — 使用自定义弹幕API地址' : '关闭 — 使用默认弹幕源',
          icon: Icons.chat_bubble,
          value: _danmakuEnabled,
          onChanged: (bool value) async {
            setState(() => _danmakuEnabled = value);
            await prefs.set('custom_danmaku_source_enabled', value);
          },
        ),
        if (_danmakuEnabled)
          VboxSettingsInputRow(
            controller: _danmakuUrl,
            hint: 'https://your-danmu-api.com',
            onChanged: (String value) =>
                prefs.set('custom_danmaku_source_url', value),
          ),
        VboxSettingsRow.toggle(
          title: '搜索调试面板',
          icon: Icons.search,
          value: _searchDebug,
          onChanged: (bool value) async {
            setState(() => _searchDebug = value);
            await prefs.set('show_search_debug', value);
          },
        ),
      ],
    );
  }

  /// 切片资源（Wave D · O-源1/O-源2/O-源3；对齐 iOS `fallbackSection` L398-L464）。
  ///
  /// 三行：兜底切片资源开关（契约键 `fallback_enabled`）+
  /// 「管理自定义切片源」（契约键 `custom_fallback_sites`）+
  /// 「管理自定义解析器」（契约键 `user_parsers`）。
  Widget _sliceSourceSection() {
    final SourceGovernanceStore store = SourceGovernanceStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? _) => VboxSettingsSection(
        title: '切片资源',
        children: <Widget>[
          VboxSettingsRow.toggle(
            title: '启用兜底切片资源',
            subtitle: '主源无结果时并入自定义切片源搜索',
            icon: Icons.dns,
            value: store.fallbackEnabled,
            onChanged: (bool value) =>
                unawaited(store.setFallbackEnabled(value)),
          ),
          VboxSettingsRow.navigation(
            title: '管理自定义切片源',
            subtitle: '${store.customFallbackSites.length} 个',
            icon: Icons.add_circle,
            onTap: () => _push(const FallbackSliceSourcePage()),
          ),
          VboxSettingsRow.navigation(
            title: '管理自定义解析器',
            subtitle: '${store.userParsers.length} 个',
            icon: Icons.auto_fix_high,
            onTap: () => _push(const ParserManagePage()),
          ),
        ],
      ),
    );
  }

  /// 站源管理（Wave D · O-源3；对齐 iOS `zhanyuanSiteSection` L466-L493）。
  Widget _zhanyuanSection() {
    return VboxSettingsSection(
      title: '站源管理',
      children: <Widget>[
        VboxSettingsRow.navigation(
          title: '管理站源（启用/禁用）',
          subtitle: '$_zhanyuanActive 个启用',
          icon: Icons.public,
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) =>
                    const ZhanyuanSiteManagePage(),
              ),
            );
            await _refreshZhanyuanCount();
          },
        ),
      ],
    );
  }

  /// TG 搜索设置（代理地址 + 频道来源 + 频道管理入口；对齐 iOS `tgSearchSettingsSection`）。
  Widget _tgSection() {
    final TGSearchConfigStore tg = context.watch<TGSearchConfigStore>();
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color rowBackground = (isDark
            ? VboxColors.secondarySystemGroupedBackgroundDark
            : VboxColors.secondarySystemGroupedBackgroundLight)
        .withValues(alpha: 0.7);
    final Color inputFill = isDark
        ? VboxColors.tertiarySystemGroupedBackgroundDark
        : VboxColors.tertiarySystemGroupedBackgroundLight;
    final Color secondary =
        isDark ? VboxColors.secondaryLabelDark : VboxColors.secondaryLabelLight;
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final TextStyle labelStyle = TextStyle(
      fontSize: VboxTypography.s13,
      fontWeight: FontWeight.w500,
      color: onSurface,
    );
    final TextStyle hintStyle = TextStyle(
      fontSize: VboxTypography.s11,
      color: secondary,
    );

    return VboxSettingsSection(
      title: 'TG搜索设置',
      children: <Widget>[
        // 代理地址
        Material(
          color: rowBackground,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.lg,
              vertical: VboxSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('代理地址', style: labelStyle),
                const SizedBox(height: VboxSpacing.sm),
                TextField(
                  controller: _tgProxy,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.none,
                  keyboardType: TextInputType.url,
                  onChanged: tg.setProxyUrl,
                  style:
                      TextStyle(fontSize: VboxTypography.s15, color: onSurface),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: inputFill,
                    hintText: 'https://xxx.com/?token=xxx&url=',
                    hintStyle: TextStyle(
                      fontSize: VboxTypography.s15,
                      color: secondary,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: VboxSpacing.md,
                      vertical: VboxSpacing.md,
                    ),
                    border: const OutlineInputBorder(
                      borderRadius: VboxRadii.button,
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: VboxSpacing.sm),
                Text('支持URL转发代理，在末尾拼接原始URL', style: hintStyle),
              ],
            ),
          ),
        ),
        // 频道来源
        Material(
          color: rowBackground,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VboxSpacing.lg,
              vertical: VboxSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('频道来源', style: labelStyle),
                const SizedBox(height: VboxSpacing.sm),
                SegmentedButton<TGChannelMode>(
                  segments: TGChannelMode.values
                      .map((TGChannelMode mode) => ButtonSegment<TGChannelMode>(
                            value: mode,
                            label: Text(mode.displayName),
                          ))
                      .toList(growable: false),
                  selected: <TGChannelMode>{tg.channelMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (Set<TGChannelMode> selection) =>
                      tg.setChannelMode(selection.first),
                ),
                const SizedBox(height: VboxSpacing.sm),
                Text(tg.channelMode.description, style: hintStyle),
              ],
            ),
          ),
        ),
        // 频道管理入口
        VboxSettingsRow.navigation(
          title: 'TG频道管理',
          subtitle: '${tg.channels.length} 个自定义频道',
          icon: Icons.telegram,
          iconColor: VboxColors.tgChannelPurple,
          onTap: () => _push(const TGChannelListPage()),
        ),
      ],
    );
  }

  /// 订阅配置（对齐 iOS `subscriptionSection`，批次 G · G-07 / G-09）。
  ///
  /// iOS 端该区块 = 「管理订阅源」入口 + **远程默认源内联编辑区**（开关 /
  /// 默认源地址 / 刷新 / 清缓存 / 版本状态，无需进入子页）+ 「双模式兼容」
  /// 开关；Flutter 侧原仅落地订阅源入口、远程源设置藏在「工具 → 远程源」
  /// 子页（G-09 对齐：内联区块补入设置页，远程源页共用同一区块组件）。
  Widget _subscribeSection() {
    final SubscribeConfigStore store = context.watch<SubscribeConfigStore>();
    final PrefsManager prefs = PrefsManager.instance;
    return VboxSettingsSection(
      title: '订阅配置',
      children: <Widget>[
        VboxSettingsRow.navigation(
          title: '管理订阅源',
          subtitle:
              store.hasConfigUrls ? '${store.configUrls.length} 个源' : '未配置',
          icon: Icons.list_alt,
          iconColor: VboxColors.skinPrimaryRose,
          onTap: () => _push(const SubscribeConfigPage()),
        ),
        // 远程默认源内联编辑区（对齐 iOS 远程源区块，与远程源页共用）。
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: VboxSpacing.md),
          child: RemoteDefaultSourceSection(),
        ),
        // 双模式兼容（对齐 iOS 同区块独立行：type=3 HTTP 接口走原生搜索）。
        VboxSettingsRow.toggle(
          title: '双模式兼容',
          subtitle: 'type=3 HTTP接口走原生搜索（重启生效）',
          icon: Icons.sync,
          iconColor: VboxColors.skinPrimaryRose,
          value: _dualMode,
          onChanged: (bool value) async {
            setState(() => _dualMode = value);
            await prefs.set('enable_dual_mode', value);
          },
        ),
      ],
    );
  }

  /// 工具入口（网盘管理）。
  ///
  /// 差异登记（对齐 iOS）：iOS 设置页**没有**「备份还原」入口——其唯一入口
  /// 在个人中心功能宫格且**仅登录态显示**（`ProfileView` L464-L466）；Flutter
  /// 侧个人中心已同款实现，此处不再重复提供入口（原 G 系列曾从个人中心
  /// 迁入，现按 iOS 真相源移除）。「远程源」独立页无 iOS 对应——订阅管理走
  /// 上方「管理订阅源」（`SubscribeConfigPage`）、源发现走首页站点态覆盖层、
  /// 远程默认源开关走订阅配置内联区块，独立页及本入口已按唯一真相源移除。
  Widget _toolsSection() {
    return VboxSettingsSection(
      title: '工具',
      children: <Widget>[
        VboxSettingsRow.navigation(
          title: '网盘管理',
          icon: Icons.folder,
          onTap: () => _push(const CloudDriveAuthCenterPage()),
        ),
      ],
    );
  }

  /// 站点诊断（批次 G · G-08；对齐 iOS `SettingsViews.siteDiagnosticsSection`）。
  ///
  /// iOS 尾部显示「已加载引擎数 / 站点总数 就绪」（读 `SpiderManager.engines`）。
  /// 差异登记：Flutter 侧当前无引擎注册表，无法在不跑一轮诊断的前提下得到
  /// 「就绪数」，故尾部改显「共 N 个接口」（诚实标注，不虚标就绪）；图标
  /// `stethoscope` 在 Material 无对应，以 `medical_services` 近似，同主色。
  Widget _diagnosticsSection() {
    return VboxSettingsSection(
      title: '站点诊断',
      children: <Widget>[
        VboxSettingsRow(
          title: '接口状态检测',
          icon: Icons.medical_services,
          iconColor: VboxColors.skinPrimaryRose,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '共 $_siteTotal 个接口',
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: VboxSpacing.xs),
              const Icon(Icons.chevron_right, size: VboxTypography.s18),
            ],
          ),
          onTap: () => _push(const SiteDiagnosticsPage()),
        ),
      ],
    );
  }

  /// TMDB 设置（批次 G · G-06；对齐 iOS `SettingsViews.tmdbSettingsSection`）。
  Widget _tmdbSection() => const TmdbSettingsSection();

  /// 存储管理（对齐 iOS `SettingsViews.swift` L807 缓存管理行 + L88-L96
  /// 清除缓存确认弹窗；确认后执行 iOS L90-L95 三项清理）。
  Widget _storageSection() {
    return VboxSettingsSection(
      title: '存储管理',
      children: <Widget>[
        VboxSettingsRow.navigation(
          title: '缓存管理',
          subtitle: _cacheSize,
          icon: Icons.storage,
          onTap: () => unawaited(_confirmClearCache()),
        ),
      ],
    );
  }

  /// 清除缓存确认弹窗（对齐 iOS `.alert("清除缓存")`：取消 / 确定删除角色）。
  Future<void> _confirmClearCache() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清除缓存'),
        content: const Text('确定要清除所有缓存数据吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // ① 网盘详情页解析缓存（对齐 iOS `spiderManager.clearCloudPlayCache()`）。
    context.read<DetailPlaybackUseCases>().clearCloudPlayCache();
    // ② 百度播放缓存六键（对齐 iOS `cloudDriveManager.clearAllBaiduPlaybackCaches()`）。
    final PrefsManager prefs = PrefsManager.instance;
    await BaiduPlaybackCacheStore(prefs).clearAll();
    // ③ 统一网盘播放缓存 baidu 分区（对齐 iOS
    //    `clearUnifiedCloudPlayItems(provider: .baidu)`，见 CloudDriveManager L879）。
    await CloudPlayItemCacheStore(prefs).clear('baidu');
    // ④ 豆瓣封面流磁盘缓存：Flutter 端封面为直连抓取（无本地代理与磁盘流
    //    缓存），无对应清理面（差异登记）。
    setState(() => _cacheSize = '0 MB');
  }

  /// 日志调试（开启日志记录 + 查看日志；对齐 iOS `developerSection`）。
  Widget _developerSection() {
    final PrefsManager prefs = PrefsManager.instance;
    return VboxSettingsSection(
      title: '日志调试',
      children: <Widget>[
        VboxSettingsRow.toggle(
          title: '开启日志记录',
          subtitle: '关闭后停止写入本地日志',
          icon: Icons.article,
          value: _logEnabled,
          onChanged: (bool value) async {
            setState(() => _logEnabled = value);
            await prefs.set('app_log_enabled', value);
            // ★ 即时生效（此前只在启动时读一次契约键 → 用户打开开关后
            //   本次运行仍不记录、必须重启 App，是「开了开关日志仍空白」的根因）。
            AppLog.configure(enabled: value);
          },
        ),
        VboxSettingsRow.navigation(
          title: '查看日志',
          icon: Icons.list_alt,
          onTap: () => _push(const LogViewerPage()),
        ),
      ],
    );
  }

  /// 关于 / 更新（版本 + 检查更新；对齐 iOS `aboutSection`）。
  Widget _aboutSection() {
    return VboxSettingsSection(
      title: '关于',
      children: <Widget>[
        VboxSettingsRow(
          title: '版本',
          icon: Icons.info,
          trailing: Text(
            '${AppInfo.version}+${AppInfo.buildNumber}',
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        VboxSettingsRow.navigation(
          title: '检查更新',
          subtitle: '检查 GitHub Releases 最新版本',
          icon: Icons.system_update,
          onTap: _checkUpdate,
        ),
      ],
    );
  }

  /// 检查更新（K-更1 真实链路）：拉取版本清单 → 有新版本弹更新弹窗，
  /// 已最新 / 失败以 Toast 反馈。
  Future<void> _checkUpdate() async {
    final Updater updater = Updater.instance;
    if (updater.isChecking) return;
    final VoidCallback dismiss = VboxToast.show(
      context,
      '正在检查更新…',
      duration: const Duration(seconds: 10),
    );
    await updater.check(force: true);
    dismiss();
    if (!mounted) return;
    if (updater.hasUpdate) {
      await showUpdateSheet(context);
      return;
    }
    if (updater.updateError != null) {
      VboxToast.show(context, updater.updateError!);
      return;
    }
    VboxToast.show(context, '当前版本 ${AppInfo.version} 已是最新版本');
  }

  /// 显示模式选择（I-04）。
  Future<void> _pickDisplayMode(UiFormController form) async {
    final UiFormOverride? selected = await showDialog<UiFormOverride>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('显示模式'),
        children: <Widget>[
          for (final UiFormOverride option in UiFormOverride.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(option),
              child: Row(
                children: <Widget>[
                  Icon(
                    option == form.override
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: VboxTypography.s18,
                  ),
                  const SizedBox(width: VboxSpacing.md),
                  Text(option.title),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || selected == form.override) return;
    await PrefsManager.instance.set('app_ui_form_override', selected.id);
    form.setOverride(selected);
    if (mounted) VboxToast.show(context, '已切换为「${selected.title}」');
  }

  /// 书架页已按 iOS 真相源移除：iOS 设置页无「书架」入口（观看记录的唯一
  /// 入口在个人中心「历史记录」/「我的收藏」，Flutter 侧 `ProfilePage` /
  /// `HomePage` 已同款接入 `HistoryView` / `FavoritesView`）。

  void _push(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (BuildContext context) => page),
    );
  }
}
