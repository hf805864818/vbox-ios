/// 网盘账号授权中心页（批次 F · F-01，对齐 iOS UI 图 14）。
///
/// 对齐 iOS `CloudAuthCenterView`（`vbox/Views/SettingsViews.swift:1561`）：
/// 顶栏「网盘账号授权 + 完成」· Node 常驻系统状态横幅 · 12 张网盘账号卡
/// （9 普通 + 3 Node 托管）· 底部说明文案。
///
/// 数据由 [CloudDriveAuthController] 提供（读契约安全存储
/// `cloud_drive_credentials_v1`）。授权动作（扫码 / 短信 / 账号 / 网页兜底）经
/// [openCloudDriveLoginSheet] 打开对应登录 Sheet（F-02 全档），Sheet 关闭后
/// 刷新卡片态。[onAction] 非空时优先外抛（供宿主接管与测试）。
library;

import 'package:flutter/material.dart';

import '../../../data/datasources/remote/emby_config_client.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../platform/node/node_runtime_manager.dart' as node;
import '../../../platform/player/pan_player.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import 'cloud_drive_auth_controller.dart';
import 'cloud_drive_widgets.dart';
import 'emby_account_card.dart';
import 'files.dart';
import 'login_gateway.dart';
import 'login_sheet.dart';
import 'sort.dart';

/// 网盘账号授权中心页。
class CloudDriveAuthCenterPage extends StatefulWidget {
  /// 构造（[controller] / [loginGateway] / [embyClient] 供测试注入；缺省自建并自管生命周期）。
  const CloudDriveAuthCenterPage({
    super.key,
    this.controller,
    this.onAction,
    this.loginGateway,
    this.embyClient,
  });

  /// 外部注入的控制器（null → 页面自建）。
  final CloudDriveAuthController? controller;

  /// 授权动作回调（非空 → 优先外抛，不打开内置登录 Sheet）。
  final void Function(CloudDriveAccount account, String action)? onAction;

  /// 登录网关（null → 「未接入」网关；F-02 余项替换为真实实现）。
  final CloudDriveLoginGateway? loginGateway;

  /// Emby 配置客户端（null → 卡片自建 Node 客户端；测试注入 fake）。
  final EmbyConfigClient? embyClient;

  @override
  State<CloudDriveAuthCenterPage> createState() =>
      _CloudDriveAuthCenterPageState();
}

class _CloudDriveAuthCenterPageState extends State<CloudDriveAuthCenterPage> {
  late final CloudDriveAuthController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    // 接线 Node 常驻系统状态源（对齐 iOS `@ObservedObject NodeRuntimeManager.shared`），
    // 否则横幅恒为「未知」。
    _controller = widget.controller ??
        CloudDriveAuthController(
          nodeRuntimeManager: node.NodeRuntimeManager.instance,
        );
    _controller.load();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _handleAction(CloudDriveAccount account, String action) async {
    final void Function(CloudDriveAccount, String)? callback = widget.onAction;
    if (callback != null) {
      callback(account, action);
      return;
    }
    // C-盘2：Node 托管盘「分享文件」→ 分享链接解析文件列表（不走登录 Sheet）。
    if (action == '分享文件') {
      await _openShareFiles(account.type);
      return;
    }
    await openCloudDriveLoginSheet(
      context,
      type: account.type,
      action: action,
      gateway: widget.loginGateway,
    );
    // 登录 / 网页兜底保存后刷新卡片态（凭据可能已被写入安全存储）。
    await _controller.load();
  }

  /// 打开分享文件列表（C-盘2，对齐 iOS 分享 → 文件列表 → 选集播放）。
  Future<void> _openShareFiles(CloudDriveType type) async {
    final TextEditingController input = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('${type.displayName} 分享文件'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(hintText: '粘贴分享链接'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(input.text.trim()),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    input.dispose();
    if (!mounted || url == null || url.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => CloudDriveFilesPage(
          driveType: type,
          shareUrl: url,
          panPlayer: PanPlayer(),
        ),
      ),
    );
  }

  /// 保存手动粘贴的 Token / Cookie（底部兜底卡片回调）。
  Future<void> _saveManualToken(
    CloudDriveType type,
    String name,
    String value,
  ) async {
    await _controller.saveManualToken(type, name, value);
  }

  /// 删除某网盘已保存凭据（底部兜底卡片回调）。
  Future<void> _removeManualToken(CloudDriveType type) async {
    await _controller.removeCredential(type);
  }

  /// 打开网页登录兜底获取 Token（底部兜底卡片回调）。
  Future<void> _openWebFallbackForToken(CloudDriveType type) async {
    await openCloudDriveLoginSheet(
      context,
      type: type,
      action: '网页登录兜底',
      gateway: widget.loginGateway,
    );
    await _controller.load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('网盘账号授权'),
        actions: <Widget>[
          // 临时入口：网盘排序在 iOS 属「我的」页宫格（批次 I 落地），
          // 此处先以顶栏图标暴露，供 F-06 排序弹窗可达（迁移成本为零）。
          IconButton(
            tooltip: '网盘排序',
            icon: const Icon(Icons.swap_vert),
            onPressed: () => CloudDriveSortPopup.show(context),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(
              '完成',
              style: TextStyle(
                fontSize: VboxTypography.s16,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) {
          if (_controller.loading && _controller.accounts.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<CloudDriveAccount> accounts = _controller.accounts;
          return ListView(
            padding: const EdgeInsets.all(VboxSpacing.lg),
            children: <Widget>[
              VboxNodeStatusBanner(status: _controller.nodeStatus),
              for (final CloudDriveAccount account in accounts) ...<Widget>[
                const SizedBox(height: VboxSpacing.lg),
                VboxDriveAccountCard(
                  account: account,
                  onTest: () => _controller.testCredential(account.type),
                  onAction: (String action) => _handleAction(account, action),
                ),
              ],
              const SizedBox(height: VboxSpacing.lg),
              // Emby 媒体服务器配置卡（批次 C，对齐 iOS `embyAccountCard`：
              // 位于网盘账号卡之后、手动 Token 兜底卡之前）。
              EmbyAccountCard(client: widget.embyClient),
              const SizedBox(height: VboxSpacing.lg),
              // 底部「复制粘贴 Token 兜底」卡片（对齐 iOS `manualTokenFallbackCard`）。
              ManualTokenFallbackCard(
                tokens: _controller.savedTokens,
                onSave: _saveManualToken,
                onRemove: _removeManualToken,
                onFetchWeb: _openWebFallbackForToken,
              ),
              const SizedBox(height: VboxSpacing.lg),
              Text(
                '播放前不会强制检测授权状态；解析失败且像授权失效时才反向标记。手动粘贴入口继续保留为高级兜底。',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
