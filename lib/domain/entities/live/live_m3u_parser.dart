/// 领域层：M3U / TXT 直播源解析器。
///
/// 对齐 iOS `LiveTVService.parseM3U` / `.parseTXT` / `.buildDynamicCategories`。
/// 纯函数、无 IO，便于单测。
library;

import 'live_channel.dart';

/// M3U / TXT 直播源解析器。
class LiveTvParser {
  LiveTvParser._();

  static final RegExp _groupTitleRe = RegExp(r'group-title="([^"]*)"');
  static final RegExp _tvgLogoRe = RegExp(r'tvg-logo="([^"]*)"');
  static final RegExp _tvgNameRe = RegExp(r'tvg-name="([^"]*)"');

  /// 解析 M3U 格式直播源内容。
  static List<SubscribeChannel> parseM3U(String content) {
    final List<SubscribeChannel> channels = <SubscribeChannel>[];
    final List<String> lines = content.split(RegExp(r'\r?\n'));
    int i = 0;
    while (i < lines.length) {
      final String line = lines[i].trim();
      if (!line.startsWith('#EXTINF:')) {
        i += 1;
        continue;
      }

      String name = '';
      String? group;
      String? logo;

      final RegExpMatch? groupMatch = _groupTitleRe.firstMatch(line);
      if (groupMatch != null) group = groupMatch.group(1);

      final RegExpMatch? logoMatch = _tvgLogoRe.firstMatch(line);
      if (logoMatch != null) logo = logoMatch.group(1);

      final int commaIndex = line.lastIndexOf(',');
      if (commaIndex >= 0) {
        name = line.substring(commaIndex + 1).trim();
      }
      if (name.isEmpty) {
        final RegExpMatch? nameMatch = _tvgNameRe.firstMatch(line);
        if (nameMatch != null) name = (nameMatch.group(1) ?? '').trim();
      }

      // 跳过分组标记（以 ** 开头的名称，如 **NOTÍCIAS**）。
      i += 1;
      if (name.startsWith('**')) {
        continue;
      }

      // 定位紧邻 URL：跳过 EXTINF 之后的空行与其他 `#` 注释行
      // （如 #EXTVLCOPT:...），对齐 iOS 解析语义。
      while (i < lines.length) {
        final String urlLine = lines[i].trim();
        if (urlLine.isNotEmpty && !urlLine.startsWith('#')) {
          channels.add(SubscribeChannel(
            name: name.isEmpty ? '未知频道' : name,
            url: urlLine,
            group: group,
            logo: logo,
          ));
          break;
        }
        i += 1;
      }
    }
    return channels;
  }

  /// 解析 TXT 格式直播源内容。
  ///
  /// 格式A：`频道名,http://xxx.m3u8`
  /// 格式B：`分组名,频道名,http://xxx.m3u8`
  static List<SubscribeChannel> parseTXT(String content) {
    final List<SubscribeChannel> channels = <SubscribeChannel>[];
    final List<String> lines = content.split(RegExp(r'\r?\n'));

    for (final String raw in lines) {
      final String trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final List<String> parts = trimmed.split(',');
      if (parts.length == 2) {
        final String name = parts[0].trim();
        final String url = parts[1].trim();
        if (name.isNotEmpty && url.isNotEmpty) {
          channels.add(SubscribeChannel(name: name, url: url));
        }
      } else if (parts.length >= 3) {
        final String group = parts[0].trim();
        final String name = parts[1].trim();
        final String url = parts[2].trim();
        if (name.isNotEmpty && url.isNotEmpty) {
          channels.add(SubscribeChannel(
            name: name,
            url: url,
            group: group.isEmpty ? null : group,
          ));
        }
      }
    }
    return channels;
  }

  /// 从订阅频道提取唯一分组，生成动态分类。
  static List<LiveCategory> buildCategories(List<SubscribeChannel> channels) {
    final Map<String, List<SubscribeChannel>> groupMap =
        <String, List<SubscribeChannel>>{};
    final Map<String, String?> firstLogo = <String, String?>{};
    final List<String> insertionOrder = <String>[];

    for (final SubscribeChannel ch in channels) {
      final String groupName = ch.group ?? '其他';
      if (!groupMap.containsKey(groupName)) {
        insertionOrder.add(groupName);
        groupMap[groupName] = <SubscribeChannel>[];
        firstLogo[groupName] = null;
      }
      groupMap[groupName]!.add(ch);
      if (firstLogo[groupName] == null &&
          ch.logo != null &&
          ch.logo!.isNotEmpty) {
        firstLogo[groupName] = ch.logo;
      }
    }

    final List<LiveCategory> categories = <LiveCategory>[];
    for (int index = 0; index < insertionOrder.length; index++) {
      final String groupName = insertionOrder[index];
      categories.add(LiveCategory(
        id: 'cat_$index',
        name: groupName,
        tid: groupName,
        logo: firstLogo[groupName],
      ));
    }
    return categories;
  }

  /// 按分组名过滤并按频道名合并多线路（对齐 iOS `fetchChannelsForGroup`）。
  static List<LiveChannel> channelsForGroup(
    List<SubscribeChannel> channels,
    String groupName,
  ) {
    final List<SubscribeChannel> filtered =
        channels.where((SubscribeChannel ch) {
      final String? group = ch.group;
      if (group == null) return groupName == '其他';
      return group == groupName;
    }).toList(growable: false);

    final Map<String, List<String>> sourcesMap = <String, List<String>>{};
    final Map<String, String?> logoMap = <String, String?>{};
    final Map<String, String> firstUrl = <String, String>{};
    final List<String> order = <String>[];

    for (final SubscribeChannel ch in filtered) {
      if (!sourcesMap.containsKey(ch.name)) {
        order.add(ch.name);
        sourcesMap[ch.name] = <String>[];
        logoMap[ch.name] = null;
        firstUrl[ch.name] = ch.url;
      }
      sourcesMap[ch.name]!.add(ch.url);
      if (logoMap[ch.name] == null && ch.logo != null && ch.logo!.isNotEmpty) {
        logoMap[ch.name] = ch.logo;
      }
    }

    return order.map((String name) {
      return LiveChannel(
        id: 'sub_${name}_${firstUrl[name]}',
        name: name,
        tid: groupName,
        channelId: firstUrl[name]!,
        token: '',
        logo: logoMap[name],
        sources: List<String>.unmodifiable(sourcesMap[name]!),
      );
    }).toList(growable: false);
  }
}