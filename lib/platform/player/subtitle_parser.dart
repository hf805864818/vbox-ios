/// 平台层：字幕解析 + 轨道查询（批次 C · C-08）。
///
/// 支持 SRT / WebVTT / ASS 三种格式解析，[SubtitleTrack] 按时间二分查找
/// 当前应显示的字幕（对齐 iOS `SubtitleParser` + `SubtitleTrack` 语义）。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// 字幕格式。
enum SubtitleFormat { srt, vtt, ass }

/// 单条字幕（时间区间 + 文本 + 可选定位提示）。
class SubtitleCue {
  /// 构造。
  const SubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.position,
  });

  /// 开始时间（毫秒）。
  final int startMs;

  /// 结束时间（毫秒）。
  final int endMs;

  /// 字幕文本（多行用 `\n` 连接）。
  final String text;

  /// ASS 定位提示（`Alignment` / `MarginV` 等原始字段，可选）。
  final String? position;

  /// 是否覆盖某时刻。
  bool covers(int positionMs) =>
      positionMs >= startMs && positionMs < endMs;

  @override
  String toString() =>
      'SubtitleCue[$startMs~$endMs] ${text.replaceAll('\n', '\\n')}';
}

/// 字幕解析器（C-08）：SRT / VTT / ASS 文本 → 有序 [SubtitleCue] 列表。
class SubtitleParser {
  SubtitleParser._();

  /// 嗅探格式后自动解析。
  ///
  /// 判定：首行含 `WEBVTT` → vtt；含 `[Script Info]` / `[V4+ Styles]` → ass；
  /// 其余按 SRT 兜底。解析失败返回空列表（不抛异常）。
  static List<SubtitleCue> parseAuto(String content) {
    final SubtitleFormat? f = sniff(content);
    if (f == null) return const <SubtitleCue>[];
    return switch (f) {
      SubtitleFormat.srt => parseSrt(content),
      SubtitleFormat.vtt => parseVtt(content),
      SubtitleFormat.ass => parseAss(content),
    };
  }

  /// 字节流解析（P-芯5）：按 BOM / 编码嗅探解码后自动解析。
  ///
  /// 依次识别 UTF-8 BOM、UTF-16 LE / BE BOM；无 BOM 时按 UTF-8 宽容解码
  /// （对齐 iOS `SubtitleParser.parse(url:)` 的编码兜底）。
  static List<SubtitleCue> parseBytes(Uint8List bytes) {
    if (bytes.isEmpty) return const <SubtitleCue>[];
    final String content = decodeBytes(bytes);
    if (content.isEmpty) return const <SubtitleCue>[];
    return parseAuto(content);
  }

  /// 字节流 → 文本（编码嗅探，P-芯5）。
  static String decodeBytes(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final int n = bytes.length ~/ 2;
    final List<int> units = List<int>.generate(n, (int i) {
      final int lo = bytes[i * 2];
      final int hi = bytes[i * 2 + 1];
      return littleEndian ? (hi << 8) | lo : (lo << 8) | hi;
    });
    return String.fromCharCodes(units);
  }

  /// 嗅探字幕格式（无法识别返回 null）。
  static SubtitleFormat? sniff(String content) {
    final String head = content.trimLeft();
    if (head.startsWith('\uFEFF')) {
      return sniff(head.substring(1));
    }
    if (head.startsWith('WEBVTT')) return SubtitleFormat.vtt;
    // P-芯4：SSA 用 `[V4 Styles]`（无 `+`），ASS 用 `[V4+ Styles]`，两者同构。
    if (head.contains('[Script Info]') ||
        head.contains('[V4+ Styles]') ||
        head.contains('[V4 Styles]')) {
      return SubtitleFormat.ass;
    }
    // SRT 常见形态：编号行 + 时间行（`00:00:01,000 --> ...`）。
    final bool looksSrt = RegExp(
      r'^\d+\s*\n\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->',
    ).hasMatch(head);
    return looksSrt ? SubtitleFormat.srt : null;
  }

