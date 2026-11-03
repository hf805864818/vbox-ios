/// 数据模型层单测：#10 —— `lib/data/models/*` 的 toMap/fromMap 保真度。
///
/// 三道防线：
///   ① 列名与 DDL 真相源（`contract/schema/schema_v1.sql`）**逐表完全一致**；
///   ② toMap → fromMap → toMap 往返稳定（含 id 可空语义）；
///   ③ v4 可空列（旧数据 NULL）必须容忍。
///
/// 说明：Python 侧 `check_models_roundtrip.py` 已做端到端 SQL 往返；
/// 本文件补上「Dart 侧进程内」的第二道防线，防模型与 DDL 悄悄漂移。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/contract/schema/schema.dart';
import 'package:vbox/data/models/models.dart';

/// 从 DDL 解析出「表名 → 列名集合」。
///
/// 支持 `CREATE TABLE ... ( ... )`（含 `UNIQUE(a,b)` 等表级约束）与
/// `ALTER TABLE x ADD COLUMN y`。
Map<String, Set<String>> _parseDdlColumns(String sql) {
  final String s = sql.replaceAll(RegExp(r'--[^\n]*'), '');
  final Map<String, Set<String>> out = <String, Set<String>>{};

  final RegExp create = RegExp(
    r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(',
    caseSensitive: false,
  );
  for (final RegExpMatch m in create.allMatches(s)) {
    // 括号配对，取出表体（内部可能含 UNIQUE(a, b) 的括号）
    int i = m.end;
    int depth = 1;
    final int bodyStart = m.end;
    while (i < s.length && depth > 0) {
      final String ch = s[i];
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
      }
      i++;
    }
    final String body = s.substring(bodyStart, i - 1);
    final Set<String> cols = <String>{};
    for (final String raw in _splitTopLevel(body)) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (RegExp(r'^(UNIQUE|PRIMARY|FOREIGN|CHECK|CONSTRAINT)\b',
              caseSensitive: false)
          .hasMatch(line)) {
        continue;
      }
      final Match? idm = RegExp(r'^(\w+)').firstMatch(line);
      if (idm != null) cols.add(idm.group(1)!);
    }
    out[m.group(1)!] = cols;
  }

  final RegExp alter = RegExp(
    r'ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)',
    caseSensitive: false,
  );
  for (final RegExpMatch m in alter.allMatches(s)) {
    out.putIfAbsent(m.group(1)!, () => <String>{}).add(m.group(2)!);
  }
  return out;
}

