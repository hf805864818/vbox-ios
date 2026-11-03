/// 网盘登录 Sheet（批次 F · F-02，对齐 iOS 登录视图）。
///
/// 两种形态：
/// - **扫码类**（原生扫码 / Node 扫码 / PG 扫码）对齐 iOS
///   `NativeCloudQRLoginView`（`SettingsViews.swift:4391`）与 `BiliQrLoginView`：
///   标题（18 semibold）+ 220×220 二维码卡 + 状态卡 + 提示卡 + 主按钮。
/// - **短信类**（Node 验证码）对齐 iOS `NodeGuangyaSMSLoginView`
///   （`NodeLoginViews.swift:123`）：手机号 + 获取验证码（60s 倒计时）+
///   验证码输入 + 状态卡 + 主按钮。
///
/// 协议调用经 [CloudDriveLoginGateway]：缺省按网盘 / 方式路由
/// （[defaultCloudDriveLoginGateway]，F-05 起 B 站扫码走 Node 常驻系统），
/// 未接线档回退「未接入」网关，页面即时报「Node 常驻系统未就绪 /
/// 原生登录链路尚未接入」，与 iOS 未就绪行为一致。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/datasources/local/cloud_drive_credential_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/cloud/cloud_drive_login.dart';
import '../../../platform/webview/in_app_webview_bridge.dart';
import '../../../platform/webview/webview_bridge.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/vbox/vbox.dart';
import 'aliyun_oplist_login_sheet.dart';
import 'cloud_drive_widgets.dart';
import 'login_controller.dart';
import 'login_gateway.dart';
import 'native_cloud_drive_login_gateway.dart';
import 'node_login_gateway.dart';

/// 授权中心动作 → 打开对应登录 Sheet。
///
/// 网页兜底（F-02 余项）走 [CloudDriveWebLoginSheet]：拉起系统浏览器打开官方
/// 登录页 + 粘贴 Token / Cookie 落安全存储。
Future<void> openCloudDriveLoginSheet(
  BuildContext context, {
  required CloudDriveType type,
  required String action,
  CloudDriveLoginGateway? gateway,
  CloudDriveWebCredentialSaver? webSaver,
  WebViewBridge? webViewBridge,
}) async {
  CloudDriveLoginMode mode = CloudDriveLoginMode.fromActionLabel(action);
  // P1-A：原生盘的「Node扫码登录」→ Node 派生类型（对齐 iOS 卡内 Segmented
  // 的 Node 档：百度 `NodeScanQRLoginView(provider:"baidu")`、夸克
  // `provider:"quark"`、UC `NodeUcTwoStepLoginView`；登录态写 Node 常驻系统，
  // 与本地原生凭据互不影响）。ucNode 命中下方两步扫码特判。
  if (action == 'Node扫码登录') {
    type = switch (type) {
      CloudDriveType.baidu => CloudDriveType.baiduNode,
      CloudDriveType.quark => CloudDriveType.quarkNode,
      CloudDriveType.uc => CloudDriveType.ucNode,
      _ => type,
    };
  }
  final ColorScheme scheme = Theme.of(context).colorScheme;
  // P1-B：UC 原生扫码成功 → sheet 关闭后 0.5s 自动弹 TV 授权
  // （对齐 iOS `onChange(of: showUCNativeQR)` + `asyncAfter 0.5` → `UCTVAuthQRView`）。
  if (type == CloudDriveType.uc && mode == CloudDriveLoginMode.nativeQr) {
    bool justCompleted = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: VboxRadii.panel),
      builder: (BuildContext _) {
        return CloudDriveQrLoginSheet(
          driveType: type,
          mode: mode,
          gateway: gateway,
          onLoginCompleted: () => justCompleted = true,
        );
      },
    );
    if (!justCompleted) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!context.mounted) return;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: VboxRadii.panel),
      builder: (BuildContext _) => CloudDriveUcTvAuthSheet(
        gateway: gateway is NativeCloudDriveLoginGateway ? gateway : null,
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: VboxRadii.panel),
    builder: (BuildContext _) {
      // 阿里原生扫码 = OpenList 授权页（对齐 iOS `NativeCloudQRLoginView(.ali)`
      // 内嵌 `AliOpenListQrLoginHelper`：WebView 扫码 → JS 提取 refresh_token）。
      if (type == CloudDriveType.ali &&
          mode == CloudDriveLoginMode.nativeQr) {
        return const AliyunOpenListLoginSheet();
      }
      // UCNode 两步扫码（对齐 iOS `NodeUcTwoStepLoginView`：Cookie → TV Token）。
      if (type == CloudDriveType.ucNode && mode == CloudDriveLoginMode.nodeQr) {
        return CloudDriveUcTwoStepQrSheet(
          driveType: type,
          gateway: gateway,
        );
      }
      return switch (mode) {
        CloudDriveLoginMode.webFallback => CloudDriveWebLoginSheet(
            driveType: type,
            saver: webSaver,
            // Web-R1：支持平台默认启用内嵌 WebView（不支持平台回退浏览器 + 粘贴）。
            bridge: webViewBridge ?? InAppWebViewBridge(),
          ),
        CloudDriveLoginMode.nodeSms => CloudDriveSmsLoginSheet(
            driveType: type,
            mode: mode,
            gateway: gateway,
            // Web-R3：支持平台内嵌滑块验证页（139）；不支持平台不展示滑块面板。
            bridge: webViewBridge ?? InAppWebViewBridge(),
          ),
        CloudDriveLoginMode.nodeAccount => CloudDriveAccountLoginSheet(
            driveType: type,
            mode: mode,
            gateway: gateway,
          ),
        _ => CloudDriveQrLoginSheet(
            driveType: type,
            mode: mode,
            gateway: gateway,
          ),
      };
    },
  );
}

/// 扫码登录 Sheet（对齐 iOS `NativeCloudQRLoginView` / `BiliQrLoginView`）。
class CloudDriveQrLoginSheet extends StatefulWidget {
  /// 构造。
  const CloudDriveQrLoginSheet({
    super.key,
    required this.driveType,
    this.mode = CloudDriveLoginMode.nativeQr,
    this.gateway,
    this.onLoginCompleted,
  });

  /// 目标网盘。
  final CloudDriveType driveType;

  /// 登录方式（扫码类）。
  final CloudDriveLoginMode mode;

  /// 登录网关（测试注入；缺省「未接入」）。
  final CloudDriveLoginGateway? gateway;

  /// 登录完成回调（成功即触发一次；P1-B：UC 原生扫码成功后宿主据此
  /// 自动弹出 TV 授权，对齐 iOS `onUCLoginSuccess` 绑定）。
  final void Function()? onLoginCompleted;

  @override
  State<CloudDriveQrLoginSheet> createState() => _CloudDriveQrLoginSheetState();
}

class _CloudDriveQrLoginSheetState extends State<CloudDriveQrLoginSheet> {
  /// 卡内 Segmented 覆盖的网盘（对齐 iOS：百度 `BaiduScanMode`、
  /// 夸克 `QuarkScanMode`、UC `UCScanMode` 仅这三盘展示分段控件）。
  static const Set<CloudDriveType> _segmentedTypes = <CloudDriveType>{
    CloudDriveType.baidu,
    CloudDriveType.quark,
    CloudDriveType.uc,
  };

