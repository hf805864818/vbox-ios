/// UI-E4：应用生命周期 Mixin + 首页轮播自动播放生命周期行为。
///
/// 对齐 iOS：
///  - `scenePhase` / `onAppear` / `onDisappear`（PlayerViewsV2 / DoubanHomeView）；
///  - 轮播 `startAutoPlay` / `stopAutoPlay`（DoubanHomeView.swift L254-L270，4s 间隔）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/presentation/lifecycle/vbox_lifecycle_mixin.dart';
import 'package:vbox/presentation/pages/home/home_banner_carousel.dart';

/// 记录生命周期钩子触发顺序的宿主。
class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe({super.key});

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe>
    with VboxLifecycleMixin {
  final List<String> calls = <String>[];

  @override
  void onAppResumed() => calls.add('resumed');

  @override
  void onAppInactive() => calls.add('inactive');

  @override
  void onAppPaused() => calls.add('paused');

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

VodItem _vod(int i) => VodItem(
      vodId: '$i',
      vodName: '样品 $i',
      vodPic: 'https://example.com/$i.jpg',
    );

double _currentPage(WidgetTester tester) {
  final PageView pv = tester.widget<PageView>(find.byType(PageView));
  return pv.controller?.page ?? 0;
}

/// 推进一个自动播放周期：4s 触发 Timer → 0.4s 完成翻页动画（350ms easeOut）。
Future<void> _advanceOneCycle(WidgetTester tester) async {
  await tester.pump(_autoInterval);
  await tester.pump(_animDur);
}

/// 自动播放间隔（对齐 iOS 4s）。
const Duration _autoInterval = Duration(seconds: 4);

/// 翻页动画时长（对齐 iOS 0.35s easeOut）。
const Duration _animDur = Duration(milliseconds: 400);

void main() {
  group('VboxLifecycleMixin', () {
    testWidgets('resumed / inactive / paused 归一为对应钩子',
        (WidgetTester tester) async {
      final GlobalKey<_LifecycleProbeState> key =
          GlobalKey<_LifecycleProbeState>();
      await tester.pumpWidget(_host(_LifecycleProbe(key: key)));
      final _LifecycleProbeState state = key.currentState!;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.calls, <String>['resumed']);

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(state.calls, <String>['resumed', 'inactive']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(state.calls, <String>['resumed', 'inactive', 'paused']);

      // detached / hidden 同样归入 paused（进后台口径）。
      state.calls.clear();
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(state.calls, <String>['paused', 'paused']);
    });

    testWidgets('页面销毁后不再回调（observer 注销）', (WidgetTester tester) async {
      final GlobalKey<_LifecycleProbeState> key =
          GlobalKey<_LifecycleProbeState>();
      await tester.pumpWidget(_host(_LifecycleProbe(key: key)));
      final _LifecycleProbeState state = key.currentState!;
      await tester.pumpWidget(_host(const SizedBox.shrink()));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.calls, isEmpty);
    });
  });

  group('HomeBannerCarousel 自动播放（UI-E4，对齐 iOS BannerCarousel）', () {
    testWidgets('4s 自动翻页循环（到尾部回 0）', (WidgetTester tester) async {
      await tester.pumpWidget(_host(
        HomeBannerCarousel(items: <VodItem>[_vod(1), _vod(2), _vod(3)]),
      ));
      expect(_currentPage(tester), 0);

      await _advanceOneCycle(tester);
      expect(_currentPage(tester), 1, reason: '4s 后应自动翻到第 1 页');

      // 第 2 页 → 回第 0 页（循环，对齐 iOS 到尾部回 0）。
      await _advanceOneCycle(tester);
      expect(_currentPage(tester), 2);
      await _advanceOneCycle(tester);
      expect(_currentPage(tester), 0);
    });

    testWidgets('失活暂停 / 回前台恢复', (WidgetTester tester) async {
      await tester.pumpWidget(_host(
        HomeBannerCarousel(items: <VodItem>[_vod(1), _vod(2)]),
      ));

      // 失活 → 推进 8s 页码不变（对齐 iOS onDisappear stopAutoPlay）。
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump(_autoInterval * 2);
      expect(_currentPage(tester), 0);

      // 回前台 → 推进一个周期翻页（对齐 iOS onAppear startAutoPlay）。
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _advanceOneCycle(tester);
      expect(_currentPage(tester), 1);
    });

    testWidgets('单 item 不启动自动播放', (WidgetTester tester) async {
      await tester.pumpWidget(_host(
        HomeBannerCarousel(items: <VodItem>[_vod(1)]),
      ));
      await tester.pump(_autoInterval * 2);
      expect(_currentPage(tester), 0);
    });
  });
}
