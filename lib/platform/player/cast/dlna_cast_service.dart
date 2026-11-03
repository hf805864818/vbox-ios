/// 平台层：DLNA / UPnP AV 投屏实现（批次 C · C-09）。
///
/// 纯 Dart 实现（无原生插件依赖），四端（Android / Android TV / Windows /
/// macOS）通用：SSDP 组播发现 MediaRenderer → 拉取设备描述 → SOAP 控制
/// AVTransport（SetAVTransportURI / Play / Pause / Stop / Seek）与
/// RenderingControl（SetVolume）。
///
/// 遵守 [CastService] 契约：网络/协议失败一律降级（返回空列表 / false / no-op），
/// 不抛异常、不阻断播放。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'cast_service.dart';

/// DLNA 设备描述（`/description.xml` 解析结果）。
class DlnaDeviceDescription {
  /// 构造。
  const DlnaDeviceDescription({
    required this.friendlyName,
    this.udn,
    this.avTransportControlUrl,
    this.renderingControlControlUrl,
  });

  /// 设备显示名（`<friendlyName>`）。
  final String friendlyName;

  /// 设备唯一标识（`<UDN>`）。
  final String? udn;

  /// AVTransport 控制地址（`SetAVTransportURI` / `Play` 等）。
  final Uri? avTransportControlUrl;

  /// RenderingControl 控制地址（音量）。
  final Uri? renderingControlControlUrl;
}