  late CloudDriveLoginController _controller;
  bool _nodeMode = false;
  bool _succeeded = false;

  @override
  void initState() {
    super.initState();
    _nodeMode = widget.mode == CloudDriveLoginMode.nodeQr;
    _buildController();
  }

  /// 当前生效类型（Node 模式 → Node 派生类型，凭据写 Node 常驻系统命名空间）。
  CloudDriveType get _effectiveType => _nodeMode
      ? _nodeTypeOf(widget.driveType)
      : widget.driveType;

  static CloudDriveType _nodeTypeOf(CloudDriveType type) => switch (type) {
        CloudDriveType.baidu => CloudDriveType.baiduNode,
        CloudDriveType.quark => CloudDriveType.quarkNode,
        CloudDriveType.uc => CloudDriveType.ucNode,
        _ => type,
      };

  void _buildController() {
    final CloudDriveLoginMode mode = _nodeMode
        ? CloudDriveLoginMode.nodeQr
        : widget.mode;
    _controller = CloudDriveLoginController(
      driveType: _effectiveType,
      mode: mode,
      gateway: widget.gateway ??
          defaultCloudDriveLoginGateway(_effectiveType, mode),
    )..addListener(_onChanged);
  }

  /// Segmented 切换（对齐 iOS `scanMode` 变更：换 gateway 与类型重建会话）。
  void _setNodeMode(bool node) {
    if (_nodeMode == node) return;
    _controller.removeListener(_onChanged);
    _controller.dispose();
    setState(() => _nodeMode = node);
    _buildController();
  }

  void _onChanged() {
    if (_controller.phase == CloudDriveLoginPhase.success && !_succeeded) {
      _succeeded = true;
      widget.onLoginCompleted?.call();
      // P1-B：对齐 iOS（`SettingsViews.swift:4934/4977` 等）成功后停留约 800ms，
      // 让用户看到「登录成功」态，随后**自动关闭**弹窗（问题 3）。
      // UC 原生扫码时宿主据此再延时弹出 TV 授权页（问题 8）。
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 标题（对齐 iOS `"\(driveType.displayName) 原生扫码授权"`；
  /// Node 档对齐 `NodeScanQRLoginView` 的 `"\(displayName) 扫码登录"`）。
  String get _headline => switch (widget.mode == CloudDriveLoginMode.nodeQr || _nodeMode) {
        true => '${_effectiveType.displayName} 扫码登录',
        false => switch (widget.mode) {
            CloudDriveLoginMode.pgQr =>
              '${widget.driveType.displayName} PG 扫码登录',
            _ => '${widget.driveType.displayName} 原生扫码授权',
          },
      };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool showSegmented =
        _segmentedTypes.contains(widget.driveType);
    // P1-A：UC Node 模式 = 完整两步扫码（对齐 iOS `ucScanMode == .node`
    // 直接渲染 `NodeUcTwoStepLoginView`；内嵌组件自带标题与步骤指示器）。
    if (showSegmented && _nodeMode && widget.driveType == CloudDriveType.uc) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(VboxSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _segmentedControl(scheme),
              const SizedBox(height: VboxSpacing.md),
              CloudDriveUcTwoStepQrSheet(
                driveType: CloudDriveType.ucNode,
                gateway: widget.gateway,
              ),
            ],
          ),
        ),
      );
    }
    final CloudDriveLoginPhase phase = _controller.phase;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VboxSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LoginSheetHeader(title: _headline),
            if (showSegmented) ...<Widget>[
              const SizedBox(height: VboxSpacing.md),
              _segmentedControl(scheme),
            ],
            const SizedBox(height: VboxSpacing.lg),
            _qrCard(scheme, phase),
            const SizedBox(height: VboxSpacing.lg),
            LoginStatusCard(
              tone: phase.tone,
              phase: phase,
              message: _controller.message,
              error: _controller.error,
            ),
            const SizedBox(height: VboxSpacing.md),
            LoginTipCard(
              text: _controller.tipText,
              tint: cloudDriveBrandColor(_effectiveType),
            ),
            const SizedBox(height: VboxSpacing.lg),
            if (phase.canCancel) ...<Widget>[
              LoginSecondaryButton(
                label: '取消',
                onTap: _controller.cancel,
              ),
              const SizedBox(height: VboxSpacing.md),
            ],
            LoginPrimaryButton(
              label: _controller.primaryLabel,
              enabled: phase != CloudDriveLoginPhase.loading,
              onTap: _controller.generateQr,
            ),
          ],
        ),
      ),
    );
  }

  /// 原生 / Node 分段控件（对齐 iOS `Picker(.segmented)`：原生档统一
  /// 「原生扫码」；Node 档百度/夸克为「Node扫码」、UC 为「Node两步登录」）。
  Widget _segmentedControl(ColorScheme scheme) {
    final String nodeLabel = widget.driveType == CloudDriveType.uc
        ? 'Node两步登录'
        : 'Node扫码';
    return SegmentedButton<bool>(
      segments: <ButtonSegment<bool>>[
        const ButtonSegment<bool>(value: false, label: Text('原生扫码')),
        ButtonSegment<bool>(value: true, label: Text(nodeLabel)),
      ],
      selected: <bool>{_nodeMode},
      onSelectionChanged: (Set<bool> selection) =>
          _setNodeMode(selection.first),
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        foregroundColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 二维码卡片（对齐 iOS `qrCard`：220×220 + 圆角 16 + 阴影）。
  Widget _qrCard(ColorScheme scheme, CloudDriveLoginPhase phase) {
    // C-盘1/C-盘3：`qr_data:` 形态为待编码的授权链接（PG），本地生成二维码；
    // data URL（B 站等）走内存图片；纯 http(s) 图片直链（百度）走网络图片。
    final String? qrContent = qrContentOf(_controller.qrDataUrl);
    final Uint8List? bytes =
        qrContent == null ? _decodeQrDataUrl(_controller.qrDataUrl) : null;
    final String? networkUrl =
        qrContent == null && bytes == null ? _qrNetworkUrl(_controller.qrDataUrl) : null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r16),
      ),
      child: Center(
        child: Container(
          width: 220,
          height: 220,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(VboxRadii.r16),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: qrContent != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(VboxRadii.r16),
                  child: QrImageView(
                    data: qrContent,
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: scheme.surface,
                    errorStateBuilder: (_, __) => _qrPlaceholder(scheme),
                  ),
                )
              : bytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(VboxRadii.r16),
                      child: Image.memory(
                        bytes,
                        width: 220,
                        height: 220,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => _qrPlaceholder(scheme),
                      ),
                    )
                  : networkUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(VboxRadii.r16),
                          child: Image.network(
                            networkUrl,
                            width: 220,
                            height: 220,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            loadingBuilder: (BuildContext _, Widget child,
                                    ImageChunkEvent? progress) =>
                                progress == null
                                    ? child
                                    : const SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                        ),
                                      ),
                            errorBuilder: (_, __, ___) => _qrPlaceholder(scheme),
                          ),
                        )
                      : phase == CloudDriveLoginPhase.loading
                          ? const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            )
                          : _qrPlaceholder(scheme),
        ),
      ),
    );
  }

  Widget _qrPlaceholder(ColorScheme scheme) => Icon(
        Icons.qr_code_2,
        size: 88,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
      );
}

