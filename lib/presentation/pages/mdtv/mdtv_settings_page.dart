/// 麻豆平台（MDTV）设置页 + 域名设置页（批次 E · E-05）。
///
/// 对齐 iOS `MDTVSettingsView` / `MDTVDomainSettingsView`：密钥状态、
/// 重置密钥 / 重置 Tab、首页 Tab 展示、API 域名入口、技术信息。
library;

import 'package:flutter/material.dart';

import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'mdtv_controller.dart';

/// 麻豆平台设置页。
class MdtvSettingsPage extends StatefulWidget {
  /// 构造。
  const MdtvSettingsPage({super.key, required this.controller});

  /// 控制器。
  final MdtvController controller;

  @override
  State<MdtvSettingsPage> createState() => _MdtvSettingsPageState();
}

class _MdtvSettingsPageState extends State<MdtvSettingsPage> {
  MdtvController get _controller => widget.controller;

  Future<void> _confirmResetKey() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('重置密钥配置'),
        content: const Text('重置后系统将重新自动探测正确的加密密钥和模式，确定要继续吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定重置'),
          ),
        ],
      ),
    );
    if (ok == true) await _controller.resetKeyConfig();
  }

  Future<void> _resetTabs() async {
    await _controller.resetTabs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已重置首页 Tab')),
      );
    }
  }

  void _openDomainSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          MdtvDomainSettingsPage(controller: _controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('麻豆平台设置')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) {
          final bool keyFound = _controller.isKeyFound;
          return ListView(
            children: <Widget>[
              _header(scheme, '加密配置'),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('密钥状态'),
                trailing: keyFound
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.check_circle, size: VboxTypography.s18, color: scheme.primary),
                          const SizedBox(width: VboxSpacing.xs),
                          const Text('已匹配'),
                        ],
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.search, size: VboxTypography.s18, color: Colors.orange),
                          SizedBox(width: VboxSpacing.xs),
                          Text('探测中'),
                        ],
                      ),
              ),
              ListTile(
                leading: Icon(Icons.restart_alt, color: scheme.error),
                title: Text('重置密钥配置', style: TextStyle(color: scheme.error)),
                onTap: _confirmResetKey,
              ),
              ListTile(
                leading: Icon(Icons.restart_alt, color: scheme.error),
                title: Text('重置 Tab 配置', style: TextStyle(color: scheme.error)),
                onTap: _resetTabs,
              ),
              _footer(scheme, '如果视频加载异常，可以尝试重置密钥，让系统重新自动探测正确的加密配置。'),
              _header(scheme, '首页 Tab'),
              ListTile(
                leading: const Icon(Icons.tab_outlined),
                title: const Text('当前 Tab'),
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    _controller.homeTabs.join(' / '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              _footer(scheme, 'Tab 列表支持本地默认 + 远程热更新。服务端更新 Tab 后，下次进入页面会自动同步。'),
              _header(scheme, '网络配置'),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('API 域名'),
                trailing: Text(
                  _controller.baseUrl.replaceFirst('https://', ''),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                onTap: _openDomainSettings,
              ),
              _header(scheme, '技术信息'),
              const _TechInfo(),
            ],
          );
        },
      ),
    );
  }

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
}

/// 技术信息（只读展示）。
class _TechInfo extends StatelessWidget {
  const _TechInfo();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const List<String> lines = <String>[
      '平台标识: JGDZMX',
      '加密算法: AES (模式自动探测)',
      '候选密钥: 动态生成 (含 hex + UTF-8 + MD5/SHA1)',
      '候选模式: CBC / CFB / CTR / OFB / ECB',
    ];
    return Padding(
      padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
              child: Text(
                line,
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: VboxSpacing.xxl),
        ],
      ),
    );
  }
}

/// API 域名设置页。
class MdtvDomainSettingsPage extends StatefulWidget {
  /// 构造。
  const MdtvDomainSettingsPage({super.key, required this.controller});

  /// 控制器。
  final MdtvController controller;

  @override
  State<MdtvDomainSettingsPage> createState() => _MdtvDomainSettingsPageState();
}

class _MdtvDomainSettingsPageState extends State<MdtvDomainSettingsPage> {
  /// 预设域名（对齐 iOS `presetDomains`）。
  static const List<String> presetDomains = <String>[
    'https://api.nzp1ve.com',
    'https://api.em1oifd0.com',
    'https://api.3459381.com',
    'https://api.c6dd5cc.com',
    'https://api.j7y675.com',
    'https://api.61c76a0.com',
    'https://api.87735d5.com',
    'https://api.b7f3192.com',
    'https://api.c9wgdr.com',
    'https://api.he0jys.com',
  ];

  final TextEditingController _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String current = widget.controller.baseUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('API 域名')),
      body: ListView(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                VboxSpacing.lg, VboxSpacing.xl, VboxSpacing.lg, VboxSpacing.sm),
            child: Text(
              '自定义 API 域名',
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          Padding(
            padding: VboxSpacing.symmetric(horizontal: VboxSpacing.lg),
            child: TextField(
              controller: _custom,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: '自定义域名',
                helperText: '输入完整域名，如 https://api.example.com',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                VboxSpacing.lg, VboxSpacing.xl, VboxSpacing.lg, VboxSpacing.sm),
            child: Text(
              '预设域名',
              style: TextStyle(
                fontSize: VboxTypography.s13,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          for (final String domain in presetDomains)
            ListTile(
              title: Text(domain.replaceFirst('https://', '')),
              trailing: current == domain
                  ? Icon(Icons.check, color: scheme.primary)
                  : null,
              onTap: () {
                _custom.text = domain.replaceFirst('https://', '');
              },
            ),
          const SizedBox(height: VboxSpacing.xxl),
        ],
      ),
    );
  }
}