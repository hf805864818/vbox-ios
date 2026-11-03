/// 网盘文件与清理队列领域模型单测（批次 F · F-07）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager.CleanupQueueItem`
/// （`vbox/Services/CloudDriveManager.swift:137`）与 `enqueueCleanup` /
/// `flushCleanupQueue`（同文件 `:1239` / `:1278`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_files.dart';

CloudDriveCleanupItem _item(
  String drive,
  String token,
  String fid, {
  required DateTime eligibleAt,
  required DateTime createdAt,
}) =>
    CloudDriveCleanupItem(
      drive: drive,
      tokenName: token,
      fileId: fid,
      eligibleAt: eligibleAt,
      createdAt: createdAt,
    );

void main() {
  final DateTime t0 = DateTime.utc(2026, 10, 3, 12);

  group('CloudDriveCleanupItem', () {
    test('dedupKey = drive|tokenName|fileId（对齐 iOS 去重键）', () {
      final CloudDriveCleanupItem item = _item(
        'quark',
        '夸克主号',
        'fid_1',
        eligibleAt: t0,
        createdAt: t0,
      );
      expect(item.dedupKey, 'quark|夸克主号|fid_1');
    });

    test('isDue：eligibleAt <= now 为真', () {
      final CloudDriveCleanupItem item =
          _item('quark', '', 'f', eligibleAt: t0, createdAt: t0);
      expect(item.isDue(t0), isTrue);
      expect(item.isDue(t0.subtract(const Duration(seconds: 1))), isFalse);
    });

    test('JSON 往返保留五字段', () {
      final CloudDriveCleanupItem item = _item(
        'baidu',
        '百度主号',
        'fs_9',
        eligibleAt: t0.add(const Duration(seconds: 180)),
        createdAt: t0,
      );
      final CloudDriveCleanupItem back =
          CloudDriveCleanupItem.fromJson(item.toJson());
      expect(back.drive, 'baidu');
      expect(back.tokenName, '百度主号');
      expect(back.fileId, 'fs_9');
      expect(back.eligibleAt, item.eligibleAt);
      expect(back.createdAt, item.createdAt);
    });

    test('等值语义按去重键（drive/tokenName/fileId）', () {
      final CloudDriveCleanupItem a =
          _item('uc', 'n', 'f', eligibleAt: t0, createdAt: t0);
      final CloudDriveCleanupItem b = _item(
        'uc',
        'n',
        'f',
        eligibleAt: t0.add(const Duration(minutes: 1)),
        createdAt: t0.add(const Duration(minutes: 1)),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('CloudDriveCleanupQueue.enqueue 去重', () {
    test('重复 fileId 不追加，且不改写原 eligibleAt（先到者先算）', () {
      final List<CloudDriveCleanupItem> first =
          CloudDriveCleanupQueue.enqueue(
        <CloudDriveCleanupItem>[],
        drive: 'quark',
        tokenName: 'n',
        fileIds: <String>['a', 'b'],
        delay: const Duration(seconds: 180),
        now: t0,
      );
      expect(first.length, 2);
      final List<CloudDriveCleanupItem> second =
          CloudDriveCleanupQueue.enqueue(
        first,
        drive: 'quark',
        tokenName: 'n',
        fileIds: <String>['b', 'c'],
        delay: const Duration(seconds: 60),
        now: t0.add(const Duration(seconds: 30)),
      );
      expect(second.length, 3);
      final CloudDriveCleanupItem b =
          second.firstWhere((CloudDriveCleanupItem e) => e.fileId == 'b');
      // b 原样保留首次入队时间与到期时间。
      expect(b.createdAt, t0);
      expect(b.eligibleAt, t0.add(const Duration(seconds: 180)));
      final CloudDriveCleanupItem c =
          second.firstWhere((CloudDriveCleanupItem e) => e.fileId == 'c');
      expect(c.eligibleAt, t0.add(const Duration(seconds: 90)));
    });

    test('tokenName 不同则视为不同条目（去重键含 tokenName）', () {
      final List<CloudDriveCleanupItem> queue =
          CloudDriveCleanupQueue.enqueue(
        <CloudDriveCleanupItem>[],
        drive: 'baidu',
        tokenName: '账号A',
        fileIds: <String>['f'],
        delay: Duration.zero,
        now: t0,
      );
      final List<CloudDriveCleanupItem> next =
          CloudDriveCleanupQueue.enqueue(
        queue,
        drive: 'baidu',
        tokenName: '账号B',
        fileIds: <String>['f'],
        delay: Duration.zero,
        now: t0,
      );
      expect(next.length, 2);
    });

    test('空 fileId 忽略（对齐 iOS where !fid.isEmpty）', () {
      final List<CloudDriveCleanupItem> queue =
          CloudDriveCleanupQueue.enqueue(
        <CloudDriveCleanupItem>[],
        drive: 'quark',
        tokenName: '',
        fileIds: <String>['', 'x', ''],
        delay: Duration.zero,
        now: t0,
      );
      expect(queue.map((CloudDriveCleanupItem e) => e.fileId), <String>['x']);
    });

    test('超过上限 300 保留最新（同批按入队先后保留后者）', () {
      final List<String> oldIds =
          List<String>.generate(300, (int i) => 'old_$i');
      final List<CloudDriveCleanupItem> base =
          CloudDriveCleanupQueue.enqueue(
        <CloudDriveCleanupItem>[],
        drive: 'quark',
        tokenName: 'n',
        fileIds: oldIds,
        delay: Duration.zero,
        now: t0,
      );
      expect(base.length, 300);

      final List<String> newIds =
          List<String>.generate(5, (int i) => 'new_$i');
      final List<CloudDriveCleanupItem> trimmed =
          CloudDriveCleanupQueue.enqueue(
        base,
        drive: 'quark',
        tokenName: 'n',
        fileIds: newIds,
        delay: Duration.zero,
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(trimmed.length, 300);
      // 5 条最新全部保留。
      expect(
        trimmed.map((CloudDriveCleanupItem e) => e.fileId).toSet(),
        containsAll(newIds),
      );
      // 最早的 5 条被裁掉。
      expect(
        trimmed.map((CloudDriveCleanupItem e) => e.fileId).toSet(),
        isNot(containsAll(<String>['old_0', 'old_1', 'old_2', 'old_3', 'old_4'])),
      );
      // 去重键全局唯一。
      expect(
        trimmed.map((CloudDriveCleanupItem e) => e.dedupKey).toSet().length,
        300,
      );
    });
  });

  group('CloudDriveCleanupQueue.due / groupByDrive / remove', () {
    test('due 仅返回到期条目', () {
      final List<CloudDriveCleanupItem> queue = <CloudDriveCleanupItem>[
        _item('quark', 'n', 'a',
            eligibleAt: t0.subtract(const Duration(seconds: 1)),
            createdAt: t0),
        _item('quark', 'n', 'b',
            eligibleAt: t0.add(const Duration(seconds: 60)), createdAt: t0),
      ];
      final List<CloudDriveCleanupItem> due =
          CloudDriveCleanupQueue.due(queue, t0);
      expect(due.map((CloudDriveCleanupItem e) => e.fileId), <String>['a']);
    });

    test('groupByDrive 按 drive|tokenName 分组收集 fileId', () {
      final List<CloudDriveCleanupItem> queue = <CloudDriveCleanupItem>[
        _item('quark', 'n1', 'a', eligibleAt: t0, createdAt: t0),
        _item('quark', 'n1', 'b', eligibleAt: t0, createdAt: t0),
        _item('quark', 'n2', 'c', eligibleAt: t0, createdAt: t0),
        _item('baidu', '', 'd', eligibleAt: t0, createdAt: t0),
      ];
      final Map<String, List<String>> groups =
          CloudDriveCleanupQueue.groupByDrive(queue);
      expect(groups['quark|n1'], <String>['a', 'b']);
      expect(groups['quark|n2'], <String>['c']);
      expect(groups['baidu|'], <String>['d']);
    });

    test('remove 按去重键移除', () {
      final List<CloudDriveCleanupItem> queue = <CloudDriveCleanupItem>[
        _item('quark', 'n', 'a', eligibleAt: t0, createdAt: t0),
        _item('quark', 'n', 'b', eligibleAt: t0, createdAt: t0),
      ];
      final List<CloudDriveCleanupItem> next =
          CloudDriveCleanupQueue.remove(queue, <CloudDriveCleanupItem>[queue[0]]);
      expect(next.map((CloudDriveCleanupItem e) => e.fileId), <String>['b']);
    });
  });

  group('CloudDriveFileEntry', () {
    test('文件夹优先排序，其次按名称忽略大小写', () {
      final List<CloudDriveFileEntry> list = <CloudDriveFileEntry>[
        const CloudDriveFileEntry(fileId: '1', name: 'b.mp4'),
        const CloudDriveFileEntry(fileId: '2', name: 'Alpha', isFolder: true),
        const CloudDriveFileEntry(fileId: '3', name: 'a.mp4'),
        const CloudDriveFileEntry(fileId: '4', name: 'beta', isFolder: true),
      ]..sort((CloudDriveFileEntry a, CloudDriveFileEntry b) => a.compareTo(b));
      expect(
        list.map((CloudDriveFileEntry e) => e.name),
        <String>['Alpha', 'beta', 'a.mp4', 'b.mp4'],
      );
    });

    test('isVideo 按扩展名判定', () {
      expect(
        const CloudDriveFileEntry(fileId: '1', name: 'EP01.MKV').isVideo,
        isTrue,
      );
      expect(
        const CloudDriveFileEntry(fileId: '2', name: 'cover.jpg').isVideo,
        isFalse,
      );
    });

    test('JSON 兼容 fileId / fsId / fid 三种键', () {
      expect(
        CloudDriveFileEntry.fromJson(<String, dynamic>{'fsId': 'x'}).fileId,
        'x',
      );
      expect(
        CloudDriveFileEntry.fromJson(<String, dynamic>{'fid': 'y'}).fileId,
        'y',
      );
      expect(
        CloudDriveFileEntry.fromJson(<String, dynamic>{'fileId': 'z'}).fileId,
        'z',
      );
    });
  });
}
