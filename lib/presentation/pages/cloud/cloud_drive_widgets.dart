/// 网盘授权中心共享组件（批次 F · F-01，对齐 iOS UI 图 14）。
///
/// 组件与 iOS `SettingsViews` 授权中心私有视图一一对应：
/// `nodeRuntimeStatusBanner` / `accountHeader` / `authStatusRow` /
/// `authButtonLabel` / `authDetailLine`。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'cloud_drive_auth_controller.dart';

/// 网盘列表图标（对齐 iOS `CloudDriveSortView.icon(for:)`，配色统一走
/// [VboxColors.selected] 蓝，与 iOS 排序列表蓝色图标一致）。
IconData cloudDriveIcon(CloudDriveType type) => switch (type) {
      CloudDriveType.ali => Icons.cloud_outlined,
      CloudDriveType.quark => Icons.link,
      CloudDriveType.quarkNode => Icons.square_outlined,
      CloudDriveType.baidu => Icons.link,
      CloudDriveType.baiduNode => Icons.square_outlined,
      CloudDriveType.one15 => Icons.cloud_outlined,
      CloudDriveType.uc => Icons.send,
      CloudDriveType.ucNode => Icons.square_outlined,
      CloudDriveType.pan123 => Icons.storage,
      CloudDriveType.pan139 => Icons.all_inbox,
      CloudDriveType.pan189 => Icons.cloud,
      CloudDriveType.xunlei => Icons.bolt,
      CloudDriveType.guangya => Icons.circle_outlined,
      CloudDriveType.woniu4k => Icons.circle_outlined,
      CloudDriveType.bilibili => Icons.tv,
    };

/// 各网盘授权动作按钮（标签 + 图标，逐档对齐 iOS `providerAccountCard` /
/// `nodeManagedAccountCard` 的分支文案；阿里与三张 Node 托管卡为单按钮）。
///
/// 注意：iOS 授权中心**无**「分享文件」按钮 —— 网盘分享解析入口在播放器
/// （打开网盘链接时展开选集）。Flutter 侧对应入口见
/// `PushPlayDetailPage`（E-12 收敛），故此处不再追加该动作。
List<(String, IconData)> cloudDriveAuthActions(CloudDriveType type) {
  return switch (type) {
      // 阿里：对齐 iOS `providerAccountCard` ali 分支「原生扫码」
      // （OpenList 授权页扫码，`CloudDriveAuthManager.swift:2244`）；
      // PG 扫码在 iOS 已隐藏（`AliyunPgQrLoginView` 无实例化点），不暴露。
      CloudDriveType.ali => <(String, IconData)>[
          ('原生扫码', Icons.qr_code_2),
        ],
      // 原生盘：对齐 iOS `providerAccountCard`（`SettingsViews.swift:1997-2061`）
      // —— uc / 百度 / 夸克卡片均为 **2 项**（原生扫码 + 网页兜底）；「Node 档」
      // 藏在原生扫码 Sheet 内的 Segmented 切换（`SettingsViews.swift:4415-4427`），
      // 不在卡片上重复暴露（问题 11）。
      CloudDriveType.uc => <(String, IconData)>[
          ('原生扫码', Icons.qr_code_2),
          ('网页登录兜底', Icons.language),
        ],
      CloudDriveType.baidu => <(String, IconData)>[
          ('扫码授权', Icons.qr_code_2),
          ('网页兜底', Icons.language),
        ],
      CloudDriveType.quark => <(String, IconData)>[
          ('扫码登录', Icons.qr_code_2),
          ('网页登录兜底', Icons.language),
        ],
      // Node 托管派生卡：动作须落到 Node 模式（F-P16）。
      CloudDriveType.ucNode ||
      CloudDriveType.baiduNode ||
      CloudDriveType.quarkNode ||
      CloudDriveType.one15 =>
        <(String, IconData)>[
          ('Node扫码登录', Icons.phone_iphone),
          ('网页兜底', Icons.language),
        ],
      // pan123：对齐 iOS「Node账号登录」（`NodePan123LoginView`）+「网页兜底」。
      CloudDriveType.pan123 => <(String, IconData)>[
          ('Node账号登录', Icons.phone_iphone),
          ('网页兜底', Icons.language),
        ],
      // pan189（P2-1）：+「原生扫码」三段链（对齐 iOS `NativeCloudQRLoginView(.pan189)`
      // 承载的原生 API `pan189CreateQrToken` / `pan189PollQrStatus` /
      // `pan189ExchangeCookie`，`CloudDriveAuthManager.swift:455-603`；iOS 卡片
      // 入口文案为「网页兜底」、主走 WebView 自动化，Flutter 无内嵌 WebView
      // 自动化栈，以三段扫码链补位为等效登录方式）。「Node账号登录」对齐
      // iOS 内部实现 `NodePan189AccountLoginView`（账号密码 + 可选短信；
      // iOS 按钮文案「Node验证码登录」与其内部实现不一致，此处按实现语义命名）。
      CloudDriveType.pan189 => <(String, IconData)>[
          ('原生扫码', Icons.qr_code_2),
          ('Node账号登录', Icons.phone_iphone),
          ('网页兜底', Icons.language),
        ],
      CloudDriveType.pan139 || CloudDriveType.xunlei => <(String, IconData)>[
          ('Node验证码登录', Icons.phone_iphone),
          ('网页兜底', Icons.language),
        ],
      CloudDriveType.guangya => <(String, IconData)>[
          ('手机验证码登录', Icons.phone_iphone),
        ],
      CloudDriveType.woniu4k => <(String, IconData)>[
          ('账号登录', Icons.person_outline),
        ],
      CloudDriveType.bilibili => <(String, IconData)>[
          ('原生扫码', Icons.qr_code_2),
        ],
    };
}