/// DLNA 投屏服务（SSDP + SOAP）。
class DlnaCastService implements CastService {
  /// 构造。
  DlnaCastService({
    this.discoverTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 8),
    http.Client? client,
  }) : _client = client;

  /// SSDP 组播地址。
  static const String ssdpAddress = '239.255.255.250';

  /// SSDP 端口。
  static const int ssdpPort = 1900;

  /// AVTransport 服务类型（`SetAVTransportURI` / `Play` / `Pause` / `Stop` / `Seek`）。
  static const String avTransportService = 'urn:schemas-upnp-org:service:AVTransport:1';

  /// RenderingControl 服务类型（音量）。
  static const String renderingControlService =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  /// 发现窗口。
  final Duration discoverTimeout;

  /// 单请求超时。
  final Duration requestTimeout;

  final http.Client? _client;
  http.Client? _default;

  http.Client get _http => _client ?? (_default ??= http.Client());

  /// id → 目标控制信息。
  final Map<String, _DlnaTarget> _targets = <String, _DlnaTarget>{};

  CastSession? _session;

  @override
  bool get isAvailable => true;

  @override
  CastSession? get session => _session;

  @override
  void Function(CastSession session)? onSessionChanged;

  @override
  void Function(List<CastDevice> devices)? onDevicesChanged;

  /// 释放内部自建 client。
  void close() {
    _default?.close();
    _default = null;
  }

  // ─────────────── 发现 ───────────────

  @override
  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Duration window =
        timeout == const Duration(seconds: 5) ? discoverTimeout : timeout;
    final Set<String> locations = <String>{};
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    Timer? resend;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
          reuseAddress: true);
      socket.broadcastEnabled = true;
      final List<int> payload = utf8.encode(mSearchRequest);
      void sendSearch() {
        try {
          socket?.send(payload, InternetAddress(ssdpAddress), ssdpPort);
        } catch (_) {
          // 发送失败（无网 / 权限）→ 忽略，最终返回空列表。
        }
      }

      sub = socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final Datagram? datagram = socket?.receive();
        if (datagram == null) return;
        final String? location = parseSsdpLocation(
          utf8.decode(datagram.data, allowMalformed: true),
        );
        if (location != null && location.isNotEmpty) locations.add(location);
      });
      sendSearch();
      resend = Timer(const Duration(milliseconds: 300), sendSearch);
      await Future<void>.delayed(window);
    } catch (_) {
      return const <CastDevice>[];
    } finally {
      resend?.cancel();
      await sub?.cancel();
      socket?.close();
    }

    final List<CastDevice> devices = <CastDevice>[];
    for (final String location in locations) {
      final CastDevice? device = await _resolve(location);
      if (device != null) devices.add(device);
    }
    final List<CastDevice> out = _dedupe(devices);
    onDevicesChanged?.call(out);
    return out;
  }

  /// 拉取设备描述并登记控制地址。
  Future<CastDevice?> _resolve(String location) async {
    try {
      final Uri uri = Uri.parse(location);
      final http.Response resp = await _http.get(uri).timeout(requestTimeout);
      if (resp.statusCode != 200) return null;
      final DlnaDeviceDescription? desc =
          parseDeviceDescription(resp.body, uri);
      if (desc == null) return null;
      final String id = desc.udn ?? uri.host;
      final CastDevice device = CastDevice(
        id: id,
        name: desc.friendlyName.isEmpty ? uri.host : desc.friendlyName,
        kind: CastDeviceKind.dlna,
      );
      _targets[id] = _DlnaTarget(
        device: device,
        avTransport: desc.avTransportControlUrl,
        renderingControl: desc.renderingControlControlUrl,
      );
      return device;
    } catch (_) {
      return null;
    }
  }

  static List<CastDevice> _dedupe(List<CastDevice> devices) {
    final Map<String, CastDevice> byId = <String, CastDevice>{};
    for (final CastDevice d in devices) {
      byId[d.id] = d;
    }
    return byId.values.toList(growable: false);
  }

  // ─────────────── 会话 ───────────────

  @override
  Future<bool> connect(CastDevice device) async {
    final _DlnaTarget? target = _targets[device.id];
    if (target == null) return false;
    _session = CastSession(device: device, state: CastSessionState.connected);
    onSessionChanged?.call(_session!);
    return true;
  }

  @override
  Future<void> disconnect() async {
    await stop();
    _session = null;
    onSessionChanged?.call(const CastSession(state: CastSessionState.disconnected));
  }

  @override
  Future<bool> cast(CastMedia media) async {
    final _DlnaTarget? target = _currentTarget();
    if (target?.avTransport == null) return false;
    final bool ok = await _soap(
      target!.avTransport!,
      avTransportService,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>${_escapeXml(media.url)}</CurrentURI>'
          '<CurrentURIMetaData></CurrentURIMetaData>',
    );
    if (!ok) return false;
    _session = (_session ?? CastSession(device: target.device)).copyWith(
      state: CastSessionState.playing,
      title: media.title,
      isLive: media.isLive,
      positionMs: media.positionMs,
    );
    onSessionChanged?.call(_session!);
    // 起播（部分设备 SetAVTransportURI 后需显式 Play）。
    await play();
    if (media.positionMs > 0) await seekTo(media.positionMs);
    return true;
  }

  @override
  Future<void> play() async {
    await _avAction('Play', '<Speed>1</Speed>');
    _setState(CastSessionState.playing);
  }

  @override
  Future<void> pause() async {
    await _avAction('Pause', '');
    _setState(CastSessionState.paused);
  }

  @override
  Future<void> stop() async {
    if (_session == null) return;
    await _avAction('Stop', '');
    _setState(CastSessionState.connected);
  }

  @override
  Future<void> seekTo(int positionMs) async {
    final int totalSec = positionMs ~/ 1000;
    final String hms =
        '${totalSec ~/ 3600}:${(totalSec % 3600) ~/ 60}:${totalSec % 60}'
            .split(':')
            .map((String s) => s.length == 1 ? '0$s' : s)
            .join(':');
    await _avAction(
      'Seek',
      '<Unit>REL_TIME</Unit><Target>$hms</Target>',
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    final _DlnaTarget? target = _currentTarget();
    if (target?.renderingControl == null) return;
    final int v = (volume.clamp(0.0, 1.0) * 100).round();
    await _soap(
      target!.renderingControl!,
      renderingControlService,
      'SetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$v</DesiredVolume>',
    );
  }

  // ─────────────── 内部工具 ───────────────

  _DlnaTarget? _currentTarget() {
    final CastDevice? device = _session?.device;
    return device == null ? null : _targets[device.id];
  }

  void _setState(CastSessionState state) {
    final CastSession? s = _session;
    if (s == null) return;
    _session = s.copyWith(state: state);
    onSessionChanged?.call(_session!);
  }

  Future<void> _avAction(String action, String extra) async {
    final _DlnaTarget? target = _currentTarget();
    if (target?.avTransport == null) return;
    await _soap(
      target!.avTransport!,
      avTransportService,
      action,
      '<InstanceID>0</InstanceID>$extra',
    );
  }

  /// 发送 SOAP 动作；成功（HTTP 200）→ true。
  Future<bool> _soap(
    Uri controlUrl,
    String serviceType,
    String action,
    String bodyInner,
  ) async {
    final String envelope = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="$serviceType">$bodyInner</u:$action>'
        '</s:Body></s:Envelope>';
    try {
      final http.Response resp = await _http
          .post(
            controlUrl,
            headers: <String, String>{
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$serviceType#$action"',
            },
            body: envelope,
          )
          .timeout(requestTimeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  // ─────────────── 纯解析（可单测） ───────────────

  /// SSDP M-SEARCH 报文（搜索 MediaRenderer）。
  static final String mSearchRequest = <String>[
    'M-SEARCH * HTTP/1.1',
    'HOST: $ssdpAddress:$ssdpPort',
    'MAN: "ssdp:discover"',
    'MX: 3',
    'ST: urn:schemas-upnp-org:device:MediaRenderer:1',
    '',
    '',
  ].join('\r\n');

  /// 从 SSDP 响应中取 `LOCATION`（大小写不敏感）；无 → null。
  static String? parseSsdpLocation(String response) {
    for (final String line in const LineSplitter().convert(response)) {
      final int idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'location') {
        final String value = line.substring(idx + 1).trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  /// 解析设备描述 XML → [DlnaDeviceDescription]（取 AVTransport / RenderingControl
  /// 的 controlURL，相对地址按 [baseUri] 解析）。
  static DlnaDeviceDescription? parseDeviceDescription(String xml, Uri baseUri) {
    final String friendly = _tagText(xml, 'friendlyName') ?? '';
    final String? udn = _tagText(xml, 'UDN');
    final Uri? av =
        _serviceControlUrl(xml, avTransportService, baseUri);
    final Uri? rc =
        _serviceControlUrl(xml, renderingControlService, baseUri);
    if (friendly.isEmpty && udn == null) return null;
    return DlnaDeviceDescription(
      friendlyName: friendly,
      udn: udn,
      avTransportControlUrl: av,
      renderingControlControlUrl: rc,
    );
  }

  /// 在 `<service>` 块内按 serviceType 取 controlURL。
  static Uri? _serviceControlUrl(
    String xml,
    String serviceType,
    Uri baseUri,
  ) {
    final RegExp serviceRe =
        RegExp(r'<service>(.*?)</service>', dotAll: true);
    for (final RegExpMatch m in serviceRe.allMatches(xml)) {
      final String block = m.group(1) ?? '';
      final String? type = _tagText(block, 'serviceType');
      if (type == null || !type.contains(serviceType)) continue;
      final String? url = _tagText(block, 'controlURL');
      if (url == null || url.isEmpty) continue;
      try {
        return baseUri.resolve(url.trim());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 取首个 `<tag>text</tag>` 文本（大小写不敏感，去空白）。
  static String? _tagText(String xml, String tag) {
    final RegExp re = RegExp('<$tag>(.*?)</$tag>', dotAll: true, caseSensitive: false);
    final RegExpMatch? m = re.firstMatch(xml);
    if (m == null) return null;
    return _unescapeXml(m.group(1) ?? '').trim();
  }

  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// 单个 DLNA 目标的控制信息。
class _DlnaTarget {
  _DlnaTarget({
    required this.device,
    this.avTransport,
    this.renderingControl,
  });

  final CastDevice device;
  final Uri? avTransport;
  final Uri? renderingControl;
}