/// UCNode 两步扫码登录 Sheet（对齐 iOS `NodeUcTwoStepLoginView`）。
///
/// 第 1 步 `ucCookie`（基础登录态：转存 / 目录读取依赖）→ 第 2 步 `ucToken`
/// （TV Token：非高会账号取流依赖）；本机已有 Cookie 时提供跳过第 1 步入口。
class CloudDriveUcTwoStepQrSheet extends StatefulWidget {
  /// 构造。
  const CloudDriveUcTwoStepQrSheet({
    super.key,
    required this.driveType,
    this.gateway,
    this.hasExistingCookie,
  });

  /// 目标网盘（ucNode）。
  final CloudDriveType driveType;

  /// 登录网关（测试注入；缺省按 `nodeQr` 路由）。
  final CloudDriveLoginGateway? gateway;

  /// 本机是否已有 Cookie（缺省读安全存储；测试注入）。
  final bool? hasExistingCookie;

  @override
  State<CloudDriveUcTwoStepQrSheet> createState() =>
      _CloudDriveUcTwoStepQrSheetState();
}

class _CloudDriveUcTwoStepQrSheetState
    extends State<CloudDriveUcTwoStepQrSheet> {
  late final CloudDriveLoginGateway _gateway;
  CloudDriveLoginController? _controller;
  bool _stepTwo = false;
  bool _hasCookie = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ??
        defaultCloudDriveLoginGateway(
          widget.driveType,
          CloudDriveLoginMode.nodeQr,
        );
    _resolveExistingCookie();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startStep());
  }

  Future<void> _resolveExistingCookie() async {
    bool has = widget.hasExistingCookie ?? false;
    if (widget.hasExistingCookie == null) {
      try {
        final CloudDriveCredential? cred = await CloudDriveCredentialStore(
          PrefsManager.instance,
        ).credential(CloudDriveType.ucNode);
        has = (cred?.cookie ?? '').isNotEmpty;
      } catch (_) {
        has = false;
      }
    }
    if (!mounted) return;
    setState(() => _hasCookie = has);
  }

  /// 当前步骤对应 provider（对齐 iOS 两步的 `ucCookie` / `ucToken`）。
  String get _provider => _stepTwo ? 'ucToken' : 'ucCookie';

  void _startStep() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    _controller = CloudDriveLoginController(
      driveType: widget.driveType,
      mode: CloudDriveLoginMode.nodeQr,
      gateway: _gateway,
      providerOverride: _provider,
    )..addListener(_onChanged);
    _controller!.generateQr();
  }

  /// 切到第 2 步（对齐 iOS `goToTVStep`）。
  void _goStepTwo() {
    if (!mounted || _stepTwo) return;
    setState(() => _stepTwo = true);
    _startStep();
  }

  void _onChanged() {
    final CloudDriveLoginController? c = _controller;
    if (c != null && c.phase == CloudDriveLoginPhase.success && !_finished) {
      if (!_stepTwo) {
        // 第 1 步完成 → 短暂停留后自动切第 2 步（对齐 iOS `goToTVStep`）。
        Future<void>.delayed(const Duration(milliseconds: 600), _goStepTwo);
      } else {
        _finished = true;
        // P1-B：第 2 步（TV Token）成功后自动关闭弹窗
        //（对齐 iOS `NodeUcTwoStepLoginView` 走完两步后 dismiss）。
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final CloudDriveLoginController? c = _controller;
    final CloudDriveLoginPhase phase =
        c?.phase ?? CloudDriveLoginPhase.loading;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VboxSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LoginSheetHeader(
              title: '${widget.driveType.displayName} 两步扫码登录',
            ),
            const SizedBox(height: VboxSpacing.md),
            _stepIndicator(scheme),
            const SizedBox(height: VboxSpacing.lg),
            _qrCard(scheme, phase, c?.qrDataUrl),
            const SizedBox(height: VboxSpacing.lg),
            LoginStatusCard(
              tone: phase.tone,
              phase: phase,
              message: c?.message ?? '',
              error: c?.error,
            ),
            const SizedBox(height: VboxSpacing.md),
            LoginTipCard(
              text: _stepTwo
                  ? '第 2 步 · 扫码授权 TV Token（非高会账号取流依赖）。'
                  : '第 1 步 · 扫码获取 Cookie（转存与目录读取依赖）。',
              tint: cloudDriveBrandColor(widget.driveType),
            ),
            const SizedBox(height: VboxSpacing.lg),
            LoginPrimaryButton(
              label: c?.primaryLabel ?? '生成二维码',
              enabled: phase != CloudDriveLoginPhase.loading,
              onTap: () => c?.generateQr(),
            ),
          ],
        ),
      ),
    );
  }

  /// 步骤指示器（对齐 iOS `stepIndicator`：chip + 箭头 + 说明 + 跳过入口）。
  Widget _stepIndicator(ColorScheme scheme) {
    Widget chip(int index, String text, {required bool active, required bool done}) {
      final Color tint = (active || done)
          ? VboxColors.selected
          : scheme.onSurfaceVariant;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (active || done)
              ? tint.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(VboxRadii.r8),
        ),
        child: Row(
          spacing: 5,
          children: <Widget>[
            Icon(
              done
                  ? Icons.check_circle
                  : (index == 1 ? Icons.looks_one : Icons.looks_two),
              size: VboxTypography.s13,
              color: tint,
            ),
            Text(
              text,
              style: TextStyle(fontSize: VboxTypography.s12, color: tint),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          spacing: 8,
          children: <Widget>[
            chip(1, 'Cookie', active: !_stepTwo, done: _stepTwo),
            Icon(
              Icons.arrow_forward,
              size: VboxTypography.s11,
              color: scheme.onSurfaceVariant,
            ),
            chip(2, 'TV Token', active: _stepTwo, done: false),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'UC网盘Node 播放需要 Cookie + TV Token 两项凭据，请按顺序完成两次扫码。',
          style: TextStyle(
            fontSize: VboxTypography.s12,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (!_stepTwo && _hasCookie) ...<Widget>[
          const SizedBox(height: 6),
          LoginSecondaryButton(
            label: '本机已有 Cookie，直接进行第 2 步',
            onTap: _goStepTwo,
          ),
        ],
      ],
    );
  }

  /// 二维码卡片（结构对齐 iOS `qrCard`）。
  Widget _qrCard(
    ColorScheme scheme,
    CloudDriveLoginPhase phase,
    String? qrDataUrl,
  ) {
    final String? qrContent = qrContentOf(qrDataUrl);
    final Uint8List? bytes =
        qrContent == null ? _decodeQrDataUrl(qrDataUrl) : null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(VboxSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r16),
      ),
      child: Center(
        child: Container(
          width: 220,
          height: 220,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(VboxRadii.r16),
          ),
          child: qrContent != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(VboxRadii.r16),
                  child: QrImageView(
                    data: qrContent,
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: scheme.surface,
                  ),
                )
              : bytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(VboxRadii.r16),
                      child: Image.memory(
                        bytes,
                        width: 220,
                        height: 220,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    )
                  : phase == CloudDriveLoginPhase.loading
                      ? const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : Icon(
                          Icons.qr_code_2,
                          size: 88,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                        ),
        ),
      ),
    );
  }
}

