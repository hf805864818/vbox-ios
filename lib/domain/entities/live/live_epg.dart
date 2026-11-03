/// 领域层：EPG（电子节目单）。
///
/// 对齐 iOS `LiveTVService.parseEPG` ：解析回看/节目单文本中的
/// `[HH:mm 节目名]`，时间 + 标题两列展示，标题去掉「回看」后缀。
///
/// 纯解析无 IO，便于单测（验收口径「数据正确」）。
library;

/// EPG 日期档位（对齐 iOS `EPGSheetView.dayOptions`）。
enum EpgDay {
  /// 今天。
  today('today', '今天'),

  /// 昨天。
  yesterday('yesterday', '昨天'),

  /// 前天。
  beforeYesterday('beforeyesterday', '前天');

  const EpgDay(this.id, this.label);

  /// 契约字符串值（对齐 iOS 用 `today` / `yesterday` / `beforeyesterday`）。
  final String id;

  /// 展示名。
  final String label;
}

/// 单条节目（时间 + 标题）。
class EpgProgram {
  const EpgProgram({required this.time, required this.title});

  /// 播出时间（`HH:mm`）。
  final String time;

  /// 节目名（已去掉「回看」）。
  final String title;

  @override
  bool operator ==(Object other) =>
      other is EpgProgram && other.time == time && other.title == title;

  @override
  int get hashCode => Object.hash(time, title);

  @override
  String toString() => 'EpgProgram($time $title)';
}

/// EPG 文本解析器。
class LiveEpgParser {
  LiveEpgParser._();

  /// 匹配 `[00:17 今日说法回看]`（对齐 iOS `parseEPG` 正则）。
  static final RegExp _programRe = RegExp(r'\[(\d{2}:\d{2})\s+([^\]]+)\]');

  /// 解析节目单文本为节目列表（顺序即出现顺序）。
  static List<EpgProgram> parseEpg(String html) {
    final List<EpgProgram> programs = <EpgProgram>[];
    for (final RegExpMatch match in _programRe.allMatches(html)) {
      final String time = match.group(1) ?? '';
      final String rawTitle = match.group(2) ?? '';
      final String title = rawTitle.replaceAll('回看', '').trim();
      if (time.isEmpty || title.isEmpty) continue;
      programs.add(EpgProgram(time: time, title: title));
    }
    return programs;
  }
}