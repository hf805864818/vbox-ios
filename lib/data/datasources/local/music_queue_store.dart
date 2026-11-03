/// 数据层：音乐播放队列持久化（批次 G · G-01 首段）。
///
/// 对齐 iOS `AudioPlayerManager` 的阶段四持久化
/// （`vbox/Services/AudioPlayerManager.swift:588` `saveQueue` / `restoreQueue`）：
/// - `music_queue_items`（string）：队列 JSON 数组字符串；
/// - `music_queue_index`（int）：当前下标。
///
/// 两键走契约 `prefs_keys_v1.json`（`_group_music`）→ `UserDefaults`，
/// Flutter 端经 [PrefsManager] 落 `SharedPreferences`。
library;

import '../../../domain/entities/music/music.dart';
import 'prefs_manager.dart';

/// 音乐队列存储。
class MusicQueueStore {
  /// 构造（注入契约偏好管理器）。
  MusicQueueStore(this._prefs);

  final PrefsManager _prefs;

  /// 契约键名（`prefs_keys_v1.json` → `_group_music`）。
  static const String itemsKey = 'music_queue_items';
  static const String indexKey = 'music_queue_index';

  /// 全部契约键（顺序与契约一致）。
  static const List<String> allKeys = <String>[indexKey, itemsKey];

  /// 读取队列（无存档 → 空队列；下标越界 → 收敛）。
  Future<MusicQueue> load() async {
    final String raw = await _prefs.getString(itemsKey);
    final List<MusicQueueItem> items = MusicQueue.decodeItems(raw);
    if (items.isEmpty) return MusicQueue.empty;
    final int index = await _prefs.getInt(indexKey);
    return MusicQueue(items: List<MusicQueueItem>.unmodifiable(items))
        .withCurrentIndex(index);
  }

  /// 写入队列（对齐 iOS `saveQueue`：空队列移除两键，使浮层自动隐藏）。
  Future<void> save(MusicQueue queue) async {
    if (queue.isEmpty) {
      await clear();
      return;
    }
    await _prefs.set(itemsKey, queue.encodeItems());
    await _prefs.set(indexKey, queue.currentIndex);
  }

  /// 清空存档（移除两键）。
  Future<void> clear() async {
    for (final String key in allKeys) {
      await _prefs.remove(key);
    }
  }

  /// 是否存在可恢复的队列（对齐 iOS `hasRestorableQueue`）。
  Future<bool> hasRestorable() async {
    final String raw = await _prefs.getString(itemsKey);
    return MusicQueue.decodeItems(raw).isNotEmpty;
  }
}