  /// SRT 解析（`HH:MM:SS,mmm --> HH:MM:SS,mmm` + 文本块，编号可缺失）。
  static List<SubtitleCue> parseSrt(String content) {
    final List<SubtitleCue> out = <SubtitleCue>[];
    final List<String> blocks = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split(RegExp(r'\n{2,}'));
    for (final String rawBlock in blocks) {
      final String block = rawBlock.trim();
      if (block.isEmpty) continue;
      final List<String> lines =
          block.split('\n').map((String l) => l.trim()).toList();
      if (lines.isEmpty || lines.first.isEmpty) continue;
      int i = 0;
      if (RegExp(r'^\d+$').hasMatch(lines[i])) i++; // 跳过可选编号行
      if (i >= lines.length) continue;
      final RegExpMatch? m = _timeRangeRE.firstMatch(lines[i]);
      if (m == null) continue;
      final int? start = _parseTime(m.group(1)!, allowMs: true);
      final int? end = _parseTime(m.group(2)!, allowMs: true);
      if (start == null || end == null) continue;
      final String text = lines.sublist(i + 1).join('\n').trim();
      if (text.isEmpty) continue;
      out.add(SubtitleCue(startMs: start, endMs: end, text: text));
    }
    return out;
  }

  /// WebVTT 解析（`HH:MM:SS.mmm --> ...`；含头部 `WEBVTT` 与可选备注行）。
  static List<SubtitleCue> parseVtt(String content) {
    final List<SubtitleCue> out = <SubtitleCue>[];
    final List<String> lines =
        content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final List<String> textBuf = <String>[];
    int? curStart;
    int? curEnd;
    void flush() {
      if (curStart == null) return;
      final String text = textBuf.join('\n').trim();
      if (text.isNotEmpty) {
        out.add(SubtitleCue(
          startMs: curStart!,
          endMs: curEnd ?? curStart!,
          text: text,
        ));
      }
      curStart = null;
      curEnd = null;
      textBuf.clear();
    }

    for (final String raw in lines) {
      final String l = raw.trim();
      if (l.isEmpty || l.startsWith('WEBVTT') || l.startsWith('NOTE')) {
        flush();
        continue;
      }
      final RegExpMatch? m = _timeRangeRE.firstMatch(l);
      if (m != null) {
        flush();
        curStart = _parseTime(m.group(1)!, allowMs: true);
        curEnd = _parseTime(m.group(2)!, allowMs: true);
        // 时间行可能带 cue 设置（如 `align:start`），跳过其后续行。
        continue;
      }
      textBuf.add(raw);
    }
    flush();
    return out;
  }

  /// ASS 解析：`Dialogue: 标记,开始,结束,样式,名字,边距L,边距R,垂直边距,文本`。
  ///
  /// 时间格式 `H:MM:SS.cc`（百分之一秒）。只取 `[Events]` 段的 Dialogue，
  /// 样式/名字/边距原样保留到 [SubtitleCue.position]。
  static List<SubtitleCue> parseAss(String content) {
    final List<SubtitleCue> out = <SubtitleCue>[];
    final List<String> lines =
        content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    bool inEvents = false;
    for (final String raw in lines) {
      final String l = raw.trim();
      if (l.startsWith('[')) {
        inEvents = l == '[Events]';
        continue;
      }
      if (!inEvents || !l.startsWith('Dialogue:')) continue;
      // 前 9 个逗号分隔字段，文本可含逗号：只切前 9 段。
      final int textStart = _indexOfNth(l, ',', 9);
      if (textStart < 0) continue;
      final String head = l.substring(0, textStart);
      final String text = l.substring(textStart + 1).trim();
      final List<String> f = head.split(',');
      if (f.length < 9) continue;
      final int? start = _parseAssTime(f[1]);
      final int? end = _parseAssTime(f[2]);
      if (start == null || end == null || text.isEmpty) continue;
      out.add(SubtitleCue(
        startMs: start,
        endMs: end,
        text: cleanAssText(text),
        position: 'style=${f[3]}|name=${f[4]}|margin=${f[7]}',
      ));
    }
    return out;
  }

