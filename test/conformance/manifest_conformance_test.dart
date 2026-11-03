/// conformance 测试：远程源 manifest 契约（fixture ↔ Dart 实现）。
///
/// 消费 `conformance/fixtures/manifest_v1.json` 的用例，验证 Dart 侧
/// `RemoteManifest.fromJson` + 校验链（`hasRequiredFiles` +
/// `hasValidConfigVersion`）与本 fixture（三端唯一真相源）完全一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/remote_source/remote_manifest.dart';

void main() {
  final Map<String, Object?> fixture =
      (jsonDecode(File('conformance/fixtures/manifest_v1.json').readAsStringSync())
              as Map)
          .cast<String, Object?>();
  final List<Object?> cases = (fixture['cases'] as List).cast<Object?>();

  test('契约常量与 fixture 对齐', () {
    expect(RemoteManifest.defaultTtlSeconds, fixture['defaultTtlSeconds']);
    expect(RemoteManifest.keyAllSources, 'allSources');
    expect(
      RemoteManifest.knownFileKeys,
      List<String>.from(fixture['knownFileKeys'] as List),
    );
  });

  test('manifest 用例与 RemoteManifest 解析/校验链路一致', () {
    expect(cases, isNotEmpty);
    for (final Object? c in cases) {
      final Map<String, Object?> m = (c as Map).cast<String, Object?>();
      final RemoteManifest manifest = RemoteManifest.fromJson(
          (m['input'] as Map).cast<String, Object?>());
      final bool valid = manifest.hasRequiredFiles && manifest.hasValidConfigVersion;
      expect(valid, m['valid'], reason: 'case=${m['name']}');

      final Map<String, Object?> expected =
          (m['expected'] as Map).cast<String, Object?>();
      if (expected.containsKey('schemaVersion')) {
        expect(manifest.schemaVersion, expected['schemaVersion']);
      }
      if (expected.containsKey('configVersion')) {
        expect(manifest.configVersion, expected['configVersion']);
      }
      if (expected.containsKey('hasValidConfigVersion')) {
        expect(manifest.hasValidConfigVersion, expected['hasValidConfigVersion']);
      }
      if (expected.containsKey('hasAllSources')) {
        expect(manifest.hasRequiredFiles, expected['hasAllSources']);
      }
      if (expected.containsKey('ttlSeconds')) {
        expect(manifest.ttlSeconds, expected['ttlSeconds']);
      }
      if (expected.containsKey('forceRefresh')) {
        expect(manifest.forceRefresh, expected['forceRefresh']);
      }
      if (expected.containsKey('disabledKeys')) {
        expect(manifest.disabledKeys, expected['disabledKeys']);
      }
      if (expected.containsKey('minAppVersion')) {
        expect(manifest.minAppVersion, expected['minAppVersion']);
      }
    }
  });
}