/// Node 网盘播放领域单测（批次 F · F-08）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/NodePanResolver.swift`
/// （`parsePlayURL` / `decodeName` / `NodePanError`）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/node_pan.dart';

String _idWithName(String name) =>
    base64.encode(utf8.encode(jsonEncode(<String, String>{'name': name})));

void main() {
  group('NodePanParser.parsePlayUrl', () {
    test(r'解析「名$id#名$id」，名称取 id 内 name', () {
      final String a = _idWithName('第01集.mp4');
      final String b = _idWithName('第02集.mp4');
      final List<NodePanEntry> entries =
          NodePanParser.parsePlayUrl('aliasA\u0024$a#aliasB\u0024$b');
      expect(entries.length, 2);
      expect(entries[0].playID, a);
      expect(entries[0].name, '第01集.mp4');
      expect(entries[1].name, '第02集.mp4');
    });

    test(r'多播放组 $$$ 仅取第一组', () {
      final String a = _idWithName('原画.mp4');
      final String b = _idWithName('极速.mp4');
      final List<NodePanEntry> entries =
          NodePanParser.parsePlayUrl('原画\u0024$a\u0024\u0024\u0024极速\u0024$b');
      expect(entries.length, 1);
      expect(entries.single.name, '原画.mp4');
    });

    test('id 非 base64 JSON 时回退到分隔符前名称', () {
      final List<NodePanEntry> entries =
          NodePanParser.parsePlayUrl('my-movie\u0024not-base64-json');
      expect(entries.single.name, 'my-movie');
      expect(entries.single.playID, 'not-base64-json');
    });

    test(r'跳过畸形片段（无 $ / 空 id）', () {
      expect(NodePanParser.parsePlayUrl('noDollar'), isEmpty);
      expect(NodePanParser.parsePlayUrl('name\u0024'), isEmpty);
      expect(NodePanParser.parsePlayUrl(''), isEmpty);
    });
  });

  group('NodePanRouting', () {
    test('10 家 Node 托管盘命中', () {
      for (final CloudDriveType t in NodePanRouting.managedProviders) {
        expect(NodePanRouting.isNodeManaged(t), isTrue, reason: t.id);
      }
      expect(NodePanRouting.managedProviders.length, 10);
    });

    test('原生盘 / 未支持盘不命中', () {
      for (final CloudDriveType t in <CloudDriveType>[
        CloudDriveType.ali,
        CloudDriveType.quark,
        CloudDriveType.baidu,
        CloudDriveType.uc,
        CloudDriveType.bilibili,
      ]) {
        expect(NodePanRouting.isNodeManaged(t), isFalse, reason: t.id);
      }
    });
  });

  group('NodePanException', () {
    test('displayMessage 逐档对齐 iOS errorDescription', () {
      expect(
        const NodePanException.nodeUnavailable().displayMessage,
        'Node 常驻系统未就绪，请稍后重试',
      );
      expect(
        const NodePanException(NodePanErrorKind.invalidShareURL).displayMessage,
        '无法识别的分享链接',
      );
      expect(
        const NodePanException(NodePanErrorKind.nodeRejected, '还没有配置 UC Cookie')
            .displayMessage,
        '还没有配置 UC Cookie',
      );
      expect(
        const NodePanException(NodePanErrorKind.nodeRejected).displayMessage,
        '网盘解析失败',
      );
    });

    test('nodeUnavailable 带详情时拼入展示文案（运行时失败原因透传）', () {
      const NodePanException e = NodePanException.nodeUnavailable(
        'Node 端口 58080 已被其他进程占用（健康响应 pid=111，'
        '本宿主子进程 pid=222）——请重启电脑，或在任务管理器结束对应进程后重试',
      );
      expect(e.kind, NodePanErrorKind.nodeUnavailable);
      expect(
        e.displayMessage,
        startsWith('Node 常驻系统未就绪——Node 端口 58080 已被其他进程占用'),
      );
      expect(e.displayMessage, contains('请重启电脑'));
    });
  });
}
