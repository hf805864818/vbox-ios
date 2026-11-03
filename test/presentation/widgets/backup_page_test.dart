/// 表现层 widget 测试：#B4 —— 备份 / 还原页。
///
/// 注入测试替身 [BackupService]（仅覆盖文件列表；真实采集 / 写回由
/// `test/data/datasources/local/backup_service_test.dart` 覆盖），覆盖：
///   ① 导出 Tab：9 个类目 + 敏感类目锁标记 + 导出按钮
///   ② 导入 Tab：无文件空态 / 有文件列表
///   ③ 还原参数对话框：冲突策略 + 类目
///
/// 注：`testWidgets` 运行在 FakeAsync 时钟下，真实文件 / 数据库 I/O 的
/// `Future` 不会完成（会一直挂到 10 分钟测试超时），故本文件不触碰真实
/// 文件系统；页面只依赖 [BackupService.listBackupFiles]，用替身即可。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/local/backup_manager.dart';
import 'package:vbox/data/datasources/local/backup_service.dart';
import 'package:vbox/presentation/widgets/backup_page.dart';

/// 测试替身：文件列表返回固定结果（避免 FakeAsync 下的真实 I/O）。
class _FakeBackupService extends BackupService {
  _FakeBackupService(this._files);

  final List<BackupFileInfo> _files;

  @override
  Future<List<BackupFileInfo>> listBackupFiles() async => _files;
}

void main() {
  /// 撑高视口后再挂载页面。
  ///
  /// 导出 Tab 的「9 个类目 + 口令输入 + 按钮」总高超出默认 800×600 视口，
  /// 而 `ListView` 只构建可见（含 cacheExtent）子项，末尾类目会缺席树，
  /// 导致 `find.text` 找不到 —— 故这里放大视口让全部类目一次性构建。
  ///
  /// [picked] 非空时注入「选择备份文件」替身（模拟系统文件选择器选中结果）。
  Future<void> pumpPage(WidgetTester tester, BackupService svc,
      {String? picked}) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: BackupPage(
        service: svc,
        pickBackupFile: picked == null
            ? null
            : () async => picked,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('导出 Tab：9 个类目 + 敏感锁标记 + 导出按钮', (WidgetTester tester) async {
    await pumpPage(tester, _FakeBackupService(const <BackupFileInfo>[]));

    for (final BackupCategory c in BackupCategory.values) {
      expect(find.text(c.label), findsOneWidget, reason: c.name);
    }
    expect(find.byIcon(Icons.lock_outline), findsOneWidget); // 仅网盘凭据
    expect(find.widgetWithText(FilledButton, '导出备份'), findsOneWidget);
  });

  testWidgets('导入 Tab：无备份文件 → 空态', (WidgetTester tester) async {
    await pumpPage(tester, _FakeBackupService(const <BackupFileInfo>[]));

    await tester.tap(find.text('导入还原'));
    await tester.pumpAndSettle();

    expect(find.textContaining('暂无备份文件'), findsOneWidget);
    // 对齐 iOS：空态仍提供「选择备份文件」入口（弹系统文件选择器）。
    expect(find.text('选择备份文件'), findsOneWidget);
  });

  testWidgets('导入 Tab：选择备份文件 → 打开还原对话框（对齐 iOS 弹选择器）',
      (WidgetTester tester) async {
    await pumpPage(
      tester,
      _FakeBackupService(const <BackupFileInfo>[]),
      picked: '/tmp/外部备份.vboxbak',
    );

    await tester.tap(find.text('导入还原'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择备份文件'));
    await tester.pumpAndSettle();

    expect(find.text('还原备份'), findsOneWidget, reason: '选中后直接进入还原流程');
    expect(find.textContaining('外部备份.vboxbak'), findsOneWidget);
  });

  testWidgets('导入 Tab：列出 .vboxbak 文件并可打开还原对话框', (WidgetTester tester) async {
    await pumpPage(
      tester,
      _FakeBackupService(<BackupFileInfo>[
        BackupFileInfo(
          path: '/tmp/vbox_backup_20260101_000000.vboxbak',
          name: 'vbox_backup_20260101_000000.vboxbak',
          sizeBytes: 128,
          modifiedAt: DateTime(2026, 1, 1),
        ),
      ]),
    );

    await tester.tap(find.text('导入还原'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.archive_outlined), findsOneWidget);
    expect(find.textContaining('.vboxbak'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.archive_outlined));
    await tester.pumpAndSettle();

    expect(find.text('还原备份'), findsOneWidget);
    expect(find.text('合并（保留本机，补齐备份）'), findsOneWidget);
    expect(find.text('覆盖（清空本机后写入）'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '开始还原'), findsOneWidget);
  });
}