/// 平台层单测：A2 网络可达性实现（探针注入，不触碰平台通道）。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/network/network_info.dart';
import 'package:vbox/platform/system/connectivity_network_info.dart';

void main() {
  group('ConnectivityNetworkInfo.hasConnection（判定语义）', () {
    test('空集 → 离线', () {
      expect(ConnectivityNetworkInfo.hasConnection(<ConnectivityResult>[]),
          isFalse);
    });

    test('仅 none → 离线', () {
      expect(
        ConnectivityNetworkInfo.hasConnection(<ConnectivityResult>[
          ConnectivityResult.none,
        ]),
        isFalse,
      );
    });

    test('wifi / mobile / ethernet / vpn → 在线', () {
      for (final ConnectivityResult r in <ConnectivityResult>[
        ConnectivityResult.wifi,
        ConnectivityResult.mobile,
        ConnectivityResult.ethernet,
        ConnectivityResult.vpn,
      ]) {
        expect(
          ConnectivityNetworkInfo.hasConnection(<ConnectivityResult>[r]),
          isTrue,
          reason: r.name,
        );
      }
    });

    test('多结果含 none 但并存其它 → 在线', () {
      expect(
        ConnectivityNetworkInfo.hasConnection(<ConnectivityResult>[
          ConnectivityResult.none,
          ConnectivityResult.wifi,
        ]),
        isTrue,
      );
    });
  });

  group('ConnectivityNetworkInfo.isConnected（探针委托）', () {
    test('探针返回 wifi → true', () async {
      final ConnectivityNetworkInfo info = ConnectivityNetworkInfo(
        probe: () async => <ConnectivityResult>[ConnectivityResult.wifi],
      );
      expect(await info.isConnected, isTrue);
    });

    test('探针返回 none → false', () async {
      final ConnectivityNetworkInfo info = ConnectivityNetworkInfo(
        probe: () async => <ConnectivityResult>[ConnectivityResult.none],
      );
      expect(await info.isConnected, isFalse);
    });

    test('实现 NetworkInfo 接口（形态隔离）', () {
      final NetworkInfo info = ConnectivityNetworkInfo(
        probe: () async => <ConnectivityResult>[ConnectivityResult.mobile],
      );
      expect(info, isA<NetworkInfo>());
    });
  });
}