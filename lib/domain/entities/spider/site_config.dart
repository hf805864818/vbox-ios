/// 领域层：站点配置（SiteConfig）与其解析逻辑。
///
/// 唯一真相源：`contract/docs/abi_v1.md` §8「站点配置字段」
///            + §1.1「引擎选择规则」
library;

import 'engine_type.dart';

/// 站点配置（对齐 iOS `struct SiteConfig`）。
class SiteConfig {
  const SiteConfig({
    required this.key,
    required this.name,
    required this.type,
    this.api,
    this.searchable,
    this.quickSearch,
    this.filterable,
    this.ext,
    this.playerType,
    this.jar,
    this.changeable,
    this.playStrategy,
    this.playMode,
    this.panHosts,
    this.group,
    this.engineType,
    this.pluginPath,
    this.version,
    this.md5,
  });

  /// 站点唯一键。
  final String key;

  /// 站点名。
  final String name;

  /// 0/1=API, 2=站源, 3=蜘蛛。
  final int type;

  /// 脚本路径或 API 地址。
  final String? api;
  final int? searchable;
  final int? quickSearch;
  final int? filterable;
  final String? ext;
  final int? playerType;
  final String? jar;
  final int? changeable;
  final String? playStrategy;

  /// normal / pan / hybrid。
  final String? playMode;

  /// 网盘宿主列表。
  final List<String>? panHosts;

  /// video/music/node/cloud/api。
  final String? group;

  /// lxMusic / node / 空。
  final String? engineType;

  /// lx 插件路径。
  final String? pluginPath;

  /// 插件版本。
  final String? version;

  /// 插件完整性校验。
  final String? md5;

  factory SiteConfig.fromJson(Map<String, Object?> j) => SiteConfig(
        key: (j['key'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        type: _asInt(j['type']) ?? 0,
        api: j['api']?.toString(),
        searchable: _asInt(j['searchable']),
        quickSearch: _asInt(j['quickSearch']),
        filterable: _asInt(j['filterable']),
        ext: j['ext']?.toString(),
        playerType: _asInt(j['playerType']),
        jar: j['jar']?.toString(),
        changeable: _asInt(j['changeable']),
        playStrategy: j['playStrategy']?.toString(),
        playMode: j['playMode']?.toString(),
        panHosts: (j['panHosts'] as List?)?.map((e) => e.toString()).toList(),
        group: j['group']?.toString(),
        engineType: j['engineType']?.toString(),
        pluginPath: j['pluginPath']?.toString(),
        version: j['version']?.toString(),
        md5: j['md5']?.toString(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'name': name,
        'type': type,
        if (api != null) 'api': api,
        if (searchable != null) 'searchable': searchable,
        if (quickSearch != null) 'quickSearch': quickSearch,
        if (filterable != null) 'filterable': filterable,
        if (ext != null) 'ext': ext,
        if (playerType != null) 'playerType': playerType,
        if (jar != null) 'jar': jar,
        if (changeable != null) 'changeable': changeable,
        if (playStrategy != null) 'playStrategy': playStrategy,
        if (playMode != null) 'playMode': playMode,
        if (panHosts != null) 'panHosts': panHosts,
        if (group != null) 'group': group,
        if (engineType != null) 'engineType': engineType,
        if (pluginPath != null) 'pluginPath': pluginPath,
        if (version != null) 'version': version,
        if (md5 != null) 'md5': md5,
      };

  /// 源分类展示名（对齐 iOS `SourceDisplayItem.category.displayName`）。
  ///
  /// iOS 由源类型直接给出分类（网盘 / API / 站源 / JS / 论坛）；
  /// Flutter 侧 [SiteConfig] 无该字段，按 `group` / `type` / `api` 形态推导，
  /// 供「切换源」浮层分组与分类页类型徽标使用。
  String get categoryLabel {
    if (key.startsWith('cloud_') || group == 'cloud' || group == 'pan') {
      return '网盘';
    }
    switch (type) {
      case 0:
      case 1:
        return 'API';
      case 2:
        return '站源';
      case 3:
        final String a = api ?? '';
        if (a.endsWith('.js') || a.endsWith('.py') || a.endsWith('.ts')) {
          return 'JS';
        }
        return '论坛';
    }
    return 'API';
  }

  /// 是否为 Node 常驻源（对齐 iOS `isNodeSite`）。
  ///
  /// - group == "node"
  /// - key 前缀 "nodejs_"
  /// - key 前缀 "csp_" 且 type == 3
  /// - api 前缀 "nodejs_" 或（"csp_" 且 type==3）
  /// - api 含 "://127.0.0.1" 且含 "/spider/"
  bool get isNodeSite {
    final String k = key;
    final String a = api ?? '';
    if (group == 'node') return true;
    if (k.startsWith('nodejs_')) return true;
    if (k.startsWith('csp_') && type == 3) return true;
    if (a.startsWith('nodejs_')) return true;
    if (a.startsWith('csp_') && type == 3) return true;
    if (a.contains('://127.0.0.1') && a.contains('/spider/')) return true;
    return false;
  }

  /// 解析站点模式（对齐 iOS `resolveSiteMode(site:)`，优先级从高到低）。
  SiteMode resolveSiteMode() {
    // ① Node 源
    if (isNodeSite) return SiteMode.node;

    final String a = api ?? '';

    // ② type 0 或 1 → API 端点
    if (type == 0 || type == 1) return SiteMode.apiEndpoint;

    // ③ type 2 → 站源
    if (type == 2) return SiteMode.zhanyuan;

    // ④ type 3 → 按 api 形式细分
    if (type == 3) {
      if (a.contains('.jar')) return SiteMode.unsupported;
      if (a.endsWith('.py')) return SiteMode.pythonSpider;

      final bool isHttp = a.startsWith('http://') || a.startsWith('https://');
      if (isHttp && a.endsWith('.js')) return SiteMode.jsSpider;
      if (isHttp && !a.endsWith('.js')) return SiteMode.apiEndpoint;

      if (a.endsWith('.js') || a.startsWith('./')) return SiteMode.jsSpider;

      // 其他（纯类名）
      return SiteMode.unsupported;
    }

    // ⑤ 其他 type
    return SiteMode.unsupported;
  }

  /// 该站点应使用的引擎（若模式为脚本引擎）。
  SpiderEngineType? resolveEngineType() {
    switch (resolveSiteMode()) {
      case SiteMode.node:
        return group == 'node' && (engineType == 'lxMusic' || (api ?? '').contains('lx'))
            ? SpiderEngineType.nodeLX
            : SpiderEngineType.node;
      case SiteMode.jsSpider:
        return SpiderEngineType.javaScriptCore;
      case SiteMode.pythonSpider:
        return SpiderEngineType.python;
      case SiteMode.apiEndpoint:
      case SiteMode.zhanyuan:
      case SiteMode.unsupported:
        return null;
    }
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}
