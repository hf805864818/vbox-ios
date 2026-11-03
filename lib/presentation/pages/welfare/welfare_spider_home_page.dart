/// 表现层：福利专区专用远程 Spider 脚本状态页（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfareSpiderHomeView.swift`
///   · `headerCard`（L61-L94）：图标 46×46 圆角 14（主色 12% 底）+ 平台名
///     18 semibold + 描述 13 secondary + 四行信息（platformKey / serviceType
///     / 当前域名 / 脚本路径）；
///   · `scriptStatusCard`（L96-L120）：状态图标 + 状态标题 + 详情 + 「重新加载脚本」
///     主按钮（加载中禁用）；
///   · `statusIcon` / `statusDetail`（L122-L169）：idle→doc / loading→进度圈 /
///     loaded→绿对勾 / failed→橙三角；loaded 展示远程 URL + 本地缓存文件名；
///   · `runtimeNoticeCard`（L171-L183）：橙 10% 底 + 「运行时说明」；
///   · `previewCard`（L185-L203）：脚本预览横向滚动（monospaced 11）。
///
/// 与 iOS 的差异（如实登记）：
///   · 图标为 SF Symbol，Flutter 复用 [welfarePlatformIcon] 映射 Material 图标；
///   · iOS 在 `onAppear` 时 idle → reload，Flutter 在首帧回调触发；
///   · iOS 工具条刷新按钮置灰禁用，Flutter 用 `onPressed == null` 表达。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/welfare/welfare.dart';
import '../../../domain/services/welfare_spider_service.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'welfare_home_page.dart' show welfarePlatformIcon;

/// 福利 Spider 脚本状态页（`welfare_spider` 非 JS 平台 / 承接 JS 平台）。
class WelfareSpiderHomePage extends StatefulWidget {
  /// 构造。
  const WelfareSpiderHomePage({super.key, required this.platform});

  /// 触发路由的平台元数据。
  final WelfarePlatform platform;

  @override
  State<WelfareSpiderHomePage> createState() => _WelfareSpiderHomePageState();
}

class _WelfareSpiderHomePageState extends State<WelfareSpiderHomePage> {
  late final WelfareSpiderService _service;

