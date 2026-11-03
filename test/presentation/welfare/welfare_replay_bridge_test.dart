/// 呈现层单测：福利重播桥分流判定（W-福2）。
///
/// 唯一真相源：iOS `ProfileView.swift` 的分流条件 ——
/// `record.laiyuan.hasPrefix("[福利]") && !record.detailua.isEmpty`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/welfare/welfare_replay_bridge.dart';

void main() {
  group('isWelfareReplayRecord', () {
    test('来源前缀 [福利] 且 detailua 非空 → 福利记录', () {
      expect(
        isWelfareReplayRecord(laiyuan: '[福利]熊猫视频', detailua: 'panda_video'),
        isTrue,
      );
    });

    test('detailua 为空白 → 非福利记录（无法重建平台定位）', () {
      expect(
        isWelfareReplayRecord(laiyuan: '[福利]熊猫视频', detailua: ''),
        isFalse,
      );
      expect(
        isWelfareReplayRecord(laiyuan: '[福利]熊猫视频', detailua: '   '),
        isFalse,
      );
    });

    test('来源前缀非 [福利] → 非福利记录', () {
      expect(
        isWelfareReplayRecord(laiyuan: '熊猫视频', detailua: 'panda_video'),
        isFalse,
      );
      expect(isWelfareReplayRecord(laiyuan: '', detailua: 'panda_video'), isFalse);
    });

    test('前缀常量与 iOS 标记一致', () {
      expect(welfareRecordPrefix, '[福利]');
    });
  });
}