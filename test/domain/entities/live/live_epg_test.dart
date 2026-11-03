/// 领域层单测：LiveEpgParser（EPG 文本解析）与 EpgDay 契约值。
///
/// 验收口径「数据正确」：`[HH:mm 标题]` 解析出时间 + 标题，标题去掉「回看」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/live/live.dart';

void main() {
  group('LiveEpgParser.parseEpg', () {
    test('解析 [HH:mm 标题] 并去掉「回看」后缀', () {
      const String html = '[00:17 今日说法回看]\n[01:02 新闻联播]';
      final List<EpgProgram> programs = LiveEpgParser.parseEpg(html);

      expect(programs.length, 2);
      expect(programs[0], const EpgProgram(time: '00:17', title: '今日说法'));
      expect(programs[1], const EpgProgram(time: '01:02', title: '新闻联播'));
    });

    test('标题中含「回看」字样一并去除并 trim', () {
      const String html = '[09:30 回看测试回看]';
      final List<EpgProgram> programs = LiveEpgParser.parseEpg(html);

      expect(programs.length, 1);
      expect(programs[0].title, '测试');
    });

    test('无匹配或空标题时返回空', () {
      expect(LiveEpgParser.parseEpg('暂无节目单'), isEmpty);
      expect(LiveEpgParser.parseEpg('[00:00 ]'), isEmpty);
      expect(LiveEpgParser.parseEpg(''), isEmpty);
    });
  });

  group('EpgDay', () {
    test('契约值对齐 iOS dayOptions（today/yesterday/beforeyesterday）', () {
      expect(EpgDay.today.id, 'today');
      expect(EpgDay.yesterday.id, 'yesterday');
      expect(EpgDay.beforeYesterday.id, 'beforeyesterday');
      expect(EpgDay.today.label, '今天');
      expect(EpgDay.yesterday.label, '昨天');
      expect(EpgDay.beforeYesterday.label, '前天');
    });
  });
}