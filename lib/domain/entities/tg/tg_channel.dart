/// TG 搜索领域模型（批次 G · G-04）。
///
/// 唯一真相源：iOS `vbox/Services/TGSearchConfigStore.swift`
///   · [TGChannel]（L15-L19）—— Telegram 频道条目（显示名 + 频道 ID）；
///   · [TGChannelMode]（L22-L34）—— 频道来源三档（远程默认 / 仅自定义 / 全部合并）；
///   · `presetChannels`（L63-L75）—— 10 个常用频道（快捷添加用）；
///   · `channelModeDescription`（L387-L396）—— 三档说明文案。
///
/// 持久化：契约键 `tg_search_channels_v1`（string）存 JSON 数组字符串。
///
/// 差异登记：iOS `TGChannel` 编码含 UUID `id`（仅供 `Identifiable` 使用），
/// Flutter 以 `channelId` 为稳定标识、落盘不写 `id`（读取时忽略该键）；两端
/// `name` / `channelId` 键名一致，跨端读取兼容（同 G-03 `PushPlayItem` 口径）。
library;

import 'dart:convert';

/// 频道来源模式（对齐 iOS `TGSearchConfigStore.ChannelMode`）。
enum TGChannelMode {
  /// 仅远程默认频道。
  remoteDefault('default', '远程默认', '仅使用远程仓库内置的默认频道'),

  /// 仅自定义频道（便于排查问题）。
  custom('custom', '仅自定义', '仅使用自定义频道，方便排查问题'),

  /// 全部合并（远程默认 + 自定义并行搜索）。
  all('all', '全部合并', '远程默认频道 + 自定义频道，全部并行搜索');

  /// 构造。
  const TGChannelMode(this.rawValue, this.displayName, this.description);

  /// 存储原始值（对齐 iOS `rawValue`：default / custom / all）。
  final String rawValue;

  /// 展示名（分段控件文案）。
  final String displayName;

  /// 说明文案（分段控件下方提示，对齐 iOS `channelModeDescription`）。
  final String description;

  /// 反序列化（未知值 → [TGChannelMode.remoteDefault] 兜底，避免脏数据崩溃）。
  static TGChannelMode fromRaw(String? raw) {
    for (final TGChannelMode mode in TGChannelMode.values) {
      if (mode.rawValue == raw) return mode;
    }
    return TGChannelMode.remoteDefault;
  }
}

/// Telegram 频道条目（对齐 iOS `TGChannel`）。
class TGChannel {
  /// 构造。
  const TGChannel({required this.name, required this.channelId});

  /// 稳定标识（对齐 iOS `Identifiable`；Flutter 以 `channelId` 作 id）。
  String get id => channelId;

  /// 显示名称（如「UC夸克资源」）。
  final String name;

  /// 频道 ID（如 `ucquark`，即 `t.me/s/` 后面的名称，不含 @）。
  final String channelId;

  /// 序列化（键名对齐 iOS `CodingKeys` 的 name / channelId）。
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'channelId': channelId,
      };

  /// 反序列化（`channelId` 缺失 / 空 → null；空 `name` 回退为 `channelId`）。
  static TGChannel? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? channelId = raw['channelId'];
    if (channelId is! String || channelId.trim().isEmpty) return null;
    final String trimmedId = channelId.trim();
    final Object? name = raw['name'];
    final String trimmedName = name is String ? name.trim() : '';
    return TGChannel(
      name: trimmedName.isEmpty ? trimmedId : trimmedName,
      channelId: trimmedId,
    );
  }

  /// 编码整表：频道列表 → JSON 数组字符串。
  static String encodeChannels(List<TGChannel> channels) =>
      jsonEncode(channels.map((TGChannel c) => c.toJson()).toList());

  /// 解码整表：JSON 数组字符串 → 频道列表（非法输入 / 缺 id 项容忍跳过）。
  static List<TGChannel> decodeChannels(String? raw) {
    final String text = (raw ?? '').trim();
    if (text.isEmpty) return const <TGChannel>[];
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const <TGChannel>[];
    }
    if (decoded is! List) return const <TGChannel>[];
    final List<TGChannel> out = <TGChannel>[];
    for (final Object? entry in decoded) {
      final TGChannel? channel = TGChannel.fromJson(entry);
      if (channel != null) out.add(channel);
    }
    return out;
  }

  /// 预置常用频道（对齐 iOS `presetChannels`，共 10 个）。
  static const List<TGChannel> presetChannels = <TGChannel>[
    TGChannel(name: 'UC夸克资源', channelId: 'ucquark'),
    TGChannel(name: '夸克分享', channelId: 'quarkshare'),
    TGChannel(name: '阿里分享', channelId: 'shareAliyun'),
    TGChannel(name: '豆儿盘', channelId: 'douerpan'),
    TGChannel(name: '4K影视频道', channelId: 'Aliyun_4K_Movies'),
    TGChannel(name: '百度频道', channelId: 'BaiduCloudDisk'),
    TGChannel(name: '移动云盘', channelId: 'yunpan139'),
    TGChannel(name: '天翼云盘', channelId: 'yunpan189'),
    TGChannel(name: 'UC云盘', channelId: 'yunpanuc'),
    TGChannel(name: '迅雷云盘', channelId: 'yunpanxunlei'),
  ];

  @override
  bool operator ==(Object other) =>
      other is TGChannel &&
      other.name == name &&
      other.channelId == channelId;

  @override
  int get hashCode => Object.hash(name, channelId);

  @override
  String toString() => 'TGChannel($name, $channelId)';
}