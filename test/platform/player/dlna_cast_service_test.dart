/// 平台层单测：DLNA 投屏服务（批次 C · C-09）。
///
/// 覆盖 SSDP / 设备描述纯解析与「无目标」降级路径；不触网、不绑定组播套接字。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/cast/cast_service.dart';
import 'package:vbox/platform/player/cast/dlna_cast_service.dart';

/// 最小可用的 MediaRenderer 设备描述（含相对 controlURL）。
const String _descriptionXml = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>客厅电视</friendlyName>
    <UDN>uuid:1234-5678</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/upnp/control/AVTransport1</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/RenderingControl1</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

void main() {
  group('parseSsdpLocation', () {
    test('大小写不敏感取 LOCATION', () {
      const String resp = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'location: http://192.168.1.10:49152/description.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
      expect(
        DlnaCastService.parseSsdpLocation(resp),
        'http://192.168.1.10:49152/description.xml',
      );
    });

    test('取首个 LOCATION（去空白）', () {
      const String resp = 'LOCATION:   http://a/b.xml   \r\n';
      expect(DlnaCastService.parseSsdpLocation(resp), 'http://a/b.xml');
    });

    test('无 LOCATION → null', () {
      expect(DlnaCastService.parseSsdpLocation('HTTP/1.1 200 OK\r\n\r\n'), isNull);
      expect(DlnaCastService.parseSsdpLocation('LOCATION:\r\n'), isNull);
    });
  });

  group('parseDeviceDescription', () {
    test('解析名称 / UDN / 两个控制地址（相对路径按 base 解析）', () {
      final DlnaDeviceDescription? d = DlnaCastService.parseDeviceDescription(
        _descriptionXml,
        Uri.parse('http://192.168.1.10:49152/description.xml'),
      );
      expect(d, isNotNull);
      expect(d!.friendlyName, '客厅电视');
      expect(d.udn, 'uuid:1234-5678');
      expect(
        d.avTransportControlUrl.toString(),
        'http://192.168.1.10:49152/upnp/control/AVTransport1',
      );
      expect(
        d.renderingControlControlUrl.toString(),
        'http://192.168.1.10:49152/upnp/control/RenderingControl1',
      );
    });

    test('绝对 controlURL 保持原样', () {
      const String xml = '<device><friendlyName>T</friendlyName>'
          '<serviceList><service>'
          '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
          '<controlURL>http://cdn/av</controlURL>'
          '</service></serviceList></device>';
      final DlnaDeviceDescription? d = DlnaCastService.parseDeviceDescription(
        xml,
        Uri.parse('http://10.0.0.1/desc.xml'),
      );
      expect(d!.avTransportControlUrl.toString(), 'http://cdn/av');
      expect(d.renderingControlControlUrl, isNull);
    });

    test('无 friendlyName 且无 UDN → null', () {
      expect(
        DlnaCastService.parseDeviceDescription('<device></device>',
            Uri.parse('http://a/desc.xml')),
        isNull,
      );
    });
  });

  group('M-SEARCH 报文', () {
    test('含 MediaRenderer 搜索目标与 ssdp:discover', () {
      final String req = DlnaCastService.mSearchRequest;
      expect(req, contains('M-SEARCH * HTTP/1.1'));
      expect(req, contains('HOST: 239.255.255.250:1900'));
      expect(req, contains('MAN: "ssdp:discover"'));
      expect(req, contains('MediaRenderer:1'));
    });
  });

  group('无目标降级', () {
    test('未发现设备时 connect/cast 返回 false，控制方法为 no-op', () async {
      final DlnaCastService svc = DlnaCastService();
      expect(svc.isAvailable, isTrue);
      expect(svc.session, isNull);

      // 未发现 → 无目标登记
      expect(await svc.connect(const CastDevice(id: 'x', name: 'n')), isFalse);
      expect(await svc.cast(const CastMedia(url: 'http://x/1.m3u8')), isFalse);

      // 控制方法不抛异常
      await svc.play();
      await svc.pause();
      await svc.stop();
      await svc.seekTo(5000);
      await svc.setVolume(0.6);
      await svc.disconnect();

      svc.close();
    });
  });
}