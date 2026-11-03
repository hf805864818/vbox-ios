/// 批次 C · C-03：弹幕解析（Bilibili XML / JSON）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/danmaku/danmaku_item.dart';
import 'package:vbox/platform/player/danmaku/danmaku_parser.dart';

void main() {
  group('DanmakuParser.parseBilibiliXml', () {
    const String xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<i>
  <chatserver>chat.bilibili.com</chatserver>
  <d p="1.50,1,25,16777215,1700000000,0,user1,12345">第一&nbsp;条弹幕</d>
  <d p="3.20,5,18,16711680,1700000001,0,user2,67890">顶部弹幕&amp;测试</d>
  <d p="5.00,4,25,255,1700000002,0,user3,111">底部弹幕</d>
</i>
''';

    test('解析 3 条：模式 / 颜色 / 时间 / 文本转义', () {
      final List<DanmakuItem> items = DanmakuParser.parseBilibiliXml(xml);
      expect(items, hasLength(3));

      expect(items[0].timeMs, 1500);
      expect(items[0].mode, DanmakuMode.scroll);
      expect(items[0].color, 0xFFFFFFFF);
      expect(items[0].content, '第一 条弹幕');

      expect(items[1].mode, DanmakuMode.top);
      expect(items[1].color, 0xFFFF0000);
      expect(items[1].content, '顶部弹幕&测试');
      expect(items[1].sizePx, greaterThan(0));

      expect(items[2].mode, DanmakuMode.bottom);
      expect(items[2].color, 0xFF0000FF);
      expect(items[2].content, '底部弹幕');
    });

    test('空文本 / 时间非法 → 丢弃', () {
      const String bad =
          '<i><d p="abc,1,25,255">x</d><d p="1.0,1,25,255">  </d></i>';
      expect(DanmakuParser.parseBilibiliXml(bad), isEmpty);
    });
  });

  group('DanmakuParser.parseJson', () {
    test('数组：time/text/color/mode 字段兼容', () {
      const String json =
          '[{"time":1.2,"text":"你好","color":16711680,"mode":1},{"t":2.5,"m":"第二","colour":255,"mode":5}]';
      final List<DanmakuItem> items = DanmakuParser.parseJson(json);
      expect(items, hasLength(2));
      expect(items[0].timeMs, 1200);
      expect(items[0].content, '你好');
      expect(items[0].color, 0xFFFF0000);
      expect(items[0].mode, DanmakuMode.scroll);
      expect(items[1].mode, DanmakuMode.top);
      expect(items[1].color, 0xFF0000FF);
    });

    test('单对象也可解析', () {
      const String json = '{"time":0.5,"text":"single"}';
      final List<DanmakuItem> items = DanmakuParser.parseJson(json);
      expect(items, hasLength(1));
      expect(items.single.timeMs, 500);
    });

    test('缺少时间/文本 → 丢弃；非法 JSON → 空', () {
      expect(DanmakuParser.parseJson('[{"time":1.0}]'), isEmpty);
      expect(DanmakuParser.parseJson('not json'), isEmpty);
    });
  });

  group('DanmakuParser.parse 自动嗅探', () {
    test('XML 与 JSON 均可，其余为空', () {
      expect(DanmakuParser.parse('<d p="1,1,25,255">x</d>'), hasLength(1));
      expect(DanmakuParser.parse('[{"time":1,"text":"x"}]'), hasLength(1));
      expect(DanmakuParser.parse(''), isEmpty);
      expect(DanmakuParser.parse('garbage'), isEmpty);
    });
  });
}