/// UC TV 画质授权 Sheet（P1-B，对齐 iOS `UCTVAuthQRView`，
/// `SettingsViews.swift:5173`）。
///
/// 由 [NativeCloudDriveLoginGateway] 直连三段链路（不经 Node 常驻系统）：
/// `startUcTvAuth`（open-api-drive.uc.cn 二维码）→ `pollUcTvAuth`（2s 一次、
/// 最多 120 次、网络错误重试 3 次）→ `exchangeUcTvToken`
/// （api.extscreen.com 兑换并入 uc 凭据 extra）。授权失败/跳过不回滚
/// 已保存的 Cookie 凭据（对齐 iOS 宽松语义）。
class CloudDriveUcTvAuthSheet extends StatefulWidget {
  /// 构造。
  const CloudDriveUcTvAuthSheet({super.key, this.gateway});

  /// 原生登录网关（测试注入；缺省自建）。
  final NativeCloudDriveLoginGateway? gateway;

  @override
  State<CloudDriveUcTvAuthSheet> createState() =>
      _CloudDriveUcTvAuthSheetState();
}

class _CloudDriveUcTvAuthSheetState extends State<CloudDriveUcTvAuthSheet> {
  late final NativeCloudDriveLoginGateway _gateway;

  /// 轮询上限（120 次 × 2s = 4 分钟，对齐 iOS `maxPoll`）。
  static const int _maxPoll = 120;

