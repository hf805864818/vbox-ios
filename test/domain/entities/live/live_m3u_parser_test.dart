/// 领域层单测：LiveTvParser（M3U / TXT 解析 + 动态分类 + 分组合并），
/// 以及 LiveChannel / LiveCategory 模型行为。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/live/live.dart';

void main() {
  group('LiveTvParser.parseM3U', () {
    test('解析 EXTINF 名称 / group-title / tvg-logo / 下一行 URL', () {
      const String m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-logo="http://logo/cctv1.png" group-title="央视",CCTV-1 综合\n'
          'http://stream/cctv1.m3u8\n';
      final List<SubscribeChannel> ch = LiveTvParser.parseM3U(m3u);
      expect(ch.length, 1);
      expect(ch.first.name, 'CCTV-1 综合');
      expect(ch.first.group, '央视');
      expect(ch.first.logo, 'http://logo/cctv1.png');
      expect(ch.first.url, 'http://stream/cctv1.m3u8');
    });

    test('跳过分组标记（** 开头的名称）', () {
      const String m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="新闻",**CCTV**\n'
          '#EXTINF:-1 group-title="新闻",CCTV-13 新闻\n'
          'http://stream/cctv13.m3u8\n';
      final List<SubscribeChannel> ch = LiveTvParser.parseM3U(m3u);
      expect(ch.length, 1);
      expect(ch.first.name, 'CCTV-13 新闻');
    });

    test('无逗号名称时回退 tvg-name', () {
      const String m3u = '#EXTINF:-1 tvg-name="CCTV-2"\n'
          'http://stream/cctv2.m3u8\n';
      final List<SubscribeChannel> ch = LiveTvParser.parseM3U(m3u);
      expect(ch.length, 1);
      expect(ch.first.name, 'CCTV-2');
    });

    test('忽略注释行与中间插入的其他 # 行', () {
      const String m3u = '#EXTM3U\n'
          '#EXTINF:-1,CCTV-5\n'
          '#EXTVLCOPT:http-referrer=http://x\n'
          'http://stream/cctv5.m3u8\n';
      final List<SubscribeChannel> ch = LiveTvParser.parseM3U(m3u);
      expect(ch.length, 1);
      expect(ch.first.url, 'http://stream/cctv5.m3u8');
    });
  });

  group('LiveTvParser.parseTXT', () {
    test('格式A：频道名,url', () {
      final List<SubscribeChannel> ch =
          LiveTvParser.parseTXT('CCTV-1,http://a.m3u8\n');
      expect(ch.length, 1);
      expect(ch.first.name, 'CCTV-1');
      expect(ch.first.url, 'http://a.m3u8');
      expect(ch.first.group, isNull);
    });

    test('格式B：分组名,频道名,url', () {
      final List<SubscribeChannel> ch =
          LiveTvParser.parseTXT('央视,CCTV-1,http://a.m3u8\n');
      expect(ch.length, 1);
      expect(ch.first.group, '央视');
      expect(ch.first.name, 'CCTV-1');
    });

    test('忽略空行与注释行', () {
      final List<SubscribeChannel> ch = LiveTvParser.parseTXT(
        '# 注释\n\n央视,CCTV-1,http://a.m3u8\n',
      );
      expect(ch.length, 1);
    });
  });

  group('LiveTvParser.buildCategories', () {
    test('按分组聚合 + 保持插入顺序 + 组台标取首个有效', () {
      final List<SubscribeChannel> ch = <SubscribeChannel>[
        const SubscribeChannel(
          name: 'CCTV-1',
          url: 'http://a',
          group: '央视',
          logo: 'http://logo/cctv1.png',
        ),
        const SubscribeChannel(
          name: 'CCTV-2',
          url: 'http://b',
          group: '央视',
        ),
        const SubscribeChannel(
          name: '卫视频道',
          url: 'http://c',
          group: '卫视',
        ),
        const SubscribeChannel(name: '无分组台', url: 'http://d'),
      ];
      final List<LiveCategory> cats = LiveTvParser.buildCategories(ch);
      expect(cats.length, 3);
      expect(cats[0].name, '央视');
      expect(cats[0].id, 'cat_0');
      expect(cats[0].logo, 'http://logo/cctv1.png');
      expect(cats[1].name, '卫视');
      expect(cats[2].name, '其他');
    });
  });

  group('LiveTvParser.channelsForGroup', () {
    test('同组同名合并多线路', () {
      final List<SubscribeChannel> ch = <SubscribeChannel>[
        const SubscribeChannel(name: 'CCTV-1', url: 'http://a', group: '央视'),
        const SubscribeChannel(name: 'CCTV-1', url: 'http://b', group: '央视'),
        const SubscribeChannel(name: 'CCTV-2', url: 'http://c', group: '央视'),
      ];
      final List<LiveChannel> out = LiveTvParser.channelsForGroup(ch, '央视');
      expect(out.length, 2);
      expect(out.first.name, 'CCTV-1');
      expect(out.first.routeCount, 2);
      expect(out.first.playURL, 'http://a');
      expect(out.first.routeURL(1), 'http://b');
      expect(out.first.routeURL(99), 'http://b'); // 越界回退最后线路
    });

    test('空分组频道归入「其他」', () {
      final List<SubscribeChannel> ch = <SubscribeChannel>[
        const SubscribeChannel(name: '台', url: 'http://a'),
      ];
      expect(LiveTvParser.channelsForGroup(ch, '其他').length, 1);
      expect(LiveTvParser.channelsForGroup(ch, '央视'), isEmpty);
    });
  });

  group('LiveChannel / LiveCategory', () {
    test('LiveChannel 无线路时 playURL 为空、routeURL 返回 null', () {
      const LiveChannel c = LiveChannel(
        id: 'x',
        name: '台',
        tid: '其他',
        channelId: 'x',
        token: '',
      );
      expect(c.playURL, '');
      expect(c.routeURL(0), isNull);
      expect(c.routeCount, 1);
    });

    test('LiveCategory.paletteIndex：cat_N 取模', () {
      expect(
        const LiveCategory(id: 'cat_3', name: 'x', tid: 'x').paletteIndex,
        3,
      );
      expect(
        const LiveCategory(id: 'cat_0', name: 'x', tid: 'x').paletteIndex,
        0,
      );
    });
  });
}