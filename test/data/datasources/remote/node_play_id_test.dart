/// 单测：Node playID 解码器（批次 F · F-P26）。
///
/// 覆盖 `NodePlayId` 的三个静态辅助（对齐 iOS `decodeNodePlayIDObject` /
/// `nodeStableFileKey` / `nodePlayIDFileName`）：base64 → JSON、data URL 前缀、
/// `+` 被当作空格的容错、稳定文件键（fileId → playToken.fid）、展示文件名。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/node_play_id.dart';

/// playID 载荷 → base64 JSON（对齐 Node 侧 `id` 生成口径）。
String _id(Map<String, Object?> obj) =>
    base64.encode(utf8.encode(jsonEncode(obj)));

void main() {
  group('decodeObject（对齐 iOS decodeNodePlayIDObject）', () {
    test('明文 base64 JSON → 字典', () {
      final Map<String, dynamic>? obj = NodePlayId.decodeObject(
        _id(<String, Object?>{'fileId': 'F1', 'name': '第01集.mp4'}),
      );
      expect(obj, isNotNull);
      expect(obj!['fileId'], 'F1');
      expect(obj['name'], '第01集.mp4');
    });

    test('data URL 前缀：`base64,` 之前整段丢弃', () {
      final String id = 'data:application/json;base64,'
          '${_id(<String, Object?>{'name': 'a.mp4'})}';
      expect(NodePlayId.decodeObject(id)?['name'], 'a.mp4');
    });

    test('空格还原为 +（URL 传输把 + 当空格）', () {
      // 中文名在 base64 中会产生 `+`（ASCII JSON 不会，须用多字节字符）。
      final String id = _id(<String, Object?>{'name': '俱'});
      expect(id, contains('+'));
      final String spaced = id.replaceAll('+', ' ');
      expect(NodePlayId.fileName(spaced), '俱');
    });

    test('空串 → null', () {
      expect(NodePlayId.decodeObject(''), isNull);
    });

    test('非法 base64（长度不合法）→ null', () {
      expect(NodePlayId.decodeObject('!!!not-base64!!!'), isNull);
    });

    test('非 JSON 载荷 → null', () {
      final String id = base64.encode(utf8.encode('plaintext'));
      expect(NodePlayId.decodeObject(id), isNull);
    });
  });

  group('stableFileKey（对齐 iOS nodeStableFileKey）', () {
    test('fileId 优先于 playToken.fid', () {
      final String id = _id(<String, Object?>{
        'fileId': 'F1',
        'playToken': jsonEncode(<String, Object?>{'fid': 'T1'}),
      });
      expect(NodePlayId.stableFileKey(id), 'F1');
    });

    test('缺 fileId → 回落 playToken.fid（嵌套 JSON 文本）', () {
      final String id = _id(<String, Object?>{
        'playToken': jsonEncode(<String, Object?>{'fid': 'T1', 'stoken': 's'}),
      });
      expect(NodePlayId.stableFileKey(id), 'T1');
    });

    test('fileId 为空串 → 回落 playToken.fid', () {
      final String id = _id(<String, Object?>{
        'fileId': '',
        'playToken': jsonEncode(<String, Object?>{'fid': 'T2'}),
      });
      expect(NodePlayId.stableFileKey(id), 'T2');
    });

    test('fileId / playToken 均缺失 → null', () {
      expect(
        NodePlayId.stableFileKey(_id(<String, Object?>{'name': 'a.mp4'})),
        isNull,
      );
    });

    test('playToken 非 JSON 文本 → null', () {
      final String id = _id(<String, Object?>{'playToken': 'not-json'});
      expect(NodePlayId.stableFileKey(id), isNull);
    });
  });

  group('fileName（对齐 iOS nodePlayIDFileName）', () {
    test('name 字段 → 展示文件名', () {
      expect(
        NodePlayId.fileName(_id(<String, Object?>{'name': '第02集.mkv'})),
        '第02集.mkv',
      );
    });

    test('name 非字符串 → null', () {
      expect(NodePlayId.fileName(_id(<String, Object?>{'name': 123})), isNull);
    });

    test('无 name 字段 → null', () {
      expect(NodePlayId.fileName(_id(<String, Object?>{'fileId': 'F1'})), isNull);
    });
  });
}