/// 网盘 `vbox_*` fragment 参数编解码（F-P27，对齐 iOS 唯一契约来源）。
///
/// 对齐 iOS：
/// - `CloudDriveManager.splitVboxFragment`（`vbox/Services/CloudDriveManager.swift:10243`）
/// - `VideoDetailView.appendVboxFragment` / `appendNodeMark`
///   （`vbox/Views/PlayerViews.swift:802` / `:810`）
/// - `VideoPlayerViewV2.bridgeNodePanJSON` 的 fragment 生成口径
///   （`vbox/Views/PlayerViewsV2.swift:5320`）
///
/// 形态：`<baseShareUrl>#vbox_fid=<fid>` / `#vbox_node=<playID>` /
/// `#vbox_nd=1&vbox_node=<playID>` / `#vbox_fsid=…` / `#vbox_route=…`。
/// 详情页生成这些 fragment 定位「用户点击的具体剧集」，播放器消费端由
/// [split] 剥离 fragment 得到干净分享链接，再用键值定位文件。
library;

import 'cloud_drive.dart';

/// fragment 参数前缀（仅此前缀的键被识别为 vbox 参数，其余透传保留）。
const String kVboxFragmentPrefix = 'vbox_';

/// vbox fragment 参数集（对齐 iOS `splitVboxFragment` 的 `params` 字典）。
///
/// 不同网盘的定位键不同（对齐 iOS 播放器各盘 `selectedIndex` 判定）：
/// - 夸克原生：`vbox_fid`（+ `vbox_route` 线路偏好）；
/// - 百度原生：`vbox_fsid`；
/// - Node 托管盘：`vbox_node`（playID）；
/// - 部分盘：`vbox_pickcode`（115）/ `vbox_fileId` / `vbox_contentId`（139）。
class VboxFragment {
  /// 构造。
  const VboxFragment({
    this.fid,
    this.fsid,
    this.node,
    this.route,
    this.nodeMark = false,
    this.token,
    this.pickcode,
    this.fileId,
    this.contentId,
    this.extra = const <String, String>{},
  });

  /// `vbox_fid`：文件 ID（夸克 / 百度 / 阿里原生定位）。
  final String? fid;

  /// `vbox_fsid`：分享侧文件 ID（百度 `fs_id`）。
  final String? fsid;

  /// `vbox_node`：Node 托管盘 playID（base64 载荷）。
  final String? node;

  /// `vbox_route`：夸克线路偏好（`original` 原画 / `transcode` 普画）。
  final String? route;

  /// `vbox_nd=1`：Node 路链标记（夸克Node / UC网盘Node / 百度网盘Node）。
  final bool nodeMark;

  /// `vbox_token`：分享侧 fid token（夸克转存）。
  final String? token;

  /// `vbox_pickcode`：115 提取码。
  final String? pickcode;

  /// `vbox_fileId`：文件 ID（迅雷 / 123 / 189 等）。
  final String? fileId;

  /// `vbox_contentId`：139 内容 ID。
  final String? contentId;

  /// 其余 `vbox_*` 键（透传保留，便于未来扩展不丢参）。
  final Map<String, String> extra;

  /// 是否为空（无任何 vbox 参数）。
  bool get isEmpty =>
      fid == null &&
      fsid == null &&
      node == null &&
      route == null &&
      !nodeMark &&
      token == null &&
      pickcode == null &&
      fileId == null &&
      contentId == null &&
      extra.isEmpty;

  /// 是否非空。
  bool get isNotEmpty => !isEmpty;

  /// 指定剧集定位键（对齐 iOS 播放器判定顺序：
  /// node → fsid → fid → pickcode → fileId → contentId）。
  ///
  /// 返回 `(key, value)`；无定位键返回 null。
  (String, String)? get locateKey {
    if (node != null && node!.isNotEmpty) return ('vbox_node', node!);
    if (fsid != null && fsid!.isNotEmpty) return ('vbox_fsid', fsid!);
    if (fid != null && fid!.isNotEmpty) return ('vbox_fid', fid!);
    if (pickcode != null && pickcode!.isNotEmpty) return ('vbox_pickcode', pickcode!);
    if (fileId != null && fileId!.isNotEmpty) return ('vbox_fileId', fileId!);
    if (contentId != null && contentId!.isNotEmpty) {
      return ('vbox_contentId', contentId!);
    }
    return null;
  }

  /// 定位值（用于 [NodePanEntry.playID]；无则返回空串）。
  String get locateValue => locateKey?.$2 ?? '';

  /// 由参数表构建（仅读取 `vbox_*` 键）。
  factory VboxFragment.fromParams(Map<String, String> params) {
    final Map<String, String> extra = <String, String>{};
    for (final MapEntry<String, String> e in params.entries) {
      if (!e.key.startsWith(kVboxFragmentPrefix)) continue;
      if (!_knownKeys.contains(e.key)) extra[e.key] = e.value;
    }
    return VboxFragment(
      fid: params['vbox_fid'],
      fsid: params['vbox_fsid'],
      node: params['vbox_node'],
      route: params['vbox_route'],
      nodeMark: params['vbox_nd'] == '1',
      token: params['vbox_token'],
      pickcode: params['vbox_pickcode'],
      fileId: params['vbox_fileId'],
      contentId: params['vbox_contentId'],
      extra: extra,
    );
  }

