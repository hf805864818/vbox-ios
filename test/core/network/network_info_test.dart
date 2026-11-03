/// 核心层单测：NetworkInfo 抽象与 AlwaysOnline 默认实现（A2 收尾）。
///
/// 覆盖：默认实现 `isConnected` 恒为 true（不做主动判断，错误由请求本身
/// 归一为 `NetworkFailure` 决定重试——分层约束：核心层不依赖插件）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/network/network_info.dart';

void main() {
  group('NetworkInfo / AlwaysOnlineNetworkInfo', () {
    test('AlwaysOnlineNetworkInfo.isConnected → true', () async {
      const AlwaysOnlineNetworkInfo info = AlwaysOnlineNetworkInfo();
      expect(await info.isConnected, isTrue);
    });

    test('抽象接口可被注入实现（形态隔离验证）', () {
      const NetworkInfo info = AlwaysOnlineNetworkInfo();
      expect(info, isA<NetworkInfo>());
    });
  });
}
