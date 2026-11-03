/// 音乐源识别（对齐 iOS `SpiderManager.isMusicEngineKey(_:)` +
/// `fetchAllSourceDisplayItems()` 的宽判定）。
///
/// 语义：音乐源只服务于「网络音乐」页，**不应**出现在视频「切换源」列表中，
/// 也**不参与**普通视频搜索（iOS `searchStream` 中 JS 蜘蛛通道显式过滤
/// `musicEngineKeys`）。
library;

import '../entities/spider/site_config.dart';

/// 引擎 key / 站点 key 是否为音乐源。
///
/// 对齐 iOS：`musicai*` / `musicaid*` / `nodejs_musicai*` 前缀。
bool isMusicSourceKey(String key) {
  final String k = key.trim().toLowerCase();
  if (k.isEmpty) return false;
  return k.startsWith('musicai') ||
      k.startsWith('musicaid') ||
      k.startsWith('nodejs_musicai');
}

/// 站点配置是否为音乐源。
///
/// 对齐 iOS `fetchAllSourceDisplayItems()` 的判定：key 前缀命中，或
/// `group == "music"`，或 api 含 `MusicAi`（不区分大小写）。
bool isMusicSite(SiteConfig site) {
  if (isMusicSourceKey(site.key)) return true;
  if (site.group == 'music') return true;
  final String api = (site.api ?? '').toLowerCase();
  return api.contains('musicaid');
}