List<String> _splitTopLevel(String body) {
  final List<String> parts = <String>[];
  final StringBuffer buf = StringBuffer();
  int depth = 0;
  for (final int code in body.codeUnits) {
    final String ch = String.fromCharCode(code);
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  parts.add(buf.toString());
  return parts;
}

void main() {
  late Map<String, Set<String>> ddl;

  setUpAll(() {
    final File f = File('contract/schema/schema_v1.sql');
    expect(f.existsSync(), isTrue,
        reason: 'DDL 真相源不存在: ${f.path}（cwd=${Directory.current.path}）');
    ddl = _parseDdlColumns(f.readAsStringSync());
  });

  group('DDL 解析自检', () {
    test('解析出 9 张业务表且列数符合预期', () {
      expect(ddl.keys.toSet(), kAllTables.toSet());
      expect(ddl['zhanyuan']!.length, 17);
      expect(ddl['apiyuan']!.length, 8);
      expect(ddl['subscription']!.length, 5);
      expect(ddl['favorite']!.length, 9);
      expect(ddl['history']!.length, 10);
      expect(ddl['download']!.length, 17, reason: '13 v1 列 + 4 v4 列');
      expect(ddl['settings']!.length, 3);
      expect(ddl['jiexisetting']!.length, 3);
      expect(ddl['search_history']!.length, 3);
    });

    test('download 的 v4 列来自 ALTER 且与契约常量一致', () {
      for (final String c in kDownloadV4NullableColumns) {
        expect(ddl['download']!.contains(c), isTrue, reason: 'DDL 缺 $c');
      }
      expect(kDownloadV4NullableColumns.length, 4);
    });
  });

  group('列名 ↔ DDL 逐表完全一致', () {
    test('9 个模型 toMap 的键集合 == DDL 列集合', () {
      final Map<String, Set<String>> modelCols = <String, Set<String>>{
        Zhanyuan.table: const Zhanyuan(
          id: 1,
          name: 'n',
          searchUrl: 'u',
          updatedAt: 1,
        ).toMap().keys.toSet(),
        Apiyuan.table:
            const Apiyuan(id: 1, name: 'n', searchurl: 'u').toMap().keys.toSet(),
        Subscription.table: const Subscription(
          id: 1,
          dyname: 'n',
          dyurl: 'u',
          lastSyncAt: 1,
        ).toMap().keys.toSet(),
        Favorite.table:
            const Favorite(id: 1, name: 'n', addedAt: 1).toMap().keys.toSet(),
        History.table:
            const History(id: 1, name: 'n', lastPlayedAt: 1).toMap().keys.toSet(),
        Download.table:
            const Download(id: 1, name: 'n', addedAt: 1).toMap().keys.toSet(),
        Setting.table: const Setting(key: 'k', updatedAt: 1).toMap().keys.toSet(),
        Jiexisetting.table: const Jiexisetting(bianma: 'b').toMap().keys.toSet(),
        SearchHistory.table:
            const SearchHistory(id: 1, keyword: 'k', searchedAt: 1).toMap().keys.toSet(),
      };
      expect(modelCols.keys.toSet(), kAllTables.toSet());
      for (final MapEntry<String, Set<String>> e in modelCols.entries) {
        expect(e.value, ddl[e.key],
            reason: '${e.key} 模型列与 DDL 不一致 缺=${ddl[e.key]!.difference(e.value)} '
                '多=${e.value.difference(ddl[e.key]!)}');
      }
    });

    test('id 为 null 时 toMap 省略 id（交给 AUTOINCREMENT）', () {
      expect(const Zhanyuan(name: 'n', searchUrl: 'u', updatedAt: 1)
          .toMap()
          .containsKey('id'), isFalse);
      expect(const Apiyuan(name: 'n', searchurl: 'u').toMap().containsKey('id'), isFalse);
      expect(const Favorite(name: 'n', addedAt: 1).toMap().containsKey('id'), isFalse);
      expect(const History(name: 'n', lastPlayedAt: 1).toMap().containsKey('id'), isFalse);
      expect(const Download(name: 'n', addedAt: 1).toMap().containsKey('id'), isFalse);
      expect(const SearchHistory(keyword: 'k', searchedAt: 1)
          .toMap()
          .containsKey('id'), isFalse);
      // 无 id 列的表（TEXT 主键）
      expect(const Setting(key: 'k', updatedAt: 1).toMap().containsKey('id'), isFalse);
      expect(const Jiexisetting(bianma: 'b').toMap().containsKey('id'), isFalse);
    });
  });

  group('toMap/fromMap 往返稳定', () {
    test('zhanyuan：bool → 0/1，且往返不丢字段', () {
      const Zhanyuan z = Zhanyuan(
        id: 3,
        name: '源A',
        searchUrl: 'http://a/s',
        searchUA: 'UA',
        playUA: 'PUA',
        websearchurl: 'w',
        searchname: 'sn',
        searchid: 'si',
        searchpic: 'sp',
        searchstarr: 'ss',
        detaillist: 'dl',
        detailxl: 'dx',
        detailjs: 'dj',
        detailjsurl: 'dju',
        isActive: false,
        updatedAt: 1700000000,
        dyurl: 'dy',
      );
      final Map<String, Object?> m = z.toMap();
      expect(m['isActive'], 0, reason: 'false 必须写 0');
      expect(Zhanyuan.fromMap(m).toMap(), m);
      expect(Zhanyuan.fromMap(m).isActive, isFalse);
    });

    test('apiyuan：bool 往返', () {
      const Apiyuan a = Apiyuan(
        id: 1,
        name: 'n',
        searchurl: 'u',
        searchua: 'a',
        detailurl: 'd',
        detailua: 'du',
        isActive: false,
        dyurl: 'y',
      );
      final Map<String, Object?> m = a.toMap();
      expect(m['isActive'], 0);
      expect(Apiyuan.fromMap(m).toMap(), m);
    });

    test('subscription 往返', () {
      const Subscription s =
          Subscription(id: 2, dyname: 'n', dyurl: 'u', dyzz: 'z', lastSyncAt: 9);
      final Map<String, Object?> m = s.toMap();
      expect(Subscription.fromMap(m).toMap(), m);
    });

    test('favorite 往返', () {
      const Favorite f = Favorite(
          id: 4,
          name: 'n',
          laiyuan: 'l',
          imgurl: 'i',
          detailurl: 'd',
          detailua: 'du',
          xianlu: 2,
          jishu: 3,
          addedAt: 11);
      final Map<String, Object?> m = f.toMap();
      expect(Favorite.fromMap(m).toMap(), m);
    });

    test('history：progress 为 REAL，num 输入亦转 double', () {
      const History h = History(
          id: 5, name: 'n', progress: 0.75, lastPlayedAt: 11);
      final Map<String, Object?> m = h.toMap();
      expect(History.fromMap(m).toMap(), m);
      // 旧数据可能以整数写入
      final History fromInt =
          History.fromMap(<String, Object?>{'id': 6, 'name': 'n', 'progress': 1, 'lastPlayedAt': 1});
      expect(fromInt.progress, 1.0);
      expect(fromInt.progress, isA<double>());
    });

    test('download：全字段往返（含 v4 列有值）', () {
      const Download d = Download(
        id: 7,
        name: 'n',
        laiyuan: 'l',
        imgurl: 'i',
        detailurl: 'd',
        playurl: 'p',
        jishu: 1,
        progress: 0.25,
        status: DownloadStatus.downloading,
        filePath: '/tmp/a',
        fileSize: 100,
        downloadedSize: 50,
        addedAt: 11,
        sourceType: 'cloud',
        engineKey: 'spider_x',
        vodId: 'v1',
        headers: '{"k":"v"}',
      );
      final Map<String, Object?> m = d.toMap();
      expect(m['status'], 'downloading');
      expect(Download.fromMap(m).toMap(), m);
    });

    test('settings / jiexisetting / search_history 往返', () {
      const Setting st = Setting(key: 'k', value: 'v', updatedAt: 1);
      expect(Setting.fromMap(st.toMap()).toMap(), st.toMap());

      const Jiexisetting j = Jiexisetting(bianma: 'b', zhuurl: 'z', beiurl: 'be');
      expect(Jiexisetting.fromMap(j.toMap()).toMap(), j.toMap());

      const SearchHistory sh = SearchHistory(id: 8, keyword: 'kw', searchedAt: 5);
      expect(SearchHistory.fromMap(sh.toMap()).toMap(), sh.toMap());
    });

    test('fromMap 容忍缺省列（旧库/部分 SELECT 场景）', () {
      final Favorite f = Favorite.fromMap(<String, Object?>{'name': 'n', 'addedAt': 1});
      expect(f.laiyuan, '');
      expect(f.xianlu, 0);
      final Download d = Download.fromMap(<String, Object?>{'name': 'n', 'addedAt': 1});
      expect(d.progress, 0.0);
      expect(d.status, DownloadStatus.pending);
      expect(d.fileSize, 0);
    });
  });

  group('download v4 可空列（旧数据 NULL 兼容）', () {
    test('旧行（缺 4 列）fromMap → 全 null；toMap 仍输出 4 键', () {
      final Download d = Download.fromMap(<String, Object?>{
        'id': 9,
        'name': 'old.mp4',
        'addedAt': 1,
      });
      for (final String c in kDownloadV4NullableColumns) {
        switch (c) {
          case 'sourceType':
            expect(d.sourceType, isNull);
          case 'engineKey':
            expect(d.engineKey, isNull);
          case 'vodId':
            expect(d.vodId, isNull);
          case 'headers':
            expect(d.headers, isNull);
        }
      }
      final Map<String, Object?> m = d.toMap();
      for (final String c in kDownloadV4NullableColumns) {
        expect(m.containsKey(c), isTrue, reason: '$c 键应始终输出');
        expect(m[c], isNull, reason: '$c 旧数据应为 NULL');
      }
    });

    test('显式 NULL 行往返稳定', () {
      final Map<String, Object?> row = <String, Object?>{
        'id': 10,
        'name': 'n',
        'addedAt': 1,
        'sourceType': null,
        'engineKey': null,
        'vodId': null,
        'headers': null,
      };
      final Map<String, Object?> m = Download.fromMap(row).toMap();
      for (final String c in kDownloadV4NullableColumns) {
        expect(m, containsPair(c, null));
      }
      expect(Download.fromMap(m).toMap(), m, reason: 'NULL 往返应稳定');
    });
  });

  group('DownloadStatus 映射', () {
    test('fromDb 四态 + 未知回退 pending', () {
      expect(DownloadStatus.fromDb('pending'), DownloadStatus.pending);
      expect(DownloadStatus.fromDb('downloading'), DownloadStatus.downloading);
      expect(DownloadStatus.fromDb('completed'), DownloadStatus.completed);
      expect(DownloadStatus.fromDb('failed'), DownloadStatus.failed);
      expect(DownloadStatus.fromDb('unknown'), DownloadStatus.pending);
      expect(DownloadStatus.fromDb(null), DownloadStatus.pending);
    });

    test('toDb == name（DDL 注释枚举一致）', () {
      for (final DownloadStatus s in DownloadStatus.values) {
        expect(s.toDb(), s.name);
      }
    });
  });

  group('db_model 辅助函数', () {
    test('readBool：null/bool/int/string 全覆盖', () {
      expect(readBool(null), isFalse);
      expect(readBool(true), isTrue);
      expect(readBool(false), isFalse);
      expect(readBool(1), isTrue);
      expect(readBool(0), isFalse);
      expect(readBool(2), isTrue);
      expect(readBool('1'), isTrue);
      expect(readBool('true'), isTrue);
      expect(readBool('TRUE'), isTrue);
      expect(readBool('0'), isFalse);
      expect(readBool('false'), isFalse);
      expect(readBool(<String>[]), isFalse, reason: '未知类型回退 false');
    });

    test('writeBool：true→1 / false→0', () {
      expect(writeBool(true), 1);
      expect(writeBool(false), 0);
    });

    test('readNullableString：NULL 保持 null', () {
      expect(readNullableString(null), isNull);
      expect(readNullableString('x'), 'x');
    });

    test('readTime/writeTime：Unix 秒往返', () {
      final DateTime t = readTime(1700000000);
      expect(t, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(writeTime(t), 1700000000);
    });
  });
}