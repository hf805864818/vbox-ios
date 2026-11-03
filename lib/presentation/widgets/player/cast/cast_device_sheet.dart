/// 表现层：投屏设备选择弹层（批次 C · C-09）。
///
/// 打开即搜索设备（SSDP），展示设备列表；点选 → 连接并投送声明的 [media]。
/// 已投屏时展示当前目标并提供「断开投屏」。风格对齐播放器面板（深色）。
library;

import 'package:flutter/material.dart';

import '../../../../platform/player/cast/cast.dart';
import '../../../theme/tokens/spacing.dart';
import 'cast_controller.dart';

/// 投屏设备选择弹层。
class CastDeviceSheet extends StatefulWidget {
  /// 构造。
  const CastDeviceSheet({
    super.key,
    required this.controller,
    required this.media,
  });

  /// 投屏控制器。
  final CastController controller;

  /// 待投送媒体（点选设备后投送）。
  final CastMedia media;

  @override
  State<CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<CastDeviceSheet> {
  @override
  void initState() {
    super.initState();
    // 进入即搜索；失败降级为空列表（由控制器保证不抛）。
    widget.controller.discover();
  }

  Future<void> _select(CastDevice device) async {
    final bool ok = await widget.controller.castTo(device, widget.media);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('投屏失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              VboxSpacing.md,
              VboxSpacing.md,
              VboxSpacing.md,
              VboxSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(bottom: VboxSpacing.sm),
                  child: Text(
                    '投屏',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ..._body(),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _body() {
    final CastController c = widget.controller;
    final String? casting = c.castingDeviceName;
    if (casting != null) {
      return <Widget>[
        ListTile(
          leading: const Icon(Icons.cast_connected_rounded, color: Colors.white),
          title: Text(
            '正在投屏到 $casting',
            style: const TextStyle(color: Colors.white),
          ),
        ),
        TextButton.icon(
          onPressed: () async {
            await c.disconnect();
            if (mounted) Navigator.of(context).pop(false);
          },
          icon: const Icon(Icons.cast_rounded),
          label: const Text('断开投屏'),
        ),
      ];
    }
    if (c.discovering && c.devices.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: VboxSpacing.lg),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        const Center(
          child: Text(
            '正在搜索设备…',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ];
    }
    if (c.devices.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: VboxSpacing.lg),
          child: Center(
            child: Text(
              '未找到投屏设备',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: () => c.discover(),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新搜索'),
        ),
      ];
    }
    return <Widget>[
      for (final CastDevice d in c.devices)
        ListTile(
          leading: const Icon(Icons.tv_rounded, color: Colors.white),
          title: Text(
            d.name.isEmpty ? d.id : d.name,
            style: const TextStyle(color: Colors.white),
          ),
          onTap: () => _select(d),
        ),
      TextButton.icon(
        onPressed: () => c.discover(),
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('重新搜索'),
      ),
    ];
  }
}