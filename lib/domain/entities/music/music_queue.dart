/// 领域层：音乐播放队列内核（批次 G · G-01 首段）。
///
/// 对齐基准（唯一真相源）：iOS `AudioPlayerManager`
/// （`vbox/Services/AudioPlayerManager.swift`）。
///
/// 覆盖三块：
/// - [MusicRepeatMode]：播放模式（顺序 / 单曲循环 / 随机），`rawValue` 与 iOS 一致；
/// - [MusicQueueItem]：队列条目，字段 / JSON 键名与 iOS `Codable` 的 `CodingKeys` 1:1；
/// - [MusicQueue]：队列纯逻辑（增删改、上一首 / 下一首索引推导、持久化编解码），
///   不依赖任何平台能力，便于单测与三端共用。
library;

import 'dart:convert';
import 'dart:math' as math;

/// 播放模式（对齐 iOS `MusicRepeatMode`：`sequential=0` / `single=1` / `shuffle=2`）。
enum MusicRepeatMode {
  /// 顺序播放。
  sequential(0, '顺序播放'),

  /// 单曲循环。
  single(1, '单曲循环'),

  /// 随机播放。
  shuffle(2, '随机播放');

  const MusicRepeatMode(this.id, this.displayName);

  /// 归档值（与 iOS `rawValue` 一致）。
  final int id;

  /// 展示名。
  final String displayName;

  /// 归档值 → 枚举（越界回退顺序播放）。
  static MusicRepeatMode fromId(int? id) {
    for (final MusicRepeatMode mode in values) {
      if (mode.id == id) return mode;
    }
    return sequential;
  }

  /// 循环切换到下一档（对齐 iOS 全屏页顶栏按钮的取模切换）。
  MusicRepeatMode get next => values[(index + 1) % values.length];
}

/// 队列条目（对齐 iOS `MusicQueueItem`）。
///
/// 必填字段与 iOS 一致：`id`（vodId）/ `name`（歌名）/ `artist`（来源或歌手）/
/// `coverURL` / `playURL` / `sourceName` / `engineKey`；扩展字段均以可空 / 默认值声明，
/// 反序列化时缺失字段回退缺省值，保证旧存档解码不崩溃（对齐 iOS `decodeIfPresent`）。
class MusicQueueItem {
  const MusicQueueItem({
    required this.id,
    required this.name,
    required this.artist,
    required this.coverURL,
    required this.playURL,
    required this.sourceName,
    required this.engineKey,
    this.quality,
    this.qualityIndex,
    this.lyric,
    this.duration,
    this.albumName,
    this.availQualities = const <String>[],
    this.musicPlatform,
    this.lxMusicInfo,
  });

  /// 歌曲 ID（iOS `id = vodId`）。
  final String id;

  /// 歌名。
  final String name;

  /// 来源 / 歌手（iOS `artist = vodRemarks ?? sourceName`）。
  final String artist;

  /// 封面图。
  final String coverURL;

  /// 播放地址。
  final String playURL;

  /// 源名称。
  final String sourceName;

  /// 引擎 Key。
  final String engineKey;

  /// 音质标识（128k / 320k / flac...）。
  final String? quality;

  /// 当前音质在 [availQualities] 中的下标（归档用）。
  final int? qualityIndex;

  /// LRC 歌词文本。
  final String? lyric;

  /// 时长（秒）。
  final int? duration;

  /// 专辑名。
  final String? albumName;

  /// 可选音质档位。
  final List<String> availQualities;

  /// lx 歌曲归属平台。
  final String? musicPlatform;

  /// lx 原始 musicInfo（音质切换重新走 `musicUrl` 时透传给插件）。
  final String? lxMusicInfo;

