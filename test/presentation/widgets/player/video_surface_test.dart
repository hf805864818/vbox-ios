/// Wave A · R-渲1：视频输出面组件（Texture 承载 / 纵横比自适应 / 无纹理占位）。
/// UI-E2：画面拉伸模式（填充 / 适应 / 拉伸，对齐 iOS VideoGravityMode）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/presentation/theme/tokens/colors.dart';
import 'package:vbox/presentation/widgets/player/video_surface.dart';

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(width: 400, height: 300, child: child),
    );

void main() {
  testWidgets('无纹理 → 深色占位（避免被误判为黑屏故障）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const VideoSurface()));
    expect(find.byType(Texture), findsNothing);
    final ColoredBox box = tester.widget<ColoredBox>(find.byType(ColoredBox));
    expect(box.color, VboxColors.playerBackground);
  });

  // 3.1890 起：纹理不再由 AspectRatio 布局，而是「按像素预算定尺寸 + FittedBox
  // 视觉缩放」（见 video_surface.dart 的 kMaxTextureLongSide）。契约不变——
  // 仍按视频纵横比居中留边，只是缩放交给合成器。
  testWidgets('有纹理 + 已知纵横比 → 纹理盒按比例、contain 缩放', (WidgetTester tester) async {
    await tester.pumpWidget(
        _host(const VideoSurface(textureId: 7, aspectRatio: 16 / 9)));
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);

    final FittedBox fitted = tester.widget<FittedBox>(find.byType(FittedBox));
    expect(fitted.fit, BoxFit.contain);

    // 纹理自身布局盒必须维持视频纵横比（16:9），否则画面会被拉伸。
    final Finder box = find.byKey(const ValueKey<String>('vbox-texture-budget'));
    final Size size = tester.getSize(box);
    expect(size.width / size.height, closeTo(16 / 9, 1e-3));
  });

  testWidgets('有纹理 + 未知/非法纵横比 → 铺满（无 AspectRatio）', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const VideoSurface(textureId: 3, aspectRatio: 0)));
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 3);
    expect(find.byType(AspectRatio), findsNothing);
  });

  group('UI-E2 画面拉伸模式', () {
    test('VideoGravityMode 三档对齐 iOS（声明序 / 展示名 / 循环切换）', () {
      // 声明序 = iOS CaseIterable 序：填充 → 适应 → 拉伸。
      expect(VideoGravityMode.values, <VideoGravityMode>[
        VideoGravityMode.aspectFill,
        VideoGravityMode.aspectFit,
        VideoGravityMode.resize,
      ]);
      // 展示名 = iOS rawValue。
      expect(VideoGravityMode.aspectFill.displayName, '填充');
      expect(VideoGravityMode.aspectFit.displayName, '适应');
      expect(VideoGravityMode.resize.displayName, '拉伸');
      // cycle 对齐 iOS cycleVideoGravity()。
      expect(VideoGravityMode.aspectFill.cycle(), VideoGravityMode.aspectFit);
      expect(VideoGravityMode.aspectFit.cycle(), VideoGravityMode.resize);
      expect(VideoGravityMode.resize.cycle(), VideoGravityMode.aspectFill);
    });

    testWidgets('适应（缺省）→ contain 缩放留黑边（对齐 resizeAspect）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VideoSurface(
        textureId: 1,
        aspectRatio: 16 / 9,
      )));
      // 3.1890：布局由 AspectRatio 改为「预算尺寸 + FittedBox」，缩放模式语义不变。
      final FittedBox fitted = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fitted.fit, BoxFit.contain);
      expect(find.byType(AspectRatio), findsNothing);
    });

    testWidgets('填充 → FittedBox cover 铺满裁切（对齐 resizeAspectFill）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VideoSurface(
        textureId: 1,
        aspectRatio: 16 / 9,
        fit: BoxFit.cover,
      )));
      final FittedBox fitted = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fitted.fit, BoxFit.cover);
      expect(find.byType(AspectRatio), findsNothing);
    });

    testWidgets('拉伸 → FittedBox fill 强制适配（对齐 resize）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VideoSurface(
        textureId: 1,
        aspectRatio: 16 / 9,
        fit: BoxFit.fill,
      )));
      final FittedBox fitted = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fitted.fit, BoxFit.fill);
    });
  });
}