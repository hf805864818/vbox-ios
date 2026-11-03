/// One 平台（YBox）设置页（批次 G · G-05）。
///
/// 对齐 iOS `OneSettingsView`：设备注册（游客模式：状态 / token / user-key /
/// 重新注册）+ 手动配置（token / user-key 覆盖 + 保存）+ 设备信息（UUID）
/// + 加密参数 + 配置状态。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'one_platform_controller.dart';

/// One 平台设置页。
class OnePlatformSettingsPage extends StatefulWidget {
  /// 构造。
  const OnePlatformSettingsPage({super.key, required this.controller});

  /// 控制器。
  final OnePlatformController controller;

  @override
  State<OnePlatformSettingsPage> createState() =>
      _OnePlatformSettingsPageState();
}

class _OnePlatformSettingsPageState extends State<OnePlatformSettingsPage> {
  final TextEditingController _tokenInput = TextEditingController();
  final TextEditingController _userKeyInput = TextEditingController();
  bool _refreshing = false;

  OnePlatformController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _tokenInput.text = _controller.token;
    _userKeyInput.text = _controller.userKey;
  }

  @override
  void dispose() {
    _tokenInput.dispose();
    _userKeyInput.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    setState(() => _refreshing = true);
    await _controller.registerDevice();
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  Future<void> _save() async {
    await _controller.saveToken(
      token: _tokenInput.text,
      userKey: _userKeyInput.text,
      uuid: _controller.uuid,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('One 平台配置已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('One 平台设置')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) {
          final bool registered = _controller.isRegistered;
          final bool manualDirty = _tokenInput.text.isNotEmpty ||
              _userKeyInput.text.isNotEmpty;
          return ListView(
            children: <Widget>[
              _header(scheme, '设备注册（游客模式）'),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('注册状态'),
                trailing: registered
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.check_circle,
                              size: VboxTypography.s18, color: scheme.primary),
                          const SizedBox(width: VboxSpacing.xs),
                          const Text('已注册'),
                        ],
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.error_outline,
                              size: VboxTypography.s18, color: Colors.orange),
                          SizedBox(width: VboxSpacing.xs),
                          Text('未注册'),
                        ],
                      ),
              ),
              if (registered) ...<Widget>[
                _valueTile(
                  scheme,
                  icon: Icons.vpn_key_outlined,
                  label: 'Token',
                  value: _prefix(_controller.token, 20),
                ),
                _valueTile(
                  scheme,
                  icon: Icons.badge_outlined,
                  label: 'user-key',
                  value: _prefix(_controller.userKey, 16),
                ),
              ],
              ListTile(
                leading: Icon(Icons.refresh, color: scheme.primary),
                title: Text(
                  registered ? '重新注册' : '立即注册',
                  style: TextStyle(color: scheme.primary),
                ),
                trailing: _refreshing
                    ? const SizedBox(
                        width: VboxTypography.s18,
                        height: VboxTypography.s18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _refreshing ? null : _register,
              ),
              _footer(scheme, '首次进入自动注册游客账号，无需手动配置'),
              _header(scheme, '手动配置'),
              Padding(
                padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: _tokenInput,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLines: null,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'JWT Token（可选，手动覆盖）',
                      ),
                    ),
                    const SizedBox(height: VboxSpacing.md),
                    TextField(
                      controller: _userKeyInput,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'user-key（可选，手动覆盖）',
                      ),
                    ),
                  ],
                ),
              ),
              _footer(scheme, '如自动注册失败，可从 ybox 中提取 token 和 user-key 手动填入'),
              if (manualDirty) ...<Widget>[
                const SizedBox(height: VboxSpacing.md),
                Padding(
                  padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('保存手动配置'),
                    ),
                  ),
                ),
              ],
              _header(scheme, '设备信息（自动生成）'),
              _valueTile(
                scheme,
                icon: Icons.smartphone_outlined,
                label: '设备 UUID',
                value: _controller.uuid,
              ),
              _footer(scheme, 'UUID 首次启动自动生成并永久保存，无需手动填写'),
              _header(scheme, '加密参数'),
              _valueTile(scheme, label: 'AES 算法', value: 'AES-128-CBC'),
              _valueTile(scheme, label: 'AES Key', value: '0f48a4e7...'),
              _valueTile(scheme, label: '填充方式', value: 'PKCS7Padding'),
              _valueTile(
                scheme,
                label: 'API 域名',
                value: _controller.baseUrl.replaceFirst('https://', ''),
              ),
              _header(scheme, '状态'),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('配置状态'),
                trailing: _controller.isConfigured
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.check_circle,
                              size: VboxTypography.s18, color: scheme.primary),
                          const SizedBox(width: VboxSpacing.xs),
                          const Text('已配置'),
                        ],
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.warning_amber_rounded,
                              size: VboxTypography.s18, color: Colors.orange),
                          SizedBox(width: VboxSpacing.xs),
                          Text('未配置'),
                        ],
                      ),
              ),
              const SizedBox(height: VboxSpacing.xxl),
            ],
          );
        },
      ),
    );
  }

  static String _prefix(String value, int len) =>
      value.length <= len ? value : '${value.substring(0, len)}...';

  Widget _header(ColorScheme scheme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(
            VboxSpacing.lg, VboxSpacing.xl, VboxSpacing.lg, VboxSpacing.sm),
        child: Text(
          title,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      );

  Widget _footer(ColorScheme scheme, String text) => Padding(
        padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
        child: Text(
          text,
          style: TextStyle(
            fontSize: VboxTypography.s12,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );

  Widget _valueTile(
    ColorScheme scheme, {
    IconData? icon,
    required String label,
    required String value,
  }) =>
      ListTile(
        leading: icon == null ? null : Icon(icon),
        title: Text(label),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(
            value.isEmpty ? '—' : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
}