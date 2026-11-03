/// 批次 C · C-08：字幕解析（SRT / WebVTT / ASS）+ 轨道时间查询。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/subtitle_parser.dart';

void main() {
  group('SubtitleParser.sniff', () {
    test('WEBVTT 头 → vtt', () {
      expect(SubtitleParser.sniff('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx'),
          SubtitleFormat.vtt);
    });

    test('[Script Info] → ass', () {
      expect(SubtitleParser.sniff('[Script Info]\nTitle: x'), SubtitleFormat.ass);
    });

    test('编号+时间行 → srt', () {
      expect(SubtitleParser.sniff('1\n00:00:01,000 --> 00:00:02,000\nx'),
          SubtitleFormat.srt);
    });

    test('无法识别 → null', () {
      expect(SubtitleParser.sniff('随便一段文本'), isNull);
    });
  });

  group('SubtitleParser.parseSrt', () {
    const String srt = '''
1
00:00:01,000 --> 00:00:03,500
第一行
第二行

2
00:00:05,200 --> 00:00:06,000
Hello

3
00:00:08,000 --> 00:00:09,000
No index line
''';

    test('解析 3 条（含无编号块）', () {
      final List<SubtitleCue> cues = SubtitleParser.parseSrt(srt);
      expect(cues, hasLength(3));
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 3500);
      expect(cues[0].text, '第一行\n第二行');
      expect(cues[1].startMs, 5200);
      expect(cues[2].text, 'No index line');
    });

    test('非法块被忽略', () {
      expect(SubtitleParser.parseSrt('垃圾文本\n\n00:00:01,000 --> 00:00:02,000\n'),
          isEmpty);
    });
  });

  group('SubtitleParser.parseVtt', () {
    const String vtt = '''
WEBVTT

NOTE 备注行

00:00:01.500 --> 00:00:02.500 align:start
你好

00:00:03.000 --> 00:00:04.000
world
''';

    test('解析 2 条，忽略头部与备注', () {
      final List<SubtitleCue> cues = SubtitleParser.parseVtt(vtt);
      expect(cues, hasLength(2));
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 2500);
      expect(cues[0].text, '你好');
      expect(cues[1].text, 'world');
    });
  });

  group('SubtitleParser.parseAss', () {
    const String ass = '''
[Script Info]
Title: demo

[V4+ Styles]

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,Alice,0,0,20,,Hello \\N世界
Dialogue: 0,0:00:05.50,0:00:06.00,Default,,0,0,0,,尾行
''';

    test('解析 2 条 Dialogue（时间厘秒、\\N 换行）', () {
      final List<SubtitleCue> cues = SubtitleParser.parseAss(ass);
      expect(cues, hasLength(2));
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 3000);
      expect(cues[0].text, 'Hello \n世界');
      expect(cues[0].position, contains('style=Default'));
      expect(cues[1].startMs, 5500);
    });

    test('Events 段之外不解析', () {
      const String bad = '[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,,,0,0,0,,ok\n';
      expect(SubtitleParser.parseAss('[Script Info]\n$bad').length, 1);
      expect(SubtitleParser.parseAss('Dialogue: 0,0:00:01.00,0:00:02.00,,,0,0,0,,x'),
          isEmpty);
    });
  });

  group('SubtitleTrack.cueAt', () {
    final SubtitleTrack track = SubtitleTrack.parse('''
1
00:00:01,000 --> 00:00:03,000
A

2
00:00:05,000 --> 00:00:07,000
B
''');

    test('区间内命中 / 间隙为空 / 区间外为空', () {
      expect(track.cueAt(0), isNull);
      expect(track.cueAt(1000)?.text, 'A');
      expect(track.cueAt(2999)?.text, 'A');
      expect(track.cueAt(3000), isNull); // 边界：end 不包含
      expect(track.cueAt(4000), isNull);
      expect(track.cueAt(5000)?.text, 'B');
      expect(track.cueAt(10000), isNull);
    });

    test('parseAuto 自动嗅探 SRT', () {
      final SubtitleTrack t = SubtitleTrack.parse('1\n00:00:01,000 --> 00:00:02,000\nx');
      expect(t.cues, hasLength(1));
      expect(t.durationMs, 2000);
    });
  });

  group('P-芯4 / P-芯5：SSA 识别 / 样式剥离 / 字节解码', () {
    test('SSA [V4 Styles] → 识别为 ass 并可解析', () {
      const String ssa = '[Script Info]\n[V4 Styles]\n\n[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,正文\n';
      expect(SubtitleParser.sniff(ssa), SubtitleFormat.ass);
      expect(SubtitleParser.parseAss(ssa).single.text, '正文');
    });

    test('cleanAssText：剥离 {\\...} 样式标签 + \\h → 空格', () {
      expect(SubtitleParser.cleanAssText(r'{\an8}{\pos(10,20)}你好\h世界'), '你好 世界');
    });

    test('parseBytes：UTF-16 LE BOM 解码后解析', () {
      const String srt = '1\n00:00:01,000 --> 00:00:02,000\nhello';
      final List<int> raw = <int>[0xFF, 0xFE];
      for (final int u in srt.codeUnits) {
        raw..add(u & 0xFF)..add((u >> 8) & 0xFF);
      }
      final List<SubtitleCue> cues =
          SubtitleParser.parseBytes(Uint8List.fromList(raw));
      expect(cues, hasLength(1));
      expect(cues.single.text, 'hello');
    });

    test('parseBytes：UTF-8 BOM', () {
      final List<int> raw = <int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nx'),
      ];
      expect(
        SubtitleParser.parseBytes(Uint8List.fromList(raw)).single.text,
        'x',
      );
    });

    test('parseBytes：空字节 → 空结果', () {
      expect(SubtitleParser.parseBytes(Uint8List(0)), isEmpty);
    });
  });
}