  /// 复制构造（对齐 iOS `init(copying:)`）：保留除 [playURL] / [quality] 外全部字段，
  /// 供音质切换在保留播放进度的同时无缝替换直链。
  MusicQueueItem copying({required String playURL, String? quality}) {
    return MusicQueueItem(
      id: id,
      name: name,
      artist: artist,
      coverURL: coverURL,
      playURL: playURL,
      sourceName: sourceName,
      engineKey: engineKey,
      quality: quality,
      qualityIndex: qualityIndex,
      lyric: lyric,
      duration: duration,
      albumName: albumName,
      availQualities: availQualities,
      musicPlatform: musicPlatform,
      lxMusicInfo: lxMusicInfo,
    );
  }

  /// 局部更新。
  MusicQueueItem copyWith({
    String? id,
    String? name,
    String? artist,
    String? coverURL,
    String? playURL,
    String? sourceName,
    String? engineKey,
    String? quality,
    int? qualityIndex,
    String? lyric,
    int? duration,
    String? albumName,
    List<String>? availQualities,
    String? musicPlatform,
    String? lxMusicInfo,
  }) {
    return MusicQueueItem(
      id: id ?? this.id,
      name: name ?? this.name,
      artist: artist ?? this.artist,
      coverURL: coverURL ?? this.coverURL,
      playURL: playURL ?? this.playURL,
      sourceName: sourceName ?? this.sourceName,
      engineKey: engineKey ?? this.engineKey,
      quality: quality ?? this.quality,
      qualityIndex: qualityIndex ?? this.qualityIndex,
      lyric: lyric ?? this.lyric,
      duration: duration ?? this.duration,
      albumName: albumName ?? this.albumName,
      availQualities: availQualities ?? this.availQualities,
      musicPlatform: musicPlatform ?? this.musicPlatform,
      lxMusicInfo: lxMusicInfo ?? this.lxMusicInfo,
    );
  }

  /// 序列化（键名与 iOS `CodingKeys` 一致，可空字段缺省不写）。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'artist': artist,
      'coverURL': coverURL,
      'playURL': playURL,
      'sourceName': sourceName,
      'engineKey': engineKey,
      if (quality != null) 'quality': quality,
      if (qualityIndex != null) 'qualityIndex': qualityIndex,
      if (lyric != null) 'lyric': lyric,
      if (duration != null) 'duration': duration,
      if (albumName != null) 'albumName': albumName,
      'availQualities': availQualities,
      if (musicPlatform != null) 'musicPlatform': musicPlatform,
      if (lxMusicInfo != null) 'lxMusicInfo': lxMusicInfo,
    };
  }

  /// 反序列化（缺失 / 类型不符字段回退缺省值，对齐 iOS `decodeIfPresent`）。
  static MusicQueueItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return MusicQueueItem(
      id: id,
      name: _asString(raw['name']),
      artist: _asString(raw['artist']),
      coverURL: _asString(raw['coverURL']),
      playURL: _asString(raw['playURL']),
      sourceName: _asString(raw['sourceName']),
      engineKey: _asString(raw['engineKey']),
      quality: raw['quality'] is String ? raw['quality'] as String : null,
      qualityIndex: raw['qualityIndex'] is int ? raw['qualityIndex'] as int : null,
      lyric: raw['lyric'] is String ? raw['lyric'] as String : null,
      duration: raw['duration'] is int ? raw['duration'] as int : null,
      albumName: raw['albumName'] is String ? raw['albumName'] as String : null,
      availQualities: _asStringList(raw['availQualities']),
      musicPlatform:
          raw['musicPlatform'] is String ? raw['musicPlatform'] as String : null,
      lxMusicInfo: raw['lxMusicInfo'] is String ? raw['lxMusicInfo'] as String : null,
    );
  }

  static String _asString(Object? value) => value is String ? value : '';

  static List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return value.whereType<String>().toList(growable: false);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicQueueItem &&
        other.id == id &&
        other.name == name &&
        other.artist == artist &&
        other.coverURL == coverURL &&
        other.playURL == playURL &&
        other.sourceName == sourceName &&
        other.engineKey == engineKey &&
        other.quality == quality &&
        other.qualityIndex == qualityIndex &&
        other.lyric == lyric &&
        other.duration == duration &&
        other.albumName == albumName &&
        _listEquals(other.availQualities, availQualities) &&
        other.musicPlatform == musicPlatform &&
        other.lxMusicInfo == lxMusicInfo;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        artist,
        coverURL,
        playURL,
        sourceName,
        engineKey,
        quality,
        qualityIndex,
        lyric,
        duration,
        albumName,
        Object.hashAll(availQualities),
        musicPlatform,
        lxMusicInfo,
      );

  @override
  String toString() => 'MusicQueueItem($id, $name)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 音乐播放队列（对齐 iOS `AudioPlayerManager` 的 `queue` + `currentIndex` 状态）。