  /// 清理 ASS/SSA 文本（P-芯4，对齐 iOS `cleanASSText`）：
  /// `\N`/`\n` → 换行、`\h` → 空格、剥离 `{\...}` 样式/定位标签。
  static String cleanAssText(String raw) => raw
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ')
      .replaceAll(RegExp(r'\{[^}]*\}'), '')
      .trim();

  // ─────────── 内部工具 ───────────

  static final RegExp _timeRangeRE = RegExp(
    r'(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})',
  );

  /// 解析 `H:MM:SS[,.]mmm` 或 `MM:SS` → 毫秒；非法返回 null。
  static int? _parseTime(String s, {bool allowMs = true}) {
    final List<String> parts = s.split(':');
    if (parts.isEmpty) return null;
    double totalSec = 0;
    try {
      for (int i = 0; i < parts.length; i++) {
        // SRT 毫秒用 `,` 分隔（`00:00:01,000`），VTT 用 `.`，统一归一。
        totalSec = totalSec * 60 + double.parse(parts[i].replaceAll(',', '.'));
      }
    } on FormatException {
      return null;
    }
    return (totalSec * 1000).round();
  }

  /// ASS 时间 `H:MM:SS.cc`（厘秒，最后两位为百分之一秒）。
  static int? _parseAssTime(String s) {
    final RegExpMatch? m = RegExp(
      r'^(\d+):(\d{1,2}):(\d{1,2})\.(\d{1,2})$',
    ).firstMatch(s.trim());
    if (m == null) return null;
    final int h = int.tryParse(m.group(1)!) ?? 0;
    final int mm = int.tryParse(m.group(2)!) ?? 0;
    final int ss = int.tryParse(m.group(3)!) ?? 0;
    final int cc = int.tryParse(m.group(4)!) ?? 0;
    return h * 3600000 + mm * 60000 + ss * 1000 + cc * 10;
  }

  /// 第 [n] 个（从 1 起）`,` 的下标；不足返回 -1。
  static int _indexOfNth(String s, String needle, int n) {
    int idx = -1;
    for (int i = 0; i < n; i++) {
      idx = s.indexOf(needle, idx + 1);
      if (idx < 0) return -1;
    }
    return idx;
  }
}

/// 字幕轨道：按时间查询当前字幕（C-08 加载后查询）。
class SubtitleTrack {
  /// 构造（cues 按 startMs 升序；内部复制排序）。
  SubtitleTrack(List<SubtitleCue> cues)
      : _cues = List<SubtitleCue>.of(cues)
          ..sort((SubtitleCue a, SubtitleCue b) {
            final int c = a.startMs.compareTo(b.startMs);
            return c != 0 ? c : a.endMs.compareTo(b.endMs);
          });

  /// 解析文本为轨道（格式可自动嗅探）。
  factory SubtitleTrack.parse(String content, {SubtitleFormat? format}) {
    final List<SubtitleCue> cues = format == null
        ? SubtitleParser.parseAuto(content)
        : switch (format) {
            SubtitleFormat.srt => SubtitleParser.parseSrt(content),
            SubtitleFormat.vtt => SubtitleParser.parseVtt(content),
            SubtitleFormat.ass => SubtitleParser.parseAss(content),
          };
    return SubtitleTrack(cues);
  }

  final List<SubtitleCue> _cues;

  /// 全部字幕（有序）。
  List<SubtitleCue> get cues => _cues;

  /// 是否为空轨道。
  bool get isEmpty => _cues.isEmpty;

  /// 查询 [positionMs] 时刻应显示的字幕（无则 null；二分查找）。
  SubtitleCue? cueAt(int positionMs) {
    int lo = 0;
    int hi = _cues.length - 1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      final SubtitleCue c = _cues[mid];
      if (c.startMs > positionMs) {
        hi = mid - 1;
      } else if (c.endMs <= positionMs) {
        lo = mid + 1;
      } else {
        return c;
      }
    }
    return null;
  }

  /// 总时长（最后一条字幕的结束时间，毫秒）。
  int get durationMs =>
      _cues.isEmpty ? 0 : _cues.map((SubtitleCue c) => c.endMs).reduce(math.max);

  @override
  String toString() => 'SubtitleTrack(${_cues.length} cues, ${durationMs}ms)';
}
