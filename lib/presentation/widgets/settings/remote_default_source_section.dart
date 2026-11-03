/// 「启用远程默认源」内联设置区块（批次 G-09）。
///
/// 对齐 iOS `SettingsViews.subscriptionSection` 的远程默认源内联编辑区——
/// iOS 无需进入子页即可在设置页直接查看与设置，Flutter 侧同款内联；
/// 仅在设置页（`_subscribeSection`）提供（原「远程源」页顶部同款区块
/// 已随入口收敛移除，对齐 iOS 唯一入口）。
/// 区块内容：
///   · 「启用远程默认源」开关（`remote_default_source_enabled`）+
///     装载状态副标题（`LoadState.displayText`）；
///   · 「默认源地址」输入框（`remote_default_manifest_url`）；
///   · 「刷新远程源」（强制拉取，同步中禁用）/「清缓存」（destructive 红）；
///   · 「配置版本：X · 同步时间：Y」状态行（`yyyy-MM-dd HH:mm`，无则「无」）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/result.dart';
import '../../../core/utils/time_utils.dart';
import '../../../domain/entities/remote_source/remote_source.dart';
import '../../../domain/usecases/usecases.dart';
import '../../theme/tokens/colors.dart';

/// 远程默认源内联设置区块。
class RemoteDefaultSourceSection extends StatefulWidget {
  /// 构造。
  const RemoteDefaultSourceSection({super.key});

  @override
  State<RemoteDefaultSourceSection> createState() =>
      _RemoteDefaultSourceSectionState();
}

class _RemoteDefaultSourceSectionState
    extends State<RemoteDefaultSourceSection> {
  late final RemoteSourceUseCases _remote;

  RemoteLoadStatus _status = const RemoteLoadStatus.idle();
  bool _refreshing = false;

  /// 远程源设置（开关 / manifest 地址 / 上次版本 / 上次同步时间）。
  RemoteSourceSettings _settings = const RemoteSourceSettings.defaults();

  /// manifest 地址输入控制器。
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _remote = context.read<RemoteSourceUseCases>();
    _loadSettings();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final RemoteLoadStatus status = await _remote.status();
    if (!mounted) return;
    setState(() => _status = status);
    await _reloadSettingsOnly();
  }

  /// 仅重读设置四键（版本 / 同步时间 / 开关 / 地址），**不覆盖装载状态**——
  /// 供刷新 / 清缓存后调用：`_refresh` 刚写入的 loadedRemote / failed 状态
  /// 是最新事实，若经 `status()` 读回会被仓储的旧状态覆盖（回归修复）。
  Future<void> _reloadSettingsOnly() async {
    final Result<RemoteSourceSettings> result = await _remote.settings();
    if (!mounted) return;
    final RemoteSourceSettings s =
        result.valueOrNull ?? const RemoteSourceSettings.defaults();
    setState(() {
      _settings = s;
      if (_urlController.text != s.manifestUrl) {
        _urlController.text = s.manifestUrl;
      }
    });
  }

  /// 切换「启用远程默认源」开关（`remote_default_source_enabled`）。
  Future<void> _setEnabled(bool value) async {
    setState(() => _settings = _settings.copyWith(enabled: value));
    await _remote.setEnabled(value);
  }

  /// 保存 manifest 地址（`remote_default_manifest_url`）。
  Future<void> _saveManifestUrl(String value) async {
    final String url = value.trim();
    await _remote.setManifestUrl(url);
    if (!mounted) return;
    setState(() => _settings = _settings.copyWith(manifestUrl: url));
  }

  /// 强制刷新远程清单（对齐 iOS `SettingsViews` 刷新按钮：无视 TTL 立即拉取）。
  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    final Result<RemoteManifest> result =
        await _remote.refresh(forceRefresh: true);
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      final dynamic failure = result.failureOrNull;
      _status = failure != null
          ? RemoteLoadStatus.failed('$failure')
          : RemoteLoadStatus.loadedRemote(result.valueOrNull!.configVersion);
    });
    await _reloadSettingsOnly();
  }

  /// 清空远程源缓存（清单文件 + 版本/时间/错误镜像键）。
  Future<void> _clearCache() async {
    await _remote.clearCache();
    if (!mounted) return;
    setState(() => _status = const RemoteLoadStatus.idle());
    await _reloadSettingsOnly();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清空远程源缓存')),
    );
  }

  /// 上次同步时间展示文本（对齐 iOS `remoteSyncTimeText`）。
  String get _syncTimeText => _settings.lastSyncTimeSeconds <= 0
      ? '无'
      : TimeUtils.formatUnixSeconds(
          _settings.lastSyncTimeSeconds,
          pattern: 'yyyy-MM-dd HH:mm',
        );

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool enabled = _settings.enabled;
    final bool canRefresh = enabled && !_refreshing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.cloud,
              size: 20,
              color: VboxColors.remoteSourceAccent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '启用远程默认源',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _status.displayText,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(value: enabled, onChanged: _setEnabled),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '默认源地址',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'manifest.json 地址',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: _saveManifestUrl,
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canRefresh ? _refresh : null,
                icon: _refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(_refreshing ? '同步中' : '刷新远程源'),
              ),
            ),
            const SizedBox(width: 10),
            // 清缓存（对齐 iOS `role: .destructive` 红色）。
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _clearCache,
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                ),
                icon: const Icon(Icons.delete, size: 18),
                label: const Text('清缓存'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '配置版本：${_settings.lastConfigVersion.isEmpty ? '无' : _settings.lastConfigVersion}'
          ' · 同步时间：$_syncTimeText',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