///
/// 不可变值对象：所有变更方法返回新实例，便于状态管理与单测。
class MusicQueue {
  const MusicQueue({this.items = const <MusicQueueItem>[], this.currentIndex = -1});

  /// 空队列。
  static const MusicQueue empty = MusicQueue();

  /// 队列条目。
  final List<MusicQueueItem> items;

  /// 当前下标（空队列为 -1）。
  final int currentIndex;

  /// 队列是否为空。
  bool get isEmpty => items.isEmpty;

  /// 队列是否非空。
  bool get isNotEmpty => items.isNotEmpty;

  /// 队列长度。
  int get length => items.length;

  /// 是否有可恢复的播放队列（非空即视为可恢复）。
  bool get hasRestorable => items.isNotEmpty;

  /// 当前曲目（下标越界返回 null，对齐 iOS `currentSong`）。
  MusicQueueItem? get current {
    if (currentIndex < 0 || currentIndex >= items.length) return null;
    return items[currentIndex];
  }

  /// 全量替换队列并定位起始下标（对齐 iOS `setQueue` / `playQueue`）。
  MusicQueue setQueue(List<MusicQueueItem> items, {int startIndex = 0}) {
    return MusicQueue(
      items: List<MusicQueueItem>.unmodifiable(items),
      currentIndex: _clampIndex(startIndex, items.length),
    );
  }

  /// 追加一首（对齐 iOS `addToQueue`：不改变当前下标）。
  MusicQueue addToQueue(MusicQueueItem item) {
    final List<MusicQueueItem> next = <MusicQueueItem>[...items, item];
    return MusicQueue(
      items: List<MusicQueueItem>.unmodifiable(next),
      currentIndex: currentIndex,
    );
  }

  /// 播放某首（对齐 iOS `play(item:)`）：队列中无此曲则追加并定位到末尾，
  /// 否则定位到首个同 id 曲目。
  MusicQueue play(MusicQueueItem item) {
    final int existing = items.indexWhere((MusicQueueItem e) => e.id == item.id);
    if (existing >= 0) {
      return MusicQueue(items: items, currentIndex: existing);
    }
    final List<MusicQueueItem> next = <MusicQueueItem>[...items, item];
    return MusicQueue(
      items: List<MusicQueueItem>.unmodifiable(next),
      currentIndex: next.length - 1,
    );
  }

  /// 移除某下标（对齐 iOS `removeFromQueue(at:)`）：
  /// - 下标越界 → 原样返回；
  /// - 移除项在当前项之前 → 当前下标前移 1；
  /// - 移除项即当前项 → 触发 `stop()` 语义：**队列整体清空**（对齐 iOS 的 stop 行为）。
  MusicQueue removeFromQueue(int index) {
    if (index < 0 || index >= items.length) return this;
    if (index == currentIndex) return MusicQueue.empty;
    final List<MusicQueueItem> next = <MusicQueueItem>[...items]..removeAt(index);
    return MusicQueue(
      items: List<MusicQueueItem>.unmodifiable(next),
      currentIndex: index < currentIndex ? currentIndex - 1 : currentIndex,
    );
  }