  String? _qrBase64;
  String _statusText = '正在获取授权二维码...';
  String _detailText = '请稍候...';
  String? _error;
  bool _isPolling = false;
  int _pollCount = 0;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ?? NativeCloudDriveLoginGateway();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startAuth());
  }

  /// 启动授权（对齐 iOS `startAuth`）。
  Future<void> _startAuth() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _statusText = '正在获取授权二维码...';
      _detailText = '请稍候...';
    });
    try {
      final CloudDriveQrTask task = await _gateway.startUcTvAuth();
      if (!mounted) return;
      setState(() {
        _qrBase64 = task.qrDataUrl;
        _statusText = '请使用 UC 浏览器扫码授权';
        _detailText = '扫码后可解锁普画 2K 画质，提升播放速度';
      });
      await _pollTvCode(task.taskId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _statusText = '获取二维码失败';
        _detailText = '';
      });
    }
  }

  /// 轮询循环（对齐 iOS `pollTVCode`：2s 间隔、120 次上限、网络错误重试
  /// 3 次、过期终止；拿到授权码后兑换失败**直接报错不重试**）。
  Future<void> _pollTvCode(String taskId) async {
    int netRetry = 0;
    setState(() {
      _isPolling = true;
      _pollCount = 0;
    });
    for (int pollCount = 1; pollCount <= _maxPoll; pollCount++) {
      if (!mounted || !_isPolling) return;
      setState(() => _pollCount = pollCount);
      String? code;
      try {
        code = await _gateway.pollUcTvAuth(taskId);
      } catch (e) {
        final String msg = '$e';
        if (!mounted) return;
        if (msg.contains('已过期')) {
          setState(() {
            _isPolling = false;
            _error = msg;
            _statusText = '二维码已过期';
            _detailText = '请点击重新获取';
          });
          return;
        }
        netRetry += 1;
        if (netRetry > 3) {
          setState(() {
            _isPolling = false;
            _error = msg;
            _statusText = '轮询失败';
            _detailText = '';
          });
          return;
        }
        setState(() {
          _statusText = '网络波动，重试中 ($netRetry/3)';
          _detailText = msg;
        });
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      if (!mounted || !_isPolling) return;
      if (code != null) {
        // 兑换失败直接报错不重试（对齐 iOS `Token 兑换失败` 分支）。
        try {
          setState(() {
            _statusText = '授权成功，正在获取 TV Token...';
            _detailText = '';
          });
          await _gateway.exchangeUcTvToken(taskId, code);
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _isPolling = false;
            _error = 'Token 兑换失败: $e';
            _statusText = '授权失败';
            _detailText = '';
          });
          return;
        }
        if (!mounted) return;
        setState(() {
          _isPolling = false;
          _statusText = '✅ UC TV 授权成功';
          _detailText = '已解锁普画 2K 画质，播放速度将大幅提升';
        });
        // 成功 1.5s 后自动关闭（对齐 iOS `asyncAfter 1.5 → dismiss`）。
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      setState(() {
        _statusText = '等待扫码授权';
        _detailText =
            '请使用 UC 浏览器扫描二维码并确认授权（剩余 ${_maxPoll - pollCount} 次）';
      });
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (mounted && _isPolling) {
      setState(() {
        _isPolling = false;
        _statusText = '二维码已过期';
        _detailText = '请点击重新获取';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Uint8List? qrBytes = _qrBase64 == null
        ? null
        : () {
            try {
              return base64Decode(_qrBase64!);
            } catch (_) {
              return null;
            }
          }();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VboxSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const LoginSheetHeader(title: 'UC TV 画质授权'),
            const SizedBox(height: VboxSpacing.lg),
            // 二维码卡（对齐 iOS：base64 PNG 直渲；未就绪转圈 / 失败警告）。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(VboxSpacing.lg),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(VboxRadii.r16),
              ),
              child: Center(
                child: Container(
                  width: 220,
                  height: 220,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(VboxRadii.r16),
                  ),
                  child: qrBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(VboxRadii.r16),
                          child: Image.memory(
                            qrBytes,
                            width: 220,
                            height: 220,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        )
                      : (_error == null
                          ? const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 40,
                                  color: scheme.error,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '获取失败',
                                  style: TextStyle(
                                    fontSize: VboxTypography.s12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            )),
                ),
              ),
            ),
            const SizedBox(height: VboxSpacing.lg),
            // 状态卡（对齐 iOS statusText / detailText / errorText 三行）。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: VboxSpacing.md,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(VboxRadii.r10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _statusText,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w600,
                      color: _statusText.contains('成功')
                          ? Colors.green.shade700
                          : scheme.onSurface,
                    ),
                  ),
                  if (_detailText.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      _detailText,
                      style: TextStyle(
                        fontSize: VboxTypography.s12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: VboxTypography.s12,
                        color: scheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: VboxSpacing.md),
            if (_isPolling)
              Text(
                '已轮询 $_pollCount 次',
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            // 失败且非轮询中 → 重新获取（对齐 iOS「重新获取二维码」按钮）。
            if (_error != null && !_isPolling) ...<Widget>[
              const SizedBox(height: VboxSpacing.md),
              LoginSecondaryButton(
                label: '重新获取二维码',
                onTap: _startAuth,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 短信验证码登录 Sheet（对齐 iOS `NodeGuangyaSMSLoginView`）。
class CloudDriveSmsLoginSheet extends StatefulWidget {
  /// 构造。
  const CloudDriveSmsLoginSheet({
    super.key,
    required this.driveType,
    this.mode = CloudDriveLoginMode.nodeSms,
    this.gateway,
    this.bridge = const UnavailableWebViewBridge(),
  });

  /// 目标网盘。
  final CloudDriveType driveType;

  /// 登录方式（短信类）。
  final CloudDriveLoginMode mode;

  /// 登录网关（测试注入；缺省「未接入」）。
  final CloudDriveLoginGateway? gateway;

  /// 内嵌 WebView 桥（Web-R3：139 滑块；不可用则不展示滑块面板）。
  final WebViewBridge bridge;

  @override
  State<CloudDriveSmsLoginSheet> createState() => _CloudDriveSmsLoginSheetState();
}

class _CloudDriveSmsLoginSheetState extends State<CloudDriveSmsLoginSheet> {
  late final CloudDriveLoginController _controller;
  late final CloudDriveLoginGateway _gateway;
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ??
        defaultCloudDriveLoginGateway(widget.driveType, widget.mode);
    _controller = CloudDriveLoginController(
      driveType: widget.driveType,
      mode: widget.mode,
      gateway: _gateway,
    )..addListener(_onChanged);
    _phone.addListener(_onChanged);
    _code.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _canLogin =>
      _phone.text.trim().isNotEmpty &&
      _code.text.trim().isNotEmpty &&
      _controller.phase != CloudDriveLoginPhase.loading;

  /// 139 滑块验证页（无则 null）。
  String? get _captchaUrl => _gateway.pendingCaptchaUrl(widget.driveType);

  /// 短信档状态主行（按短信语义替换扫码档的 `phase.displayText`）。
  String get _statusTitle => switch (_controller.phase) {
        CloudDriveLoginPhase.idle => '输入手机号后获取验证码',
        CloudDriveLoginPhase.success => '登录成功',
        CloudDriveLoginPhase.failed => '登录失败',
        CloudDriveLoginPhase.loading ||
        CloudDriveLoginPhase.waitingScan ||
        CloudDriveLoginPhase.scanned ||
        CloudDriveLoginPhase.exchanging ||
        CloudDriveLoginPhase.saving =>
          _controller.message.isEmpty ? '等待中…' : _controller.message,
      };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final CloudDriveLoginPhase phase = _controller.phase;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(VboxSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LoginSheetHeader(title: '${widget.driveType.displayName} 授权'),
              const SizedBox(height: VboxSpacing.lg),
              Text(
                '使用${widget.driveType.displayName}注册手机号接收验证码，登录成功后自动回收 Token。',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: VboxSpacing.lg),
              _formCard(scheme),
              if (_captchaUrl != null && widget.bridge.isAvailable) ...<Widget>[
                const SizedBox(height: VboxSpacing.lg),
                _captchaCard(scheme, _captchaUrl!),
              ],
              const SizedBox(height: VboxSpacing.lg),
              LoginStatusCard(
                tone: phase.tone,
                phase: phase,
                title: _statusTitle,
                message: '',
                error: _controller.error,
              ),
              const SizedBox(height: VboxSpacing.lg),
              LoginPrimaryButton(
                label: _controller.primaryLabel,
                enabled: _canLogin,
                onTap: () => _controller.loginWithSms(_code.text),
              ),
              const SizedBox(height: VboxSpacing.lg),
              LoginTipCard(
                text: _controller.tipText,
                tint: cloudDriveBrandColor(widget.driveType),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 手机号 + 验证码表单卡（对齐 iOS 分组底 + 圆角 12）。
  Widget _formCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: Column(
        children: <Widget>[
          Row(
            spacing: VboxSpacing.sm,
            children: <Widget>[
              Expanded(
                child: LoginTextField(
                  key: const ValueKey<String>('cloud_login_phone'),
                  controller: _phone,
                  hintText: '${widget.driveType.displayName}手机号',
                  keyboardType: TextInputType.phone,
                ),
              ),
              SizedBox(
                width: 90,
                height: 34,
                child: LoginSecondaryButton(
                  label: _controller.smsCooldownActive
                      ? '${_controller.countdown}s'
                      : '获取验证码',
                  enabled: !_controller.smsCooldownActive &&
                      _controller.phase != CloudDriveLoginPhase.loading,
                  dense: true,
                  onTap: () => _controller.sendSms(_phone.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LoginTextField(
            key: const ValueKey<String>('cloud_login_code'),
            controller: _code,
            hintText: '短信验证码',
            keyboardType: TextInputType.number,
          ),
        ],
      ),
    );
  }

  /// 139 滑块验证面板（对齐 iOS `NodeCaptchaWebView`，Web-R3）。
  Widget _captchaCard(ColorScheme scheme, String url) {
    final Widget? view = widget.bridge.buildView(url: url);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '滑块验证（完成后请等待短信）',
            style: TextStyle(
              fontSize: VboxTypography.s12,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 300,
            child: view ??
                Center(
                  child: Text(
                    'WebView 不可用',
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

/// 账号密码登录 Sheet（对齐 iOS `NodePan123LoginView` / `NodeWoniu4kLoginView`）。
class CloudDriveAccountLoginSheet extends StatefulWidget {
  /// 构造。
  const CloudDriveAccountLoginSheet({
    super.key,
    required this.driveType,
    this.mode = CloudDriveLoginMode.nodeAccount,
    this.gateway,
  });

  /// 目标网盘。
  final CloudDriveType driveType;

  /// 登录方式（账号类）。
  final CloudDriveLoginMode mode;

  /// 登录网关（测试注入；缺省「未接入」）。
  final CloudDriveLoginGateway? gateway;

  @override
  State<CloudDriveAccountLoginSheet> createState() =>
      _CloudDriveAccountLoginSheetState();
}

class _CloudDriveAccountLoginSheetState
    extends State<CloudDriveAccountLoginSheet> {
  late final CloudDriveLoginController _controller;
  late final CloudDriveLoginGateway _gateway;
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _verify = TextEditingController();
  final TextEditingController _smsCode = TextEditingController();
  String? _captchaImage;
  bool _captchaLoading = false;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ??
        defaultCloudDriveLoginGateway(widget.driveType, widget.mode);
    _controller = CloudDriveLoginController(
      driveType: widget.driveType,
      mode: widget.mode,
      gateway: _gateway,
    )..addListener(_onChanged);
    _account.addListener(_onChanged);
    _password.addListener(_onChanged);
    _verify.addListener(_onChanged);
    _smsCode.addListener(_onChanged);
    // 对齐 iOS `NodeWoniu4kLoginView.onAppear { fetchVerify() }`（首帧后拉取）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCaptcha());
  }

  /// 拉取 / 刷新图形验证码（无图形验证码的盘返回 null）。
  Future<void> _loadCaptcha() async {
    if (!mounted) return;
    setState(() => _captchaLoading = true);
    try {
      final String? img = await _gateway.loadAccountCaptcha(widget.driveType);
      if (!mounted) return;
      setState(() {
        _captchaImage = img;
        _captchaLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _captchaLoading = false);
    }
  }

  bool get _needsCaptcha => _captchaImage != null;

  /// 提交账号登录；失败时刷新图形验证码（对齐 iOS 提交失败自动换图）。
  ///
  /// 天翼 189 二次校验态（[accountNeedsSms]）改走短信验证码分支
  /// （对齐 iOS `NodePan189AccountLoginView.submit` 的 `needSms` 分支）。
  Future<void> _submit() async {
    if (_controller.accountNeedsSms) {
      await _controller.loginWithAccountSms(_smsCode.text);
      return;
    }
    await _controller.loginWithAccount(
      _account.text,
      _password.text,
      captchaCode: _verify.text,
    );
    if (_needsCaptcha && _controller.phase == CloudDriveLoginPhase.failed) {
      await _loadCaptcha();
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _account.dispose();
    _password.dispose();
    _verify.dispose();
    _smsCode.dispose();
    super.dispose();
  }

  bool get _canLogin {
    // 二次校验态仅需短信验证码（对齐 iOS `canSubmit` 的 `needSms` 分支）。
    if (_controller.accountNeedsSms) {
      return _smsCode.text.trim().isNotEmpty &&
          _controller.phase != CloudDriveLoginPhase.loading;
    }
    return _account.text.trim().isNotEmpty &&
        _password.text.isNotEmpty &&
        (!_needsCaptcha || _verify.text.trim().isNotEmpty) &&
        _controller.phase != CloudDriveLoginPhase.loading;
  }

  /// 账号档状态主行（按账号语义替换扫码档的 `phase.displayText`）。
  String get _statusTitle => switch (_controller.phase) {
        CloudDriveLoginPhase.idle =>
          _controller.accountNeedsSms ? '请输入短信验证码' : '输入账号密码登录',
        CloudDriveLoginPhase.success => '登录成功',
        CloudDriveLoginPhase.failed => '登录失败',
        CloudDriveLoginPhase.loading ||
        CloudDriveLoginPhase.waitingScan ||
        CloudDriveLoginPhase.scanned ||
        CloudDriveLoginPhase.exchanging ||
        CloudDriveLoginPhase.saving =>
          _controller.message.isEmpty ? '等待中…' : _controller.message,
      };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final CloudDriveLoginPhase phase = _controller.phase;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(VboxSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LoginSheetHeader(title: '${widget.driveType.displayName} 账号登录'),
              const SizedBox(height: VboxSpacing.lg),
              Text(
                '使用${widget.driveType.displayName}账号密码登录，登录成功后自动回收凭据到授权中心。',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: VboxSpacing.lg),
              _formCard(scheme),
              const SizedBox(height: VboxSpacing.lg),
              LoginStatusCard(
                tone: phase.tone,
                phase: phase,
                title: _statusTitle,
                message: '',
                error: _controller.error,
              ),
              const SizedBox(height: VboxSpacing.lg),
              LoginPrimaryButton(
                label: _controller.accountNeedsSms
                    ? (_controller.phase == CloudDriveLoginPhase.loading
                        ? '验证中…'
                        : '验证短信并登录')
                    : (phase == CloudDriveLoginPhase.loading
                        ? '登录中…'
                        : '登录并保存'),
                enabled: _canLogin,
                onTap: _submit,
              ),
              const SizedBox(height: VboxSpacing.lg),
              LoginTipCard(
                text: _controller.tipText,
                tint: cloudDriveBrandColor(widget.driveType),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 账号 + 密码表单卡（对齐 iOS 分组底 + 圆角 12）。
  Widget _formCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: Column(
        spacing: 10,
        children: <Widget>[
          LoginTextField(
            key: const ValueKey<String>('cloud_login_account'),
            controller: _account,
            hintText: '${widget.driveType.displayName}账号',
          ),
          LoginTextField(
            key: const ValueKey<String>('cloud_login_password'),
            controller: _password,
            hintText: '${widget.driveType.displayName}密码',
            obscureText: true,
          ),
          // 短信二次校验（天翼 189，对齐 iOS `NodePan189AccountLoginView` 的
          // `needSms` 态：账号密码提交后由 Node 下发短信，此处补录验证码）。
          if (_controller.accountNeedsSms)
            LoginTextField(
              key: const ValueKey<String>('cloud_login_sms_code'),
              controller: _smsCode,
              hintText: '短信验证码',
            ),
          // 图形验证码（对齐 iOS `NodeWoniu4kLoginView`：验证码输入 + 图 120×40）。
          if (_needsCaptcha)
            Row(
              spacing: VboxSpacing.sm,
              children: <Widget>[
                Expanded(
                  child: LoginTextField(
                    key: const ValueKey<String>('cloud_login_verify'),
                    controller: _verify,
                    hintText: '验证码',
                  ),
                ),
                SizedBox(
                  width: 120,
                  height: 40,
                  child: _captchaButton(scheme),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 图形验证码图（点击刷新，对齐 iOS 点击 `fetchVerify`）。
  Widget _captchaButton(ColorScheme scheme) {
    final Uint8List? bytes = _decodeQrDataUrl(_captchaImage);
    return InkWell(
      onTap: _captchaLoading ? null : _loadCaptcha,
      borderRadius: BorderRadius.circular(VboxRadii.r8),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(VboxRadii.r8),
        ),
        child: _captchaLoading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : bytes != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(VboxRadii.r8),
                    child: Image.memory(
                      bytes,
                      width: 120,
                      height: 40,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => _captchaText(scheme),
                    ),
                  )
                : _captchaText(scheme),
      ),
    );
  }

  Widget _captchaText(ColorScheme scheme) => Text(
        '获取验证码',
        style: TextStyle(
          fontSize: VboxTypography.s12,
          color: scheme.onSurfaceVariant,
        ),
      );
}

/// 网页兜底凭据落盘回调（F-02 余项；测试注入替身，缺省写契约安全存储）。
typedef CloudDriveWebCredentialSaver = Future<void> Function({
  required CloudDriveType type,
  required String secret,
});

/// 默认落盘：把网页登录回收到的 Token / Cookie 写入
/// `cloud_drive_credentials_v1`（契约 `storage: keychain`）。
///
/// 对齐 iOS `CloudDriveAuthManager.saveWebViewCookie(type:cookie:)`：仅落凭据 +
/// 标记 `valid`（是否真正可用仍由授权中心的 `isAuthorized` 复审，百度需
/// BDUSS+STOKEN 齐全）。阿里特殊：提取值写入 `refreshToken` 字段而非
/// cookie（对齐 iOS `saveWebViewCookie` ali 分支，`CloudDriveAuthManager.swift:2601`）。
Future<void> saveWebCredentialToStore({
  required CloudDriveType type,
  required String secret,
}) async {
  final CloudDriveCredentialStore store =
      CloudDriveCredentialStore(PrefsManager.instance);
  final DateTime now = DateTime.now();
  if (type == CloudDriveType.ali) {
    // OpenList 授权页展示的是 refresh_token（非 Cookie）。
    await store.save(
      CloudDriveCredential(
        driveType: type.id,
        authType: CloudDriveAuthType.webView,
        refreshToken: secret,
        updatedAt: now,
        lastCheckedAt: now,
        state: CloudDriveAuthState.valid,
      ),
    );
    return;
  }
  await store.save(
    CloudDriveCredential(
      driveType: type.id,
      authType: CloudDriveAuthType.webView,
      cookie: secret,
      updatedAt: now,
      lastCheckedAt: now,
      state: CloudDriveAuthState.valid,
    ),
  );
}

/// 网页登录兜底 Sheet（批次 F · F-02 余项）。
///
/// 对齐 iOS `*LoginHelper`（`CloudDriveAuthManager.swift`）的网页登录页：
/// ① 拉起官方登录页（[launchUrl] 系统浏览器）→ ② 用户完成登录 →
/// ③ 粘贴回收到的 Cookie / Token → ④ 落安全存储并回授权中心。
class CloudDriveWebLoginSheet extends StatefulWidget {
  /// 构造。
  const CloudDriveWebLoginSheet({
    super.key,
    required this.driveType,
    this.saver,
    this.bridge = const UnavailableWebViewBridge(),
  });

  /// 目标网盘。
  final CloudDriveType driveType;

  /// 凭据落盘回调（测试注入；缺省 [saveWebCredentialToStore]）。
  final CloudDriveWebCredentialSaver? saver;

  /// 内嵌 WebView 桥（Web-R1；缺省未接入 → 回退「浏览器 + 粘贴」）。
  final WebViewBridge bridge;

  @override
  State<CloudDriveWebLoginSheet> createState() =>
      _CloudDriveWebLoginSheetState();
}

class _CloudDriveWebLoginSheetState extends State<CloudDriveWebLoginSheet> {
  final TextEditingController _secret = TextEditingController();
  bool _saving = false;
  bool _saved = false;
  bool _autoRunning = false;
  String? _error;
  String? _launchError;
  String? _autoError;

  @override
  void initState() {
    super.initState();
    _secret.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _secret.removeListener(_onChanged);
    _secret.dispose();
    super.dispose();
  }

  String? get _url => CloudDriveWebLogin.urlFor(widget.driveType);

  bool get _canSave => _secret.text.trim().isNotEmpty && !_saving && !_saved;

  /// 打开官方登录页（系统浏览器）。
  Future<void> _openUrl() async {
    final String? url = _url;
    if (url == null) return;
    bool launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (!mounted) return;
    setState(() {
      _launchError = launched ? null : '无法拉起浏览器，请复制链接后手动打开';
    });
    if (!launched) {
      VboxToast.show(context, '无法拉起浏览器，请复制登录链接');
    }
  }

  /// 复制官方登录页地址（兜底：无法拉起浏览器时手动打开）。
  Future<void> _copyUrl() async {
    final String? url = _url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    VboxToast.show(context, '已复制登录链接');
  }

  /// 内嵌 WebView 打开官方登录页并自动回收 HttpOnly Cookie（Web-R1）。
  ///
  /// 桥未接入（[UnavailableWebViewBridge]）时抛明确错误，不影响「浏览器 + 粘贴」。
  Future<void> _autoFetch() async {
    final String? url = _url;
    if (url == null) return;
    setState(() {
      _autoRunning = true;
      _autoError = null;
    });
    try {
      final WebAuthPolicy? policy = WebAuthPolicy.of(widget.driveType);
      final WebViewPageResult page = await widget.bridge.loadPage(
        url: url,
        userAgent: policy?.userAgent,
        timeout: const Duration(seconds: 30),
      );
      final String cookie = await widget.bridge.currentCookieString(
        domain: policy != null && policy.cookieHosts.isNotEmpty
            ? policy.cookieHosts.first
            : null,
      );
      final String secret = cookie.isNotEmpty ? cookie : page.cookie;
      if (secret.isEmpty) {
        throw const WebViewBridgeException('未回收到有效 Cookie，请在页面完成登录后重试');
      }
      await (widget.saver ?? saveWebCredentialToStore)(
        type: widget.driveType,
        secret: secret,
      );
      if (!mounted) return;
      setState(() {
        _autoRunning = false;
        _saved = true;
      });
    } on WebViewBridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _autoRunning = false;
        _autoError = e.message;
      });
      VboxToast.show(context, e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _autoRunning = false;
        _autoError = '自动回收失败：$e';
      });
    }
  }

  /// 保存粘贴的 Token / Cookie 到安全存储（空凭据时主按钮禁用，不会进此分支）。
  Future<void> _save() async {
    final String secret = _secret.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await (widget.saver ?? saveWebCredentialToStore)(
        type: widget.driveType,
        secret: secret,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  CloudDriveLoginPhase get _phase {
    if (_saved) return CloudDriveLoginPhase.success;
    if (_saving) return CloudDriveLoginPhase.loading;
    if (_error != null) return CloudDriveLoginPhase.failed;
    return CloudDriveLoginPhase.idle;
  }

  String get _statusTitle {
    if (_saved) return '已保存到授权中心';
    if (_saving) return '正在保存凭据…';
    if (_error != null) return '保存失败';
    return '等待粘贴 Token / Cookie';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(VboxSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LoginSheetHeader(title: '${widget.driveType.displayName} 网页登录兜底'),
              const SizedBox(height: VboxSpacing.lg),
              Text(
                '在系统浏览器完成${widget.driveType.displayName}网页登录后，'
                '把回收到的 Cookie / Token 粘贴到下方并保存。',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: VboxSpacing.lg),
              _urlCard(scheme),
              const SizedBox(height: VboxSpacing.lg),
              _pasteCard(scheme),
              const SizedBox(height: VboxSpacing.lg),
              LoginStatusCard(
                tone: _phase.tone,
                phase: _phase,
                title: _statusTitle,
                message: '',
                error: _error,
              ),
              const SizedBox(height: VboxSpacing.lg),
              LoginPrimaryButton(
                label: _saved ? '已保存' : (_saving ? '保存中…' : '保存并授权'),
                enabled: _canSave,
                onTap: _save,
              ),
              const SizedBox(height: VboxSpacing.lg),
              LoginTipCard(
                text: 'iOS 侧内嵌 WebView 可直接读取 HttpOnly Cookie；'
                    'Flutter 端在 WebView 桥（Web-R1）接入后自动回收，'
                    '未接入时走「系统浏览器 + 粘贴」兜底；'
                    '保存后凭据写入安全存储并即时出现在授权中心。',
                tint: cloudDriveBrandColor(widget.driveType),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 官方登录页卡片（地址 + 复制链接 / 打开网页）。
  Widget _urlCard(ColorScheme scheme) {
    final String url = _url ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.language,
                size: VboxTypography.s16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: VboxSpacing.sm),
              Expanded(
                child: Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s13,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          Row(
            spacing: 10,
            children: <Widget>[
              Expanded(
                child: LoginSecondaryButton(
                  label: '复制链接',
                  onTap: _copyUrl,
                ),
              ),
              Expanded(
                child: LoginSecondaryButton(
                  label: '打开网页',
                  enabled: _url != null,
                  onTap: _openUrl,
                ),
              ),
            ],
          ),
          // Web-R1：桥可用时提供内嵌登录并自动回收 HttpOnly Cookie。
          if (widget.bridge.isAvailable)
            LoginSecondaryButton(
              label: _autoRunning ? '自动回收中…' : '内嵌登录并自动回收',
              enabled: !_autoRunning && _url != null,
              onTap: _autoFetch,
            ),
          if (_launchError != null)
            Text(
              _launchError!,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.error,
              ),
            ),
          if (_autoError != null)
            Text(
              _autoError!,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.error,
              ),
            ),
        ],
      ),
    );
  }

  /// 粘贴卡（Cookie / Token 多行输入）。
  Widget _pasteCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r12),
      ),
      child: LoginTextField(
        key: const ValueKey<String>('cloud_login_web_secret'),
        controller: _secret,
        hintText: CloudDriveWebLogin.credentialHint(widget.driveType),
        maxLines: 3,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 共享子组件（对齐 iOS 各登录视图的公共行级结构）
// ─────────────────────────────────────────────────────────────

/// 登录 Sheet 顶栏（标题 + 关闭）。
class LoginSheetHeader extends StatelessWidget {
  /// 构造。
  const LoginSheetHeader({super.key, required this.title});

  /// 标题文案。
  final String title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: VboxTypography.s16,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: Icon(
            Icons.close,
            size: VboxTypography.s18,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 登录状态卡（对齐 iOS `statusCard`：状态点 + 文案 + 已登录角标 + 错误行）。
class LoginStatusCard extends StatelessWidget {
  /// 构造。
  const LoginStatusCard({
    super.key,
    required this.tone,
    required this.phase,
    required this.message,
    this.error,
    this.title,
  });

  /// 配色档。
  final CloudDriveLoginTone tone;

  /// 阶段。
  final CloudDriveLoginPhase phase;

  /// 状态说明。
  final String message;

  /// 错误文案（非空优先展示）。
  final String? error;

  /// 主行文案覆盖（短信档按自身语义替换 `phase.displayText`；缺省取阶段文案）。
  final String? title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = loginToneColor(scheme, tone);
    final String? errorText = error;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.md,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(VboxRadii.r10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: VboxSpacing.sm),
              Expanded(
                child: Text(
                  title ?? phase.displayText,
                  style: TextStyle(
                    fontSize: VboxTypography.s14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (phase == CloudDriveLoginPhase.success)
                _badge('已登录', VboxColors.success),
            ],
          ),
          if (errorText != null) ...<Widget>[
            const SizedBox(height: VboxSpacing.xs),
            Text(
              errorText,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.error,
              ),
            ),
          ] else if (message.isNotEmpty &&
              phase != CloudDriveLoginPhase.idle) ...<Widget>[
            const SizedBox(height: VboxSpacing.xs),
            Text(
              message,
              style: TextStyle(
                fontSize: VboxTypography.s12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: VboxSpacing.sm, vertical: 4),
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

/// 提示卡（对齐 iOS `tipCard`：品牌色 8% 底 + 圆角 14）。
class LoginTipCard extends StatelessWidget {
  /// 构造。
  const LoginTipCard({super.key, required this.text, required this.tint});

  /// 提示文案。
  final String text;

  /// 品牌主色（背景淡染）。
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(VboxRadii.r14),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: VboxTypography.s12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 主按钮（对齐 iOS 登录视图主按钮：满宽 + 主色 + 圆角 12）。
class LoginPrimaryButton extends StatelessWidget {
  /// 构造。
  const LoginPrimaryButton({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  /// 文案。
  final String label;

  /// 是否可用。
  final bool enabled;

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: enabled
            ? scheme.primary
            : scheme.onSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(VboxRadii.r12),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(VboxRadii.r12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: VboxSpacing.md),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: VboxTypography.s15,
                  fontWeight: FontWeight.w600,
                  color: enabled ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 次级按钮（取消 / 获取验证码；[dense] 用于表单内小号档）。
class LoginSecondaryButton extends StatelessWidget {
  /// 构造。
  const LoginSecondaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.dense = false,
  });

  /// 文案。
  final String label;

  /// 点击回调。
  final VoidCallback onTap;

  /// 是否可用。
  final bool enabled;

  /// 紧凑档（表单内 90×34）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground =
        enabled ? scheme.primary : scheme.onSurfaceVariant;
    return SizedBox(
      width: double.infinity,
      height: dense ? null : 42,
      child: Material(
        color: foreground.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(VboxRadii.r8),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(VboxRadii.r8),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: dense ? VboxTypography.s12 : VboxTypography.s14,
                fontWeight: FontWeight.w500,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 登录输入框（对齐 iOS `RoundedBorderTextFieldStyle` 的朴素样式）。
class LoginTextField extends StatelessWidget {
  /// 构造。
  const LoginTextField({
    super.key,
    required this.controller,
    required this.hintText,
    this.keyboardType,
    this.obscureText = false,
    this.maxLines = 1,
  });

  /// 文本控制器。
  final TextEditingController controller;

  /// 占位提示。
  final String hintText;

  /// 键盘类型。
  final TextInputType? keyboardType;

  /// 是否密码框（对齐 iOS `SecureField`）。
  final bool obscureText;

  /// 最大行数（网页兜底粘贴 Cookie / Token 用多行）。
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      maxLines: maxLines,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(
        fontSize: VboxTypography.s14,
        color: scheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(
          fontSize: VboxTypography.s14,
          color: scheme.onSurfaceVariant,
        ),
        isDense: true,
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.md,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VboxRadii.r8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// 登录配色档 → 令牌色（域层不持有色值，映射集中在表现层）。
Color loginToneColor(ColorScheme scheme, CloudDriveLoginTone tone) =>
    switch (tone) {
      CloudDriveLoginTone.neutral => scheme.onSurfaceVariant,
      CloudDriveLoginTone.busy => VboxColors.warning,
      CloudDriveLoginTone.active => VboxColors.selected,
      CloudDriveLoginTone.pending => VboxColors.pending,
      CloudDriveLoginTone.ok => VboxColors.success,
      CloudDriveLoginTone.error => scheme.error,
    };

/// 二维码**远程图片**地址（百度扫码返回图片 URL，而非 data URL / 待编码文本）。
///
/// 对齐 iOS `NativeCloudQRLoginView`：百度 `getqrcode` 的 `imgurl` 是图片直链，
/// 表现层直接按网络图片渲染；前端生成类（UC / 夸克，`qr_data:`）与 data URL
/// 两类已由其它分支处理，这里只挑出纯 http(s) 图片地址。
String? _qrNetworkUrl(String? qrDataUrl) {
  if (qrDataUrl == null) return null;
  final String source = qrDataUrl.trim();
  if (source.isEmpty ||
      source.startsWith(kQrDataContentPrefix) ||
      source.startsWith('data:')) {
    return null;
  }
  return (source.startsWith('http://') || source.startsWith('https://'))
      ? source
      : null;
}

/// 解析二维码 data URL（对齐 iOS `NodeLoginAPIClient.image(fromDataURL:)`）。
Uint8List? _decodeQrDataUrl(String? dataUrl) {
  if (dataUrl == null) return null;
  String source = dataUrl.trim();
  final int marker = source.indexOf('base64,');
  if (marker >= 0) source = source.substring(marker + 7);
  if (source.isEmpty) return null;
  try {
    return base64Decode(source);
  } catch (_) {
    return null;
  }
}
