/// 网盘播放错误分档集中映射层单测（F-P14）。
///
/// 对齐基准（唯一真相源）：
/// - iOS `DriveError`（`vbox/Services/CloudDriveManager.swift:10575-10604`）——
///   7 档 `errorDescription` 通用文案；
/// - iOS 播放站点分档收敛（`vbox/Views/PlayerViewsV2.swift:3669-3679`，百度分支
///   `2315-2322`）—— `noPlayURL` 直出 reason / `invalidResponse` 作「服务器响应
///   异常」/ `notImplemented` 作「暂不支持」；
/// - iOS `NodePanError.errorDescription`（`vbox/Services/NodePanResolver.swift:204-213`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/cloud/node_pan.dart';
import 'package:vbox/platform/player/drive_error.dart';
import 'package:vbox/platform/player/drive_error_mapper.dart';
import 'package:vbox/platform/player/pan_player.dart';

void main() {
  group('DriveError.description（逐档对齐 iOS DriveError.errorDescription）', () {
    test('noPlayURL 拼「无法获取播放地址：<reason>」', () {
      expect(
        const DriveError.noPlayURL('夸克: download_url 和转码地址均为空').description,
        '无法获取播放地址：夸克: download_url 和转码地址均为空',
      );
    });

    test('invalidResponse / invalidShareURL / saveFailed / notImplemented', () {
      expect(const DriveError.invalidResponse().description, '服务器响应无效');
      expect(const DriveError.invalidShareURL().description, '无效的分享链接');
      expect(const DriveError.saveFailed().description, '转存失败');
      expect(const DriveError.notImplemented().description, '该网盘暂不支持');
    });

    test('tokenNotConfigured 拼「未配置<name> Token」', () {
      expect(
        const DriveError.tokenNotConfigured('阿里云盘').description,
        '未配置阿里云盘 Token',
      );
    });

    test('nodeNotReady 拼「<name> 需要 Node 常驻系统，当前未就绪，请稍后重试」', () {
      expect(
        const DriveError.nodeNotReady('夸克Node').description,
        '夸克Node 需要 Node 常驻系统，当前未就绪，请稍后重试',
      );
    });
  });

  group('DriveError.playbackMessage（对齐 iOS 播放站点档）', () {
    test('noPlayURL 直出 reason（不加前缀）', () {
      expect(
        const DriveError.noPlayURL('该资源已在夸克网盘中失效').playbackMessage,
        '该资源已在夸克网盘中失效',
      );
    });

    test('invalidResponse 作「服务器响应异常」、notImplemented 作「暂不支持」', () {
      expect(const DriveError.invalidResponse().playbackMessage, '服务器响应异常');
      expect(const DriveError.notImplemented().playbackMessage, '暂不支持');
    });

    test('其余档与通用文案一致', () {
      expect(const DriveError.invalidShareURL().playbackMessage, '无效的分享链接');
      expect(const DriveError.saveFailed().playbackMessage, '转存失败');
      expect(
        const DriveError.tokenNotConfigured('百度网盘').playbackMessage,
        '未配置百度网盘 Token',
      );
    });
  });

  group('DriveErrorMapper.messageOf（集中映射）', () {
    test('DriveError → 播放站点档', () {
      expect(
        DriveErrorMapper.messageOf(const DriveError.notImplemented()),
        '暂不支持',
      );
      expect(
        DriveErrorMapper.messageOf(const DriveError.invalidResponse()),
        '服务器响应异常',
      );
    });

    test('PanPlayException（携带分档）→ 播放站点档', () {
      expect(
        DriveErrorMapper.messageOf(
          PanPlayException.fromDrive(const DriveError.notImplemented()),
        ),
        '暂不支持',
      );
      expect(
        DriveErrorMapper.messageOf(
          PanPlayException.fromDrive(const DriveError.tokenNotConfigured('百度网盘')),
        ),
        '未配置百度网盘 Token',
      );
    });

    test('PanPlayException（自由文案）→ 直出 message', () {
      expect(
        DriveErrorMapper.messageOf(const PanPlayException('播放地址为空')),
        '播放地址为空',
      );
    });

    test('NodePanException → 逐档对齐 iOS NodePanError.errorDescription', () {
      expect(
        DriveErrorMapper.messageOf(const NodePanException.nodeUnavailable()),
        'Node 常驻系统未就绪，请稍后重试',
      );
      expect(
        DriveErrorMapper.messageOf(
          const NodePanException(NodePanErrorKind.invalidShareURL),
        ),
        '无法识别的分享链接',
      );
      expect(
        DriveErrorMapper.messageOf(
          const NodePanException(NodePanErrorKind.nodeRejected, '解析响应 JSON 失败'),
        ),
        '解析响应 JSON 失败',
      );
    });

    test('未知异常 → toString 兜底', () {
      expect(DriveErrorMapper.messageOf(StateError('boom')), contains('boom'));
    });
  });

  group('PanPlayException.fromDrive', () {
    test('message 取通用文案，driveError 保留分档', () {
      final PanPlayException e =
          PanPlayException.fromDrive(const DriveError.notImplemented());
      expect(e.message, '该网盘暂不支持');
      expect(e.driveError?.kind, DriveErrorKind.notImplemented);
    });

    test('自由构造无分档', () {
      const PanPlayException e = PanPlayException('自定义');
      expect(e.driveError, isNull);
    });
  });
}