/// 网盘领域模型单测（批次 F · F-01 / F-03 / F-06）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager.DriveType` /
/// `CloudDriveAuthManager`（`CloudDriveAuthType` / `CloudDriveAuthState` /
/// `CloudDriveCredential`）/ `CloudDriveSortManager.defaultOrder`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';

CloudDriveCredential _cred({
  String driveType = 'ali',
  String? accessToken,
  String? refreshToken,
  String? cookie,
  String? userName,
  DateTime? expiresAt,
  DateTime? lastCheckedAt,
  CloudDriveAuthState state = CloudDriveAuthState.unknown,
  Map<String, String> extra = const <String, String>{},
}) =>
    CloudDriveCredential(
      driveType: driveType,
      updatedAt: DateTime(2026, 1, 1, 12),
      accessToken: accessToken,
      refreshToken: refreshToken,
      cookie: cookie,
      userName: userName,
      expiresAt: expiresAt,
      lastCheckedAt: lastCheckedAt,
      state: state,
      extra: extra,
    );

void main() {
  group('CloudDriveType', () {
    test('15 项，契约 id 逐档对齐 iOS rawValue', () {
      expect(CloudDriveType.values.length, 15);
      expect(CloudDriveType.ali.id, 'ali');
      expect(CloudDriveType.quark.id, 'quark');
      expect(CloudDriveType.quarkNode.id, 'quarkNode');
      expect(CloudDriveType.baidu.id, 'baidu');
      expect(CloudDriveType.baiduNode.id, 'baiduNode');
      expect(CloudDriveType.one15.id, '115');
      expect(CloudDriveType.uc.id, 'uc');
      expect(CloudDriveType.ucNode.id, 'ucNode');
      expect(CloudDriveType.pan123.id, '123pan');
      expect(CloudDriveType.pan139.id, '139pan');
      expect(CloudDriveType.pan189.id, '189pan');
      expect(CloudDriveType.xunlei.id, 'xunlei');
      expect(CloudDriveType.guangya.id, 'guangya');
      expect(CloudDriveType.woniu4k.id, 'woniu4k');
      expect(CloudDriveType.bilibili.id, 'bilibili');
    });

    test('fromId：命中返回枚举，未知/空/null 返回 null', () {
      expect(CloudDriveType.fromId('115'), CloudDriveType.one15);
      expect(CloudDriveType.fromId('123pan'), CloudDriveType.pan123);
      expect(CloudDriveType.fromId('nope'), isNull);
      expect(CloudDriveType.fromId(''), isNull);
      expect(CloudDriveType.fromId(null), isNull);
    });

    test('fromDisplayName：命中中文名，未知/空/null 返回 null', () {
      expect(CloudDriveType.fromDisplayName('夸克网盘'), CloudDriveType.quark);
      expect(CloudDriveType.fromDisplayName('哔哩哔哩'), CloudDriveType.bilibili);
      expect(CloudDriveType.fromDisplayName('不存在'), isNull);
      expect(CloudDriveType.fromDisplayName(''), isNull);
      expect(CloudDriveType.fromDisplayName(null), isNull);
    });

    test('派生盘仅 3 家 Node 盘（夸克/UC/百度 Node）', () {
      expect(
        CloudDriveType.values
            .where((CloudDriveType t) => t.isNodeDerived)
            .toSet(),
        <CloudDriveType>{
          CloudDriveType.quarkNode,
          CloudDriveType.ucNode,
          CloudDriveType.baiduNode,
        },
      );
    });

    test('fromShareUrl：各网盘域名命中（E-12 播放器展开选集）', () {
      expect(CloudDriveType.fromShareUrl('https://www.alipan.com/s/abc'),
          CloudDriveType.ali);
      expect(CloudDriveType.fromShareUrl('https://pan.quark.cn/s/abc'),
          CloudDriveType.quark);
      expect(CloudDriveType.fromShareUrl('https://pan.baidu.com/s/abc'),
          CloudDriveType.baidu);
      expect(CloudDriveType.fromShareUrl('https://115.com/s/abc'),
          CloudDriveType.one15);
      expect(CloudDriveType.fromShareUrl('https://drive.uc.cn/s/abc'),
          CloudDriveType.uc);
      expect(CloudDriveType.fromShareUrl('https://www.123pan.com/s/abc'),
          CloudDriveType.pan123);
      expect(CloudDriveType.fromShareUrl('https://caiyun.139.com/w/abc'),
          CloudDriveType.pan139);
      expect(CloudDriveType.fromShareUrl('https://cloud.189.cn/t/abc'),
          CloudDriveType.pan189);
      expect(CloudDriveType.fromShareUrl('https://pan.xunlei.com/s/abc'),
          CloudDriveType.xunlei);
      expect(CloudDriveType.fromShareUrl('https://www.bilibili.com/video/abc'),
          CloudDriveType.bilibili);
    });

    test('fromShareUrl：大小写不敏感 + 无法识别/空/null 返回 null', () {
      expect(CloudDriveType.fromShareUrl('HTTPS://PAN.QUARK.CN/s/abc'),
          CloudDriveType.quark);
      expect(CloudDriveType.fromShareUrl('https://cdn.example.com/v.m3u8'),
          isNull);
      expect(CloudDriveType.fromShareUrl(''), isNull);
      expect(CloudDriveType.fromShareUrl(null), isNull);
    });

    test('defaultSortOrder 8 家且顺序对齐 iOS defaultOrder', () {
      expect(CloudDriveType.defaultSortOrder, <CloudDriveType>[
        CloudDriveType.quark,
        CloudDriveType.uc,
        CloudDriveType.baidu,
        CloudDriveType.ali,
        CloudDriveType.one15,
        CloudDriveType.pan123,
        CloudDriveType.pan139,
        CloudDriveType.pan189,
      ]);
    });
  });

  group('CloudDriveAuthType', () {
    test('id 集合 + fromId 未知回退 manual', () {
      expect(
        CloudDriveAuthType.values
            .map((CloudDriveAuthType e) => e.id)
            .toList(),
        <String>['manual', 'qr', 'webView', 'oauth'],
      );
      expect(CloudDriveAuthType.fromId('webView'), CloudDriveAuthType.webView);
      expect(CloudDriveAuthType.fromId('nope'), CloudDriveAuthType.manual);
      expect(CloudDriveAuthType.fromId(null), CloudDriveAuthType.manual);
    });
  });

  group('CloudDriveAuthState', () {
    test('displayText 逐档对齐 iOS', () {
      expect(CloudDriveAuthState.notAuthorized.displayText, '未授权');
      expect(CloudDriveAuthState.valid.displayText, '正常');
      expect(CloudDriveAuthState.expiringSoon.displayText, '即将过期');
      expect(CloudDriveAuthState.expired.displayText, '已过期');
      expect(CloudDriveAuthState.invalid.displayText, '授权失效');
      expect(CloudDriveAuthState.unknown.displayText, '未检测');
    });

    test('isReady 仅 valid 为真；fromId 未知/空回退 unknown', () {
      for (final CloudDriveAuthState s in CloudDriveAuthState.values) {
        expect(s.isReady, s == CloudDriveAuthState.valid, reason: s.id);
      }
      expect(CloudDriveAuthState.fromId('expired'), CloudDriveAuthState.expired);
      expect(CloudDriveAuthState.fromId('nope'), CloudDriveAuthState.unknown);
      expect(CloudDriveAuthState.fromId(null), CloudDriveAuthState.unknown);
    });
  });

  group('CloudDriveCredential', () {
    test('primarySecret 优先级 refreshToken > cookie > accessToken（空串忽略）', () {
      expect(
        _cred(refreshToken: 'r', cookie: 'c', accessToken: 'a').primarySecret,
        'r',
      );
      expect(_cred(cookie: 'c', accessToken: 'a').primarySecret, 'c');
      expect(_cred(accessToken: 'a').primarySecret, 'a');
      expect(_cred(refreshToken: '', cookie: '', accessToken: '').primarySecret,
          isNull);
      expect(_cred().primarySecret, isNull);
      expect(_cred().hasSecret, isFalse);
      expect(_cred(cookie: 'c').hasSecret, isTrue);
    });

    test('isReady = state.valid 且持有密钥', () {
      expect(
        _cred(state: CloudDriveAuthState.valid, cookie: 'c').isReady,
        isTrue,
      );
      expect(
        _cred(state: CloudDriveAuthState.valid).isReady,
        isFalse,
      );
      expect(
        _cred(state: CloudDriveAuthState.expired, cookie: 'c').isReady,
        isFalse,
      );
    });

    test('displayName 优先 userName，否则「已授权账号」', () {
      expect(_cred(userName: '张三').displayName, '张三');
      expect(_cred(userName: '').displayName, '已授权账号');
      expect(_cred().displayName, '已授权账号');
    });

    test('type 由 driveType 反解', () {
      expect(_cred(driveType: 'baidu').type, CloudDriveType.baidu);
      expect(_cred(driveType: 'bad').type, isNull);
    });

    test('copyWith 覆盖 lastCheckedAt 且保留其余字段', () {
      final CloudDriveCredential base = _cred(
        driveType: 'baidu',
        cookie: 'BDUSS=b; STOKEN=s',
        userName: '李四',
        state: CloudDriveAuthState.valid,
      );
      final CloudDriveCredential next =
          base.copyWith(lastCheckedAt: DateTime(2026, 2, 3, 9, 8));
      expect(next.driveType, 'baidu');
      expect(next.cookie, 'BDUSS=b; STOKEN=s');
      expect(next.userName, '李四');
      expect(next.state, CloudDriveAuthState.valid);
      expect(next.updatedAt, base.updatedAt);
      expect(next.lastCheckedAt, DateTime(2026, 2, 3, 9, 8));
    });

    test('toJson / fromJson 往返一致', () {
      final CloudDriveCredential src = CloudDriveCredential(
        driveType: 'quark',
        updatedAt: DateTime(2026, 1, 2, 3, 4, 5),
        authType: CloudDriveAuthType.qr,
        accessToken: 'at',
        cookie: 'k=v',
        userId: 'u1',
        userName: '王五',
        expiresAt: DateTime(2026, 6, 1, 8),
        lastCheckedAt: DateTime(2026, 1, 2, 3),
        state: CloudDriveAuthState.valid,
        statusMessage: 'ok',
        extra: <String, String>{'token': 't'},
      );
      final CloudDriveCredential back =
          CloudDriveCredential.fromJson(src.toJson());
      expect(back.driveType, src.driveType);
      expect(back.authType, src.authType);
      expect(back.accessToken, src.accessToken);
      expect(back.cookie, src.cookie);
      expect(back.userId, src.userId);
      expect(back.userName, src.userName);
      expect(back.expiresAt, src.expiresAt);
      expect(back.updatedAt, src.updatedAt);
      expect(back.lastCheckedAt, src.lastCheckedAt);
      expect(back.state, src.state);
      expect(back.statusMessage, src.statusMessage);
      expect(back.extra, src.extra);
    });

    test('fromJson 缺字段回退（driveType 空 / manual / unknown / 空 extra）', () {
      final CloudDriveCredential back =
          CloudDriveCredential.fromJson(<String, dynamic>{});
      expect(back.driveType, '');
      expect(back.authType, CloudDriveAuthType.manual);
      expect(back.state, CloudDriveAuthState.unknown);
      expect(back.extra, isEmpty);
      expect(back.updatedAt,
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect(back.expiresAt, isNull);
      expect(back.lastCheckedAt, isNull);
    });
  });

  group('NodeRuntimeStatus', () {
    test('detailText 逐档（就绪带端口 / 内存告警 / 失败取 detail）', () {
      expect(
        const NodeRuntimeStatus(state: NodeRuntimeState.ready, port: 58080)
            .detailText,
        '端口 58080 · 网盘解析链路可用',
      );
      expect(
        const NodeRuntimeStatus(state: NodeRuntimeState.memoryWarning)
            .detailText,
        'Node 仍可用，建议重启 App 释放内存',
      );
      expect(
        const NodeRuntimeStatus(
          state: NodeRuntimeState.failed,
          detail: '端口占用',
        ).detailText,
        '端口占用',
      );
      expect(
        const NodeRuntimeStatus(state: NodeRuntimeState.failed).detailText,
        'Node 服务启动失败',
      );
      expect(
        const NodeRuntimeStatus(state: NodeRuntimeState.crashed).detailText,
        'Node 服务已停止，请重启 App 恢复',
      );
      expect(
        const NodeRuntimeStatus(state: NodeRuntimeState.starting).detailText,
        'Node 引擎正在拉起，请稍候…',
      );
      expect(
        const NodeRuntimeStatus(state: NodeRuntimeState.stopped).detailText,
        '等待启动（App 启动后自动拉起）',
      );
      expect(const NodeRuntimeStatus().detailText, '状态：未知');
      expect(
        const NodeRuntimeStatus(
          state: NodeRuntimeState.unknown,
          detail: 'RPC 无响应',
        ).detailText,
        '状态：RPC 无响应',
      );
    });

    test('NodeRuntimeState 分档谓词', () {
      expect(NodeRuntimeState.ready.isReady, isTrue);
      expect(NodeRuntimeState.memoryWarning.isReady, isFalse);
      expect(NodeRuntimeState.failed.isError, isTrue);
      expect(NodeRuntimeState.crashed.isError, isTrue);
      expect(NodeRuntimeState.stopped.isPending, isTrue);
      expect(NodeRuntimeState.starting.isPending, isTrue);
      expect(NodeRuntimeState.ready.isPending, isFalse);
    });
  });
}
