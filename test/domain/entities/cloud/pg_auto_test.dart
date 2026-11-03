/// PG 自动化领域模型单测（批次 F · F-09）。
///
/// 对齐基准（唯一真相源）：iOS `AliyunPgConfig`
/// （`vbox/Services/AliyunPgConfig.swift`）与
/// `AliyunPgQrLoginView.PgPlayConfigSection`（`vbox/Views/AliyunPgQrLoginView.swift:158`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/pg_auto.dart';

void main() {
  group('PgVodQuality', () {
    test('flags 解析：4kz / 4ko 归原画，其余按 id', () {
      expect(PgVodQuality.fromFlags('4kz|auto'), PgVodQuality.original4k);
      expect(PgVodQuality.fromFlags('4ko|auto'), PgVodQuality.original4k);
      expect(PgVodQuality.fromFlags('fhd'), PgVodQuality.fhd);
      expect(PgVodQuality.fromFlags('fhd|auto'), PgVodQuality.fhd);
      expect(PgVodQuality.fromFlags('sd'), PgVodQuality.sd);
    });

    test('空 / 未知回退原画 4K（对齐 iOS 缺省 "4kz|auto"）', () {
      expect(PgVodQuality.fromFlags(''), PgVodQuality.original4k);
      expect(PgVodQuality.fromFlags(null), PgVodQuality.original4k);
      expect(PgVodQuality.fromFlags('bogus'), PgVodQuality.original4k);
    });

    test('is4kz 仅原画档为真', () {
      expect(PgVodQuality.original4k.is4kz, isTrue);
      expect(PgVodQuality.fhd.is4kz, isFalse);
    });
  });

  group('PgAutoConfig', () {
    test('契约缺省值（prefs_keys_v1.json → _group_quark_pg）', () {
      const PgAutoConfig c = PgAutoConfig.defaults;
      expect(c.enabled, isFalse);
      expect(c.isVip, isFalse);
      expect(c.threadLimit, 3);
      expect(c.threadNight, 5);
      expect(c.vodFlags, '');
      expect(c.transferDir, '');
      expect(c.autoCleanup, isFalse);
      expect(c.cleanupDelaySeconds, 60);
      expect(c.proxyPort, 58090);
    });

    test('copyWith / 相等性', () {
      const PgAutoConfig base = PgAutoConfig.defaults;
      final PgAutoConfig next = base.copyWith(enabled: true, threadLimit: 8);
      expect(next.enabled, isTrue);
      expect(next.threadLimit, 8);
      expect(next.threadNight, base.threadNight);
      expect(next == base.copyWith(enabled: true, threadLimit: 8), isTrue);
      expect(next == base, isFalse);
    });
  });

  group('PgAutoRules · 线程（对齐 iOS currentThreadLimit）', () {
    test('非 VIP 恒为 1（忽略线程配置）', () {
      final PgAutoConfig c = PgAutoConfig.defaults.copyWith(
        isVip: false,
        threadLimit: 32,
        threadNight: 16,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 12)),
        1,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 20)),
        1,
      );
    });

    test('VIP 白天取 threadLimit，夜间取 threadNight', () {
      final PgAutoConfig c = PgAutoConfig.defaults.copyWith(
        isVip: true,
        threadLimit: 32,
        threadNight: 16,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 12)),
        32,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 19)),
        16,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 22, 59)),
        16,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 23)),
        32,
      );
    });

    test('自定义夜间窗口', () {
      final PgAutoConfig c =
          PgAutoConfig.defaults.copyWith(isVip: true, threadLimit: 4, threadNight: 9);
      expect(
        PgAutoRules.currentThreadLimit(
          c,
          now: DateTime(2026, 10, 3, 8),
          startHour: 7,
          endHour: 9,
        ),
        9,
      );
    });

    test('线程下限 1（对齐 iOS Stepper 下界）', () {
      final PgAutoConfig c = PgAutoConfig.defaults.copyWith(
        isVip: true,
        threadLimit: 0,
        threadNight: 0,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 12)),
        1,
      );
      expect(
        PgAutoRules.currentThreadLimit(c, now: DateTime(2026, 10, 3, 20)),
        1,
      );
    });

    test('isNightWindow 边界：19:00 起（含）至 23:00 止（不含）', () {
      expect(PgAutoRules.isNightWindow(DateTime(2026, 10, 3, 18, 59)), isFalse);
      expect(PgAutoRules.isNightWindow(DateTime(2026, 10, 3, 19)), isTrue);
      expect(PgAutoRules.isNightWindow(DateTime(2026, 10, 3, 22, 59)), isTrue);
      expect(PgAutoRules.isNightWindow(DateTime(2026, 10, 3, 23)), isFalse);
    });
  });

  group('PgAutoRules · 画质 / 转存 / 清理 / 代理', () {
    test('resolvedVodFlags：空串回退 4kz|auto', () {
      expect(
        PgAutoRules.resolvedVodFlags(PgAutoConfig.defaults),
        '4kz|auto',
      );
      expect(
        PgAutoRules.resolvedVodFlags(PgAutoConfig.defaults.copyWith(vodFlags: ' hd ')),
        'hd',
      );
      expect(PgAutoRules.is4kz(PgAutoConfig.defaults), isTrue);
      expect(
        PgAutoRules.vodQuality(PgAutoConfig.defaults.copyWith(vodFlags: 'sd')),
        PgVodQuality.sd,
      );
    });

    test('resolvedTransferDir：空串回退 vbox_pg_temp', () {
      expect(
        PgAutoRules.resolvedTransferDir(PgAutoConfig.defaults),
        'vbox_pg_temp',
      );
      expect(
        PgAutoRules.resolvedTransferDir(
          PgAutoConfig.defaults.copyWith(transferDir: ' 我的临时 '),
        ),
        '我的临时',
      );
    });

    test('cleanupDelay：秒 → Duration，负值收敛为 0', () {
      expect(
        PgAutoRules.cleanupDelay(PgAutoConfig.defaults),
        const Duration(seconds: 60),
      );
      expect(
        PgAutoRules.cleanupDelay(
          PgAutoConfig.defaults.copyWith(cleanupDelaySeconds: -5),
        ),
        Duration.zero,
      );
    });

    test('shouldScheduleCleanup：仅「启用 + 自动清理」同时为真', () {
      const PgAutoConfig off = PgAutoConfig.defaults;
      expect(PgAutoRules.shouldScheduleCleanup(off), isFalse);
      expect(
        PgAutoRules.shouldScheduleCleanup(off.copyWith(enabled: true)),
        isFalse,
      );
      expect(
        PgAutoRules.shouldScheduleCleanup(off.copyWith(autoCleanup: true)),
        isFalse,
      );
      expect(
        PgAutoRules.shouldScheduleCleanup(
          off.copyWith(enabled: true, autoCleanup: true),
        ),
        isTrue,
      );
    });

    test('proxyUrl 由端口拼装（对齐 iOS aliproxyUrl）', () {
      expect(
        PgAutoRules.proxyUrl(PgAutoConfig.defaults),
        'http://127.0.0.1:58090',
      );
      expect(
        PgAutoRules.proxyUrl(PgAutoConfig.defaults.copyWith(proxyPort: 10078)),
        'http://127.0.0.1:10078',
      );
    });
  });

  group('PgCredentialMark（pg_source / qr_scan）', () {
    test('mark 打标后 isPgCredential 为真（不改写入参）', () {
      const Map<String, String> extra = <String, String>{'is_vip': 'true'};
      final Map<String, String> marked = PgCredentialMark.mark(extra);
      expect(marked[PgCredentialMark.sourceKey], 'qr_scan');
      expect(marked['is_vip'], 'true');
      expect(extra.containsKey(PgCredentialMark.sourceKey), isFalse);
      expect(PgCredentialMark.isPgCredential(marked), isTrue);
      expect(PgCredentialMark.isPgCredential(extra), isFalse);
    });

    test('凭据对象判定（对齐 iOS isPgCredential）', () {
      final CloudDriveCredential plain = CloudDriveCredential(
        driveType: CloudDriveType.ali.id,
        updatedAt: DateTime.utc(2026, 10, 3),
      );
      expect(PgCredentialMark.of(plain), isFalse);
      final CloudDriveCredential pg = plain.copyWith(
        extra: PgCredentialMark.mark(plain.extra),
      );
      expect(PgCredentialMark.of(pg), isTrue);
    });
  });
}
