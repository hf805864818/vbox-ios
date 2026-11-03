/// 领域层单测：版本分发清单模型（批次 K · K-更2）。
///
/// 覆盖：`version.json` 解析、GitHub Releases 归一、版本清洗 / 数值化比较、
/// 更新说明拆条去前缀、平台契约值与资产选择。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/update/update_manifest.dart';

void main() {
  group('cleanVersion / compareVersions（对齐 iOS .numeric）', () {
    test('清洗：去首 v、截断预发布后缀、仅保留数字与点', () {
      expect(cleanVersion('v3.700-beta'), '3.700');
      expect(cleanVersion('V3.1716.0'), '3.1716.0');
      expect(cleanVersion('  3.10.2  '), '3.10.2');
    });

    test('数值化比较：3.10 > 3.9（避免字符串比较误判）', () {
      expect(compareVersions('3.10', '3.9'), greaterThan(0));
      expect(compareVersions('3.9', '3.10'), lessThan(0));
      expect(compareVersions('3.1716.0', '3.1716'), 0);
    });

    test('缺失段按 0 补齐', () {
      expect(compareVersions('3.1716', '3.1716.0'), 0);
      expect(compareVersions('3.1716.1', '3.1716'), greaterThan(0));
    });
  });

  group('UpdateManifest.fromJson（version.json）', () {
    test('解析版本 / 构建号 / 说明 / 资产', () {
      final UpdateManifest? m = UpdateManifest.fromJson(<String, Object?>{
        'version': 'v3.1716.0',
        'build': 1716,
        'notes': <String>['修复 A', '新增 B'],
        'releasePageUrl': 'https://example.com/rel',
        'publishedAt': '2026-10-05T10:00:00Z',
        'assets': <Object>[
          <String, Object?>{
            'platform': 'android-arm64',
            'url': 'https://example.com/vbox-arm64.apk',
            'sha256': 'ABCDEF',
            'size': 12345678,
          },
          <String, Object?>{'platform': 'macos', 'url': 'https://example.com/vbox.dmg'},
          <String, Object?>{'platform': 'bogus'}, // 无效：缺 url / 未知平台
        ],
      });
      expect(m, isNotNull);
      expect(m!.version, '3.1716.0');
      expect(m.build, 1716);
      expect(m.notes, <String>['修复 A', '新增 B']);
      expect(m.releasePageUrl, 'https://example.com/rel');
      expect(m.publishedAt, isNotNull);
      expect(m.assets.length, 2);
      final UpdateAsset? a = m.assetFor(UpdatePlatform.androidArm64);
      expect(a, isNotNull);
      expect(a!.sha256, 'abcdef'); // 归一为小写
      expect(a.sizeBytes, 12345678);
      expect(m.assetFor(UpdatePlatform.windows), isNull);
    });

    test('无 version → 无效返回 null', () {
      expect(UpdateManifest.fromJson(<String, Object?>{'notes': 'x'}), isNull);
      expect(UpdateManifest.fromJson('nope'), isNull);
    });

    test('isNewerThan 语义', () {
      const UpdateManifest m = UpdateManifest(version: '3.1716.0');
      expect(m.isNewerThan('3.1621.0'), isTrue);
      expect(m.isNewerThan('3.1716.0'), isFalse);
      expect(m.isNewerThan('3.2000.0'), isFalse);
    });
  });

  group('UpdateManifest.fromGitHubRelease（GitHub Releases 归一）', () {
    test('tag_name / body / assets 映射与 digest 解析', () {
      final UpdateManifest? m =
          UpdateManifest.fromGitHubRelease(<String, Object?>{
        'tag_name': 'v3.9999.0',
        'body': '## 更新\n1、修复崩溃\n- 新增倍速\n---\n',
        'html_url': 'https://github.com/vbox-Ai/app/releases/tag/v3.9999.0',
        'published_at': '2026-10-05T10:00:00Z',
        'assets': <Object>[
          <String, Object?>{
            'name': 'vbox-arm64.apk',
            'browser_download_url': 'https://github.com/x/y/vbox-arm64.apk',
            'size': 10,
            'digest': 'sha256:DEADBEEF',
          },
          <String, Object?>{
            'name': 'vbox-v7a.apk',
            'browser_download_url': 'https://github.com/x/y/vbox-v7a.apk',
          },
          <String, Object?>{
            'name': 'vbox-setup.exe',
            'browser_download_url': 'https://github.com/x/y/vbox-setup.exe',
          },
          <String, Object?>{
            'name': 'vbox.dmg',
            'browser_download_url': 'https://github.com/x/y/vbox.dmg',
          },
          <String, Object?>{
            'name': 'checksums.txt',
            'browser_download_url': 'https://github.com/x/y/checksums.txt',
          },
        ],
      });
      expect(m, isNotNull);
      expect(m!.version, '3.9999.0');
      expect(m.notes, <String>['修复崩溃', '新增倍速']);
      expect(m.assets.length, 4); // checksums.txt 不识别 → 丢弃
      expect(m.assetFor(UpdatePlatform.androidArm64)!.sha256, 'deadbeef');
      expect(m.assetFor(UpdatePlatform.androidV7a), isNotNull);
      expect(m.assetFor(UpdatePlatform.windows), isNotNull);
      expect(m.assetFor(UpdatePlatform.macos), isNotNull);
    });
  });

  group('UpdatePlatform 契约值', () {
    test('fromId 往返与未知回退', () {
      expect(UpdatePlatform.fromId('android-arm64'), UpdatePlatform.androidArm64);
      expect(UpdatePlatform.fromId('android-v7a'), UpdatePlatform.androidV7a);
      expect(UpdatePlatform.fromId('windows'), UpdatePlatform.windows);
      expect(UpdatePlatform.fromId('macos'), UpdatePlatform.macos);
      expect(UpdatePlatform.fromId('linux'), isNull);
      expect(UpdatePlatform.fromId(null), isNull);
    });
  });

  group('normalizeNotes', () {
    test('多行字符串拆条 + 去 md 前缀 + 去标题/分隔线', () {
      expect(
        normalizeNotes('## 标题\n1、第一条\n2. 第二条\n- 第三条\n* 第四条\n---\n\n'),
        <String>['第一条', '第二条', '第三条', '第四条'],
      );
    });

    test('列表输入直取', () {
      expect(normalizeNotes(<String>['  ', '项 A']), <String>['项 A']);
    });
  });
}