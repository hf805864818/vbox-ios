/// 直播导入/导出纯逻辑单测（批次 E · E-04）。
///
/// 覆盖 M3U/TXT 自动判定解析、导出文件名安全化；落盘/分享的 IO 由
/// widget 层注入 fake 覆盖（见 live_source_management_test.dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/pages/live/import_export.dart';

void main() {
  group('LiveSourceImportExport.parseContent', () {
    test('EXTM3U 前缀走 M3U 解析', () {
      const String m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="央视",CCTV-1\n'
          'http://a.m3u8\n';
      final channels = LiveSourceImportExport.parseContent(m3u);
      expect(channels, hasLength(1));
      expect(channels.first.name, 'CCTV-1');
    });

    test('非 EXTM3U 前缀走 TXT 解析（两段/三段）', () {
      final two = LiveSourceImportExport.parseContent(
        'CCTV-1,http://a.m3u8\n',
      );
      expect(two, hasLength(1));
      expect(two.first.group, isNull);

      final three = LiveSourceImportExport.parseContent(
        '央视,CCTV-1,http://a.m3u8\n',
      );
      expect(three.first.group, '央视');
    });

    test('空内容返回空列表', () {
      expect(LiveSourceImportExport.parseContent('  \n '), isEmpty);
    });
  });

  group('LiveSourceImportExport.exportFileName', () {
    test('M3U 扩展名 + 路径分隔符/空格替换', () {
      expect(
        LiveSourceImportExport.exportFileName('我的 源/一', isM3U: true),
        '我的_源_一.m3u',
      );
    });

    test('TXT 扩展名 + 反斜杠替换', () {
      expect(
        LiveSourceImportExport.exportFileName('a b\\c', isM3U: false),
        'a_b_c.txt',
      );
    });
  });
}