  /// 替换某下标条目（音质切换用，保持下标不变）。
  MusicQueue replaceAt(int index, MusicQueueItem item) {
    if (index < 0 || index >= items.length) return this;
    final List<MusicQueueItem> next = <MusicQueueItem>[...items]..[index] = item;
    return MusicQueue(
      items: List<MusicQueueItem>.unmodifiable(next),
      currentIndex: currentIndex,
    );
  }

  /// 定位到某下标（越界收敛）。
  MusicQueue withCurrentIndex(int index) {
    return MusicQueue(
      items: items,
      currentIndex: _clampIndex(index, items.length),
    );
  }

  /// 清空（对齐 iOS `stop()` 的队列清理）。
  MusicQueue cleared() => MusicQueue.empty;

  /// 「下一首」目标下标（对齐 iOS `playNext`）：
  /// - 空队列 → null；
  /// - 单曲循环 → 当前下标（重播）；
  /// - 随机 → 随机下标（可注入 [randomInt] 便于单测）；
  /// - 顺序 → `(currentIndex + 1) % length`。
  int? nextIndex(MusicRepeatMode mode, {int Function(int max)? randomInt}) {
    if (items.isEmpty) return null;
    switch (mode) {
      case MusicRepeatMode.single:
        return currentIndex < 0 ? 0 : currentIndex;
      case MusicRepeatMode.shuffle:
        return _randomIndex(randomInt);
      case MusicRepeatMode.sequential:
        if (currentIndex < 0) return 0;
        return (currentIndex + 1) % items.length;
    }
  }

  /// 「上一首」目标下标（对齐 iOS `playPrevious` 的 `currentTime <= 3` 分支之后）。
  int? previousIndex(MusicRepeatMode mode, {int Function(int max)? randomInt}) {
    if (items.isEmpty) return null;
    if (mode == MusicRepeatMode.shuffle) return _randomIndex(randomInt);
    if (currentIndex < 0) return 0;
    return (currentIndex - 1 + items.length) % items.length;
  }

  /// 持久化：队列 → JSON 数组字符串（键名对齐 iOS `CodingKeys`）。
  String encodeItems() {
    return jsonEncode(
      items.map((MusicQueueItem e) => e.toJson()).toList(growable: false),
    );
  }

  /// 反序列化：JSON 数组字符串 → 条目列表（非法输入 / 缺 id 项容忍跳过）。
  static List<MusicQueueItem> decodeItems(String? raw) {
    final String text = (raw ?? '').trim();
    if (text.isEmpty) return const <MusicQueueItem>[];
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const <MusicQueueItem>[];
    }
    if (decoded is! List) return const <MusicQueueItem>[];
    final List<MusicQueueItem> out = <MusicQueueItem>[];
    for (final Object? entry in decoded) {
      final MusicQueueItem? item = MusicQueueItem.fromJson(entry);
      if (item != null) out.add(item);
    }
    return out;
  }

  int _randomIndex(int Function(int max)? randomInt) {
    if (items.length <= 1) return 0;
    if (randomInt != null) return randomInt(items.length).clamp(0, items.length - 1);
    return math.Random().nextInt(items.length);
  }

  /// 下标收敛：空列表 → -1，否则钳制到 `[0, length)`。
  static int _clampIndex(int index, int length) {
    if (length <= 0) return -1;
    if (index < 0) return 0;
    if (index >= length) return length - 1;
    return index;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicQueue &&
        other.currentIndex == currentIndex &&
        other.items.length == items.length &&
        _listEquals(other.items, items);
  }

  @override
  int get hashCode => Object.hash(currentIndex, Object.hashAll(items));

  @override
  String toString() => 'MusicQueue(${items.length} 首, 当前 $currentIndex)';

  static bool _listEquals(List<MusicQueueItem> a, List<MusicQueueItem> b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