  @override
  void initState() {
    super.initState();
    _service = WelfareSpiderService(platform: widget.platform);
    // 对齐 iOS `onAppear`：idle 时自动加载（有缓存则构造时已恢复 loaded）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_service.state == WelfareSpiderLoadState.idle) {
        _service.reload();
      }
    });
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  bool get _isLoading =>
      _service.state == WelfareSpiderLoadState.loading;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (BuildContext context, _) {
        return Scaffold(
          // 对齐 iOS `systemGroupedBackground` 全屏底。
          backgroundColor: _groupedBackground(context),
          appBar: AppBar(
            title: Text(widget.platform.name),
            centerTitle: true,
            actions: <Widget>[
              IconButton(
                tooltip: '重新加载脚本',
                icon: const Icon(Icons.refresh),
                onPressed: _isLoading ? null : () => _service.reload(),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(VboxSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _headerCard(context),
                const SizedBox(height: 18),
                _scriptStatusCard(context),
                const SizedBox(height: 18),
                _runtimeNoticeCard(context),
                if (_service.scriptPreview != null) ...<Widget>[
                  const SizedBox(height: 18),
                  _previewCard(context, _service.scriptPreview!),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ────────────── 头部卡片（对齐 iOS `headerCard`）──────────────

  Widget _headerCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color cardColor = _cardColor(context);
    final Color secondary = _secondary(context);
    final Color primary = theme.colorScheme.primary;
    final String api = widget.platform.api ?? '';

    return Container(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: VboxRadii.chip, // 16，对齐 iOS 卡片圆角 16
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(VboxRadii.r14),
                  ),
                ),
                child: Icon(
                  welfarePlatformIcon(widget.platform.icon),
                  size: 24,
                  color: primary,
                ),
              ),
              const SizedBox(width: VboxSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.platform.name,
                      style: const TextStyle(
                        fontSize: VboxTypography.s18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.platform.desc.isEmpty ? '（无描述）' : widget.platform.desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: VboxTypography.s13,
                        color: secondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: VboxSpacing.md),
          _infoRow('platformKey', widget.platform.platformKey, secondary),
          const SizedBox(height: VboxSpacing.sm),
          _infoRow('serviceType', widget.platform.serviceType, secondary),
          const SizedBox(height: VboxSpacing.sm),
          _infoRow('当前域名', _service.currentDomain, secondary),
          if (api.isNotEmpty) ...<Widget>[
            const SizedBox(height: VboxSpacing.sm),
            _infoRow('脚本路径', api, secondary),
          ],
        ],
      ),
    );
  }

  // ────────────── 脚本状态卡片（对齐 iOS `scriptStatusCard`）──────────────

  Widget _scriptStatusCard(BuildContext context) {
    final Color secondary = _secondary(context);

    return Container(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: VboxRadii.chip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _statusIcon(),
              const SizedBox(width: VboxSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _service.state.title,
                      style: const TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _statusDetail(context, secondary),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: VboxSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : () => _service.reload(),
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('重新加载脚本'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusIcon() {
    final ThemeData theme = Theme.of(context);
    final Widget child = switch (_service.state) {
      WelfareSpiderLoadState.idle => Icon(
          Icons.description_outlined,
          size: 22,
          color: theme.colorScheme.outline,
        ),
      WelfareSpiderLoadState.loading => const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      WelfareSpiderLoadState.loaded => const Icon(
          Icons.check_circle,
          size: 22,
          color: VboxColors.success,
        ),
      WelfareSpiderLoadState.failed => const Icon(
          Icons.warning_amber_rounded,
          size: 22,
          color: VboxColors.warning,
        ),
    };
    return SizedBox(
      width: 30,
      height: 30,
      child: Center(child: child),
    );
  }

  Widget _statusDetail(BuildContext context, Color secondary) {
    switch (_service.state) {
      case WelfareSpiderLoadState.idle:
        return _detailText('准备从福利远程源加载脚本', secondary);
      case WelfareSpiderLoadState.loading:
        return _detailText('正在下载并缓存福利专用脚本', secondary);
      case WelfareSpiderLoadState.loaded:
        final String remote =
            _service.script?.remoteURL.toString() ?? '';
        final String local =
            _service.localScriptPath ?? _service.script?.localURL ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              remote,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s11,
                fontFamily: 'monospace',
                color: secondary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '本地缓存：$local',
              style: TextStyle(fontSize: VboxTypography.s11, color: secondary),
            ),
          ],
        );
      case WelfareSpiderLoadState.failed:
        return Text(
          _service.errorMessage ?? '未知错误',
          style: const TextStyle(
              fontSize: VboxTypography.s12, color: VboxColors.warning),
        );
    }
  }

  // ────────────── 运行时说明卡片（对齐 iOS `runtimeNoticeCard`）──────────────

  Widget _runtimeNoticeCard(BuildContext context) {
    final Color secondary = _secondary(context);
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: isDark
            ? VboxColors.warning.withValues(alpha: 0.12)
            : VboxColors.warning.withValues(alpha: 0.10),
        borderRadius: VboxRadii.chip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.info_outline, size: VboxTypography.s15),
              SizedBox(width: VboxSpacing.xs),
              Text(
                '运行时说明',
                style: TextStyle(
                  fontSize: VboxTypography.s15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: VboxSpacing.sm),
          Text(
            '当前接入层已完成福利 Spider 平台识别、路由、脚本下载和缓存。'
            '项目尚未包含通用 Python 解释器，因此不会在这里强行执行 Python 脚本，'
            '避免影响现有资源蜘蛛、网盘和播放链路。',
            style: TextStyle(fontSize: VboxTypography.s13, color: secondary),
          ),
        ],
      ),
    );
  }

  // ────────────── 脚本预览卡片（对齐 iOS `previewCard`）──────────────

  Widget _previewCard(BuildContext context, String preview) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final Color codeBackground =
        isDark ? VboxColors.systemBackgroundDark : VboxColors.systemBackgroundLight;

    return Container(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: VboxRadii.chip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '脚本预览',
            style: TextStyle(
              fontSize: VboxTypography.s15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: codeBackground,
              borderRadius: VboxRadii.card, // 12，对齐 iOS 预览内圆角 12
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(VboxSpacing.md),
              child: Text(
                preview,
                style: const TextStyle(
                  fontSize: VboxTypography.s11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ────────────── 小工具 ──────────────

  Widget _infoRow(String label, String value, Color secondary) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: TextStyle(fontSize: VboxTypography.s12, color: secondary),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '未配置' : value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: VboxTypography.s12,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Widget _detailText(String text, Color secondary) => Text(
        text,
        style: TextStyle(fontSize: VboxTypography.s12, color: secondary),
      );

  Color _cardColor(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? VboxColors.secondarySystemGroupedBackgroundDark
        : VboxColors.secondarySystemGroupedBackgroundLight;
  }

  Color _groupedBackground(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? VboxColors.systemGroupedBackgroundDark
        : VboxColors.systemGroupedBackgroundLight;
  }

  Color _secondary(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? VboxColors.secondaryLabelDark
        : VboxColors.secondaryLabelLight;
  }
}
