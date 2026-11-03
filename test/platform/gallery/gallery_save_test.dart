/// 保存到相册桥单测（批次 E · E1-1）。
///
/// 对齐基准：iOS `DownloadOverlayViews.swift` performSaveToPhotos / convertAndSaveToPhotos；
/// 错误码 `PERMISSION_DENIED` / `SAVE_FAILED` 由原生侧返回。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/gallery/gallery_save.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.vbox.player/gallery_save');
  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger().setMockMethodCallHandler(channel, null));

  test('isSupported：桌面/测试环境非 Android → false', () {
    // 测试宿主为桌面平台，非 Android。
    expect(Platform.isAndroid, isFalse);
    expect(GallerySaver.isSupported, isFalse);
  });

  test('save：透传 path/name 并返回入库标识', () async {
    MethodCall? seen;
    messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
      seen = call;
      return 'content://media/external/video/media/42';
    });

    final String saved = await GallerySaver.save(
      filePath: '/data/cache/a.ts',
      displayName: 'a.mp4',
    );

    expect(seen?.method, 'save');
    expect((seen?.arguments as Map<Object?, Object?>)['path'], '/data/cache/a.ts');
    expect((seen?.arguments as Map<Object?, Object?>?)?['name'], 'a.mp4');
    expect(saved, 'content://media/external/video/media/42');
  });

  test('save：原生 PlatformException → GallerySaveException（保留错误码）', () async {
    messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'PERMISSION_DENIED', message: '无存储权限');
    });

    await expectLater(
      GallerySaver.save(filePath: '/x/a.ts', displayName: 'a'),
      throwsA(
        isA<GallerySaveException>()
            .having((GallerySaveException e) => e.code, 'code', 'PERMISSION_DENIED')
            .having((GallerySaveException e) => e.message, 'message', '无存储权限'),
      ),
    );
  });

  test('save：原生返回空 → 空串（不抛）', () async {
    messenger().setMockMethodCallHandler(channel, (MethodCall call) async => null);
    expect(await GallerySaver.save(filePath: '/x/a.ts', displayName: 'a'), '');
  });

  test('GallerySaveException.toString 含码与描述', () {
    const GallerySaveException e = GallerySaveException('SAVE_FAILED', '转换失败');
    expect(e.toString(), contains('SAVE_FAILED'));
    expect(e.toString(), contains('转换失败'));
  });
}