  /// 已知键（其余 `vbox_*` 归入 [extra]）。
  static const Set<String> _knownKeys = <String>{
    'vbox_fid',
    'vbox_fsid',
    'vbox_node',
    'vbox_route',
    'vbox_nd',
    'vbox_token',
    'vbox_pickcode',
    'vbox_fileId',
    'vbox_contentId',
  };
}

/// fragment 拆分结果（对齐 iOS `(baseURL, params)` 元组）。
class VboxFragmentSplit {
  /// 构造。
  const VboxFragmentSplit({required this.baseUrl, required this.params});

  /// 剥离 `vbox_*` 参数后的干净分享链接（非 vbox 参数透传保留）。
  final String baseUrl;

  /// vbox 参数集。
  final VboxFragment params;

  /// 是否带 vbox 参数。
  bool get hasParams => params.isNotEmpty;
}

/// vbox fragment 编解码（对齐 iOS `splitVboxFragment` / `appendVboxFragment`）。
abstract final class VboxFragmentCodec {
  /// 拆分 URL：剥离 `vbox_*` 参数得干净分享链接 + 参数集。
  ///
  /// 对齐 iOS 语义：`#` 之后按 `&` 拆段，每段按首个 `=` 拆键值；
  /// 键以 `vbox_` 开头 → 进入参数集（值 percent-decode），否则透传保留在 baseUrl。
  static VboxFragmentSplit split(String url) {
    final int hash = url.indexOf('#');
    if (hash < 0) {
      return VboxFragmentSplit(baseUrl: url, params: const VboxFragment());
    }
    final String head = url.substring(0, hash);
    final String fragment = url.substring(hash + 1);
    final Map<String, String> params = <String, String>{};
    final List<String> passthrough = <String>[];
    for (final String item in fragment.split('&')) {
      if (item.isEmpty) continue;
      final int eq = item.indexOf('=');
      if (eq < 0) {
        passthrough.add(item);
        continue;
      }
      final String key = item.substring(0, eq);
      final String value = _decode(item.substring(eq + 1));
      if (key.startsWith(kVboxFragmentPrefix)) {
        params[key] = value;
      } else {
        passthrough.add(item);
      }
    }
    final String base = passthrough.isEmpty
        ? head
        : '$head#${passthrough.join('&')}';
    return VboxFragmentSplit(
      baseUrl: base,
      params: VboxFragment.fromParams(params),
    );
  }

  /// 剥离 `vbox_*` 参数（仅取干净分享链接）。
  static String strip(String url) => split(url).baseUrl;

  /// 追加 vbox 参数（对齐 iOS `appendVboxFragment`：已有 `#` 用 `&` 连接）。
  static String append(String url, Map<String, String> params) {
    if (params.isEmpty) return url;
    final String payload = params.entries
        .map((MapEntry<String, String> e) => '${e.key}=${_encode(e.value)}')
        .join('&');
    return url.contains('#') ? '$url&$payload' : '$url#$payload';
  }

  /// 追加 Node 路链标记 `vbox_nd=1`（对齐 iOS `appendNodeMark`，已带则不重复）。
  static String appendNodeMark(String url) {
    if (url.contains('#vbox_nd=1')) return url;
    final int hash = url.indexOf('#');
    if (hash >= 0) {
      return '${url.substring(0, hash + 1)}vbox_nd=1&${url.substring(hash + 1)}';
    }
    return '$url#vbox_nd=1';
  }

  /// 网盘类型识别（含 Node 路链标记：`#vbox_nd=1` 时映射为对应 Node 派生盘）。
  ///
  /// 对齐 iOS `resolvePlayURL`：检测盘别时优先识别 `#vbox_nd=1`，
  /// 命中夸克 / UC / 百度则分别判为 `quarkNode` / `ucNode` / `baiduNode`。
  static CloudDriveType? resolveShareType(String? url) {
    if (url == null || url.isEmpty) return null;
    final CloudDriveType? base = CloudDriveType.fromShareUrl(
      url.contains('#vbox_nd=1') ? split(url).baseUrl : url,
    );
    if (base == null) return null;
    if (!url.contains('#vbox_nd=1')) return base;
    return switch (base) {
      CloudDriveType.quark => CloudDriveType.quarkNode,
      CloudDriveType.uc => CloudDriveType.ucNode,
      CloudDriveType.baidu => CloudDriveType.baiduNode,
      _ => base,
    };
  }

  /// percent-encode（对齐 iOS `addingPercentEncoding(withAllowedCharacters:)`
  /// 的可逆语义：`+ / =` 等特殊字符编码后由 [split] 还原）。
  static String _encode(String value) => Uri.encodeComponent(value);

  /// percent-decode（非法编码回退原值，对齐 iOS `removingPercentEncoding ?? raw`）。
  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }
}