/// 网盘品牌角标底色（未登记回退分类色板的云盘蓝）。
Color cloudDriveBrandColor(CloudDriveType type) =>
    VboxColors.cloudDriveBrandColors[type.id] ??
    VboxColors.categoryColors[VboxCategory.cloud]!;

/// 品牌角标字母（对齐 iOS 图标语义的极简字形）。
const Map<CloudDriveType, String> _brandLetters = <CloudDriveType, String>{
  CloudDriveType.ali: 'A',
  CloudDriveType.quark: 'Q',
  CloudDriveType.quarkNode: 'Q',
  CloudDriveType.baidu: 'B',
  CloudDriveType.baiduNode: 'B',
  CloudDriveType.one15: '1',
  CloudDriveType.uc: 'U',
  CloudDriveType.ucNode: 'U',
  CloudDriveType.pan123: '1',
  CloudDriveType.pan139: '1',
  CloudDriveType.pan189: 'T',
  CloudDriveType.xunlei: 'X',
  CloudDriveType.guangya: 'G',
  CloudDriveType.woniu4k: 'W',
  CloudDriveType.bilibili: 'B',
};

/// 网盘品牌圆形角标（授权中心 / 排序列表共用）。
class VboxDriveLogo extends StatelessWidget {
  /// 构造。
  const VboxDriveLogo({super.key, required this.type, this.size = 28});

  /// 网盘类型。
  final CloudDriveType type;

