/// 核心层单测：目录布局 + 文件读写 + 安全存储。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vbox/core/errors/exceptions.dart';
import 'package:vbox/core/storage/storage.dart';

void main() {
  group('StoragePaths', () {
    tearDown(StoragePaths.reset);

    test('未配置时访问 root 抛 StateError', () {
      StoragePaths.reset();
      expect(StoragePaths.isConfigured, isFalse);
      expect(() => StoragePaths.root, throwsStateError);
      expect(() => StoragePaths.dbDir, throwsStateError);
    });

    test('配置后目录与数据库文件路径正确', () {
      StoragePaths.configure(p.join('/tmp', 'vboxroot'));
      expect(StoragePaths.isConfigured, isTrue);
      expect(StoragePaths.dbDir, p.join('/tmp', 'vboxroot', 'db'));
      expect(StoragePaths.backupDir, p.join('/tmp', 'vboxroot', 'backup'));
      expect(StoragePaths.logDir, p.join('/tmp', 'vboxroot', 'log'));
      expect(StoragePaths.spiderDir, p.join('/tmp', 'vboxroot', 'spider'));
      expect(
        StoragePaths.databaseFile,
        p.join('/tmp', 'vboxroot', 'db', 'vbox.sqlite3'),
      );
      expect(StoragePaths.allDirs.length, 6);
    });

    test('ensureLayout 幂等创建全部目录', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('vbox_paths_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      StoragePaths.configure(tmp.path);
      await StoragePaths.ensureLayout();
      await StoragePaths.ensureLayout();
      for (final String dir in StoragePaths.allDirs) {
        expect(Directory(dir).existsSync(), isTrue, reason: dir);
      }
    });
  });

  group('FileStore', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('vbox_files_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('文本原子写 + 读回（自动建父目录）', () async {
      final String file = p.join(tmp.path, 'a', 'b', 'note.txt');
      await FileStore.writeString(file, '内容 1');
      expect(await FileStore.readString(file), '内容 1');
      expect(File('$file.tmp').existsSync(), isFalse);
      // 覆盖写
      await FileStore.writeString(file, '内容 2');
      expect(await FileStore.readString(file), '内容 2');
    });

    test('读不存在的文件返回 null', () async {
      expect(await FileStore.readString(p.join(tmp.path, 'nope.txt')), isNull);
    });

    test('JSON 往返', () async {
      final String file = p.join(tmp.path, 'data.json');
      await FileStore.writeJson(file, <String, Object?>{'n': 1, 's': 'x'});
      final Map<String, Object?>? back = await FileStore.readJsonMap(file);
      expect(back?['n'], 1);
      expect(back?['s'], 'x');

      await FileStore.writeString(file, '不是 JSON');
      expect(await FileStore.readJsonMap(file), isNull);
    });

    test('delete / sizeOf / list', () async {
      final String f1 = p.join(tmp.path, 'x.json');
      final String f2 = p.join(tmp.path, 'y.txt');
      await FileStore.writeString(f1, '12345');
      await FileStore.writeString(f2, 'ab');

      expect(await FileStore.sizeOf(f1), 5);
      expect(await FileStore.sizeOf(p.join(tmp.path, 'missing')), 0);

      final List<String> jsonOnly = await FileStore.list(tmp.path, suffix: '.json');
      expect(jsonOnly, <String>[f1]);
      expect((await FileStore.list(tmp.path)).length, 2);
      expect(await FileStore.list(p.join(tmp.path, 'nodir')), isEmpty);

      expect(await FileStore.delete(f1), isTrue);
      expect(await FileStore.delete(f1), isFalse);
      expect(File(f1).existsSync(), isFalse);
    });
  });

  group('InMemorySecureStore', () {
    test('读写删查清', () async {
      final InMemorySecureStore store = InMemorySecureStore();
      expect(await store.read('k'), isNull);
      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      expect(await store.containsKey('k'), isTrue);
      expect(await store.delete('k'), isTrue);
      expect(await store.delete('k'), isFalse);
      expect(await store.containsKey('k'), isFalse);

      await store.write('a', '1');
      await store.clear();
      expect(store.keys, isEmpty);
    });

    test('构造时可注入初值（测试替身）', () async {
      final InMemorySecureStore store =
          InMemorySecureStore(<String, String>{'token': 't'});
      expect(await store.read('token'), 't');
    });
  });

  group('异常类型', () {
    test('StorageException 是 VBoxException 且错误码为 storageIo', () {
      const StorageException e = StorageException('写失败');
      expect(e.code.name, 'storageIo');
      expect(e.toString(), contains('写失败'));
    });
  });
}