  /// 边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cloudDriveBrandColor(type),
        shape: BoxShape.circle,
      ),
      child: Text(
        _brandLetters[type] ?? '?',
        style: TextStyle(
          fontSize: size >= 32 ? VboxTypography.s16 : VboxTypography.s13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Node 常驻系统状态横幅（对齐 iOS `nodeRuntimeStatusBanner`）。
class VboxNodeStatusBanner extends StatelessWidget {
  /// 构造。
  const VboxNodeStatusBanner({super.key, required this.status});

  /// 状态快照。
  final NodeRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = _nodeStatusColor(scheme, status.state);
    return Container(
      padding: const EdgeInsets.all(VboxSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: VboxRadii.card,
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 26,
            child: Icon(
              _nodeStatusIcon(status.state),
              size: VboxTypography.s16,
              color: color,
            ),
          ),
          const SizedBox(width: VboxSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'Node 常驻系统',
                      style: TextStyle(
                        fontSize: VboxTypography.s14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: VboxSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(VboxRadii.r6),
                      ),
                      child: Text(
                        status.state.displayText,
                        style: TextStyle(
                          fontSize: VboxTypography.s11,
                          fontWeight: FontWeight.w500,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  status.detailText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: scheme.onSurfaceVariant,
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

/// 网盘账户卡（对齐 iOS `accountHeader` + `authStatusRow` + `authDetailLine`）。
class VboxDriveAccountCard extends StatelessWidget {
  /// 构造。
  const VboxDriveAccountCard({
    super.key,
    required this.account,
    this.onTest,
    this.onAction,
  });

  /// 账户视图模型。
  final CloudDriveAccount account;

  /// 「测试」回调。
  final VoidCallback? onTest;

  /// 登录动作回调（动作名见 [actions]）。
  final void Function(String action)? onAction;

  /// 登录动作（逐档对齐 iOS，见 [cloudDriveAuthActions]）。
  List<(String, IconData)> get actions => cloudDriveAuthActions(account.type);

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color statusColor =
        account.statusReady ? VboxColors.success : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: VboxRadii.chip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 14,
        children: <Widget>[
          _header(scheme),
          if (account.hasCookieRow)
            _cookieRow(scheme, statusColor),
          if (account.description != null)
            Text(
              account.description!,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          Row(
            spacing: 10,
            children: <Widget>[
              for (final (String, IconData) action in actions)
                Expanded(
                  child: _actionButton(
                    context,
                    scheme,
                    label: action.$1,
                    icon: action.$2,
                  ),
                ),
            ],
          ),
          _detailLine(scheme, statusColor),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Row(
      spacing: VboxSpacing.md,
      children: <Widget>[
        VboxDriveLogo(type: account.type, size: 36),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                account.type.displayName,
                style: TextStyle(
                  fontSize: VboxTypography.s16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                account.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _badge(
          text: account.authorized ? '已获取' : '未获取',
          color: account.authorized ? VboxColors.success : scheme.onSurfaceVariant,
        ),
      ],
    );
  }

  Widget _cookieRow(ColorScheme scheme, Color statusColor) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Row(
        children: <Widget>[
          Text(
            account.cookieLabel!,
            style: TextStyle(
              fontSize: VboxTypography.s13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          Icon(
            account.cookieReady ? Icons.check_circle : Icons.error_outline,
            size: VboxTypography.s13,
            color: account.cookieReady ? VboxColors.success : VboxColors.warning,
          ),
          const SizedBox(width: VboxSpacing.xs),
          Text(
            account.cookieStatusText,
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: account.cookieReady ? VboxColors.success : VboxColors.warning,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    BuildContext context,
    ColorScheme scheme, {
    required String label,
    required IconData icon,
  }) {
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(VboxRadii.r10),
      child: InkWell(
        onTap: onAction == null ? null : () => onAction!(label),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: VboxTypography.s14, color: scheme.onPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: VboxTypography.s13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailLine(ColorScheme scheme, Color statusColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              account.detailFallback,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            account.statusText,
            style: TextStyle(
              fontSize: VboxTypography.s12,
              fontWeight: FontWeight.w500,
              color: statusColor,
            ),
          ),
          const SizedBox(width: VboxSpacing.sm),
          TextButton(
            key: ValueKey<String>(CloudDriveAccount.actionKey(account.type)),
            onPressed: onTest,
            style: TextButton.styleFrom(
              backgroundColor: scheme.primary.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(VboxRadii.r8),
              ),
            ),
            child: Text(
              '测试',
              style: TextStyle(
                fontSize: VboxTypography.s11,
                fontWeight: FontWeight.w500,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge({required String text, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(VboxRadii.r8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: VboxTypography.s12,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

Color _nodeStatusColor(ColorScheme scheme, NodeRuntimeState state) {
  if (state.isReady) return VboxColors.success;
  if (state == NodeRuntimeState.memoryWarning ||
      state == NodeRuntimeState.starting) {
    return VboxColors.warning;
  }
  if (state.isError) return scheme.error;
  return scheme.onSurfaceVariant;
}

IconData _nodeStatusIcon(NodeRuntimeState state) {
  if (state.isReady) return Icons.check_circle;
  if (state == NodeRuntimeState.memoryWarning) {
    return Icons.warning_amber_rounded;
  }
  if (state.isError) return Icons.error;
  if (state == NodeRuntimeState.starting) return Icons.hourglass_bottom;
  if (state == NodeRuntimeState.stopped) return Icons.power_settings_new;
  return Icons.help_outline;
}

/// 底部「复制粘贴 Token 兜底」卡片（对齐 iOS `manualTokenFallbackCard`）。
///
/// 结构（自上而下）：标题行（钥匙图标 + 「复制粘贴 Token 兜底」+ 副标题）→
/// 已保存 Token 列表（空态「暂无已保存 Token」，最高 170）→「网页登录获取
/// Token（兜底）」主按钮 → 网盘类型下拉 + 备注名 + 凭据输入 +「保存 Token」
/// 按钮。凭据读写经 [onSave] / [onRemove] / [onFetchWeb] 回调外部落库。
class ManualTokenFallbackCard extends StatefulWidget {
  /// 构造。
  const ManualTokenFallbackCard({
    super.key,
    required this.tokens,
    required this.onSave,
    required this.onRemove,
    required this.onFetchWeb,
  });

  /// 已保存凭据清单（[CloudDriveAuthController.savedTokens]）。
  final List<CloudDriveCredential> tokens;

  /// 保存手动粘贴的 Token / Cookie。
  final Future<void> Function(CloudDriveType type, String name, String value)
      onSave;

  /// 删除指定网盘凭据（对齐 iOS `removeToken(at:)`）。
  final Future<void> Function(CloudDriveType type) onRemove;

  /// 打开网页登录兜底获取 Token（对齐 iOS `showTokenFetcher`）。
  final Future<void> Function(CloudDriveType type) onFetchWeb;

  @override
  State<ManualTokenFallbackCard> createState() =>
      _ManualTokenFallbackCardState();
}

class _ManualTokenFallbackCardState extends State<ManualTokenFallbackCard> {
  CloudDriveType _selected = CloudDriveType.ali;
  final TextEditingController _name = TextEditingController();
  final TextEditingController _value = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _value.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    await widget.onSave(_selected, _name.text.trim(), _value.text.trim());
    if (!mounted) return;
    setState(() {
      _name.clear();
      _value.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const Color accent = VboxColors.skinPrimaryRose;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(VboxRadii.r14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 26,
                child: Icon(Icons.key, size: VboxTypography.s18, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '复制粘贴 Token 兜底',
                      style: TextStyle(
                        fontSize: VboxTypography.s15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '用于查看、网页登录获取、手动粘贴各网盘 Token',
                      style: TextStyle(
                        fontSize: VboxTypography.s12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: VboxSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 170),
            child: widget.tokens.isEmpty
                ? _emptyHint(scheme)
                : ListView.separated(
                    shrinkWrap: true,
                    primary: false,
                    padding: EdgeInsets.zero,
                    itemCount: widget.tokens.length,
                    separatorBuilder: (BuildContext _, int __) =>
                        const SizedBox(height: VboxSpacing.sm),
                    itemBuilder: (BuildContext _, int index) =>
                        _tokenRow(scheme, widget.tokens[index]),
                  ),
          ),
          const SizedBox(height: VboxSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => widget.onFetchWeb(_selected),
              icon: const Icon(Icons.public, size: VboxTypography.s16),
              label: const Text(
                '网页登录获取 Token（兜底）',
                style: TextStyle(fontSize: VboxTypography.s14),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(VboxRadii.r12),
                ),
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: '网盘类型',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<CloudDriveType>(
                value: _selected,
                isExpanded: true,
                isDense: true,
                items: <DropdownMenuItem<CloudDriveType>>[
                  for (final CloudDriveType type in CloudDriveType.values)
                    DropdownMenuItem<CloudDriveType>(
                      value: type,
                      child: Text(
                        type.displayName,
                        style: TextStyle(
                          fontSize: VboxTypography.s13,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                ],
                onChanged: (CloudDriveType? type) {
                  if (type != null) setState(() => _selected = type);
                },
              ),
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          TextField(
            controller: _name,
            onChanged: (String _) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '备注名称',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: TextStyle(
              fontSize: VboxTypography.s13,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.sm),
          TextField(
            controller: _value,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (String _) => setState(() {}),
            decoration: InputDecoration(
              hintText: _selected.tokenLabel,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: VboxSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _canSave ? _save : null,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    scheme.onSurfaceVariant.withValues(alpha: 0.3),
                minimumSize: const Size.fromHeight(42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(VboxRadii.r10),
                ),
              ),
              child: const Text(
                '保存 Token',
                style: TextStyle(
                  fontSize: VboxTypography.s14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Text(
        '暂无已保存 Token',
        style: TextStyle(
          fontSize: VboxTypography.s12,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _tokenRow(ColorScheme scheme, CloudDriveCredential token) {
    final CloudDriveType? type = token.type;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 24,
            child: Icon(
              type != null ? cloudDriveIcon(type) : Icons.cloud,
              size: VboxTypography.s16,
              color: VboxColors.skinPrimaryRose,
            ),
          ),
          const SizedBox(width: VboxSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  type?.displayName ?? token.driveType,
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  token.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(
              Icons.delete_outline,
              size: VboxTypography.s16,
              color: VboxColors.danger,
            ),
            onPressed: type == null ? null : () => widget.onRemove(type),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
