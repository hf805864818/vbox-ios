/// 批次 C · C-11：播放器后端选择 + wire 线上值锁定。
///
/// 锁定各端后端降级链口径（D6）与 MDK 统一内核接缝（M1），以及
/// ChannelPlayer.open 传给原生插件的 `backend` 线上字符串
/// （Windows `player_plugin.cpp` 仅实现 libmpv，收到其他值返回
/// E_BACKEND_UNAVAILABLE，见 windows/runner/player_plugin.cpp）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';

void main() {
  group('PlayerBackendSelector.chainFor', () {
    test('windows → 仅 mediaKit（自研桥退役，media_kit 唯一内核）', () {
      expect(
        PlayerBackendSelector.chainFor('windows'),
        const <PlayerBackend>[PlayerBackend.mediaKit],
      );
    });

    test('macos → 与 Windows 同链，case 穿透', () {
      expect(
        PlayerBackendSelector.chainFor('macos'),
        const <PlayerBackend>[PlayerBackend.mediaKit],
      );
    });

    test('android → media3 主 + libVLC 回退（MDK 无原生实现，不入链）', () {
      expect(
        PlayerBackendSelector.chainFor('android'),
        const <PlayerBackend>[
          PlayerBackend.media3,
          PlayerBackend.libVLC,
        ],
      );
    });

    test('ios → nativeiOS（不迁移占位）', () {
      expect(
        PlayerBackendSelector.chainFor('ios'),
        const <PlayerBackend>[PlayerBackend.nativeiOS],
      );
    });

    test('链首即默认主后端（默认路径不经过 MDK）', () {
      expect(PlayerBackendSelector.chainFor('android').first,
          PlayerBackend.media3);
      expect(PlayerBackendSelector.chainFor('windows').first,
          PlayerBackend.mediaKit);
    });
  });

  group('backendWireValue（原生 open 参数）', () {
    test('libmpv → "libmpv"（player_plugin.cpp 唯一接受值）', () {
      expect(backendWireValue(PlayerBackend.libmpv), 'libmpv');
    });

    test('mdk → "mdk"（M1：原生未接入前由降级链兜底）', () {
      expect(backendWireValue(PlayerBackend.mdk), 'mdk');
    });

    test('media3 / libVLC / nativeiOS 各自对齐 Android/iOS 侧', () {
      expect(backendWireValue(PlayerBackend.media3), 'media3');
      expect(backendWireValue(PlayerBackend.libVLC), 'libVLC');
      expect(backendWireValue(PlayerBackend.nativeiOS), 'nativeiOS');
    });
  });

  group('PlayerBackendMeta（M1 · MDK 元数据）', () {
    test('MDK 显示名 / 短名 / 系统 PiP 能力', () {
      expect(PlayerBackend.mdk.displayName, 'MDK（全格式）');
      expect(PlayerBackend.mdk.shortName, 'MDK');
      expect(PlayerBackend.mdk.supportsSystemPip, isFalse);
    });

    test('每个后端元数据非空（面板文案完整性）', () {
      for (final PlayerBackend b in PlayerBackend.values) {
        expect(b.displayName, isNotEmpty, reason: b.name);
        expect(b.shortName, isNotEmpty, reason: b.name);
      }
    });
  });

  group('PlayerBackendSelector.initialBackend（M1 · 初始后端选择）', () {
    const List<PlayerBackend> android = <PlayerBackend>[
      PlayerBackend.media3,
      PlayerBackend.libVLC,
    ];
    const List<PlayerBackend> desktop = <PlayerBackend>[
      PlayerBackend.libmpv,
    ];

    test('常规媒体 → 链首主后端（默认路径不经过复杂封装分支）', () {
      expect(
        PlayerBackendSelector.initialBackend(
          chain: android,
          needsFullFormat: false,
        ),
        PlayerBackend.media3,
      );
      expect(
        PlayerBackendSelector.initialBackend(
          chain: desktop,
          needsFullFormat: false,
        ),
        PlayerBackend.libmpv,
      );
    });

    test('需全格式：Android 链无 MDK → libVLC；桌面链无 MDK → libmpv 兜底', () {
      expect(
        PlayerBackendSelector.initialBackend(
          chain: android,
          needsFullFormat: true,
        ),
        PlayerBackend.libVLC,
      );
      expect(
        PlayerBackendSelector.initialBackend(
          chain: desktop,
          needsFullFormat: true,
        ),
        PlayerBackend.libmpv,
      );
    });

    test('回退序：无 MDK → libVLC → libmpv → 链首', () {
      expect(
        PlayerBackendSelector.initialBackend(
          chain: const <PlayerBackend>[PlayerBackend.media3, PlayerBackend.libVLC],
          needsFullFormat: true,
        ),
        PlayerBackend.libVLC,
      );
      expect(
        PlayerBackendSelector.initialBackend(
          chain: const <PlayerBackend>[PlayerBackend.libmpv],
          needsFullFormat: true,
        ),
        PlayerBackend.libmpv,
      );
      expect(
        PlayerBackendSelector.initialBackend(
          chain: const <PlayerBackend>[PlayerBackend.media3],
          needsFullFormat: true,
        ),
        PlayerBackend.media3,
      );
    });
  });

  group('PlayerBackendSelector.needsFallback（A21.5 清单）', () {
    test('复杂封装 → 需全格式后端回退', () {
      for (final String ext in <String>[
        '.mkv', '.flv', '.ts', '.rmvb', '.avi', '.wmv', '.m2ts',
      ]) {
        expect(
          PlayerBackendSelector.needsFallback('https://x/a$ext'),
          isTrue,
          reason: '扩展名 $ext 应触发回退',
        );
      }
    });

    test('常规容器 → 不回退', () {
      expect(
        PlayerBackendSelector.needsFallback('https://x/a.mp4'),
        isFalse,
      );
      expect(
        PlayerBackendSelector.needsFallback('https://x/a.m3u8'),
        isFalse,
      );
    });

    test('无扩展名代理 URL → 以真实文件名补判（修复②）', () {
      const String proxy = 'http://127.0.0.1:58080/spider/push/4/proxy/115/x';
      // 仅凭 URL 无法判定封装 → 不回退（原缺陷：4K HEVC MKV 被误投 Media3）。
      expect(PlayerBackendSelector.needsFallback(proxy), isFalse);
      // 真实文件名命中复杂封装 → 回退。
      expect(
        PlayerBackendSelector.needsFallback(proxy,
            resourceName: 'Movie.hevc.mkv'),
        isTrue,
      );
      // 真实文件名普通容器 → 不回退。
      expect(
        PlayerBackendSelector.needsFallback(proxy, resourceName: 'Movie.mp4'),
        isFalse,
      );
    });
  });

  group('F-P28 · 按盘内核策略（对齐 iOS preferredCompatibilityEngineName）', () {
    group('URL 判据（逐字对齐 iOS）', () {
      test('isNodePanProxyUrl：本地回环 + /spider/push/ 路径（iOS L1251-1254）', () {
        expect(
          PlayerBackendSelector.isNodePanProxyUrl(
              'http://127.0.0.1:18080/spider/push/4/proxy/quark/x'),
          isTrue,
        );
        expect(
          PlayerBackendSelector.isNodePanProxyUrl(
              'http://localhost:18080/spider/push/4/proxy/115/x'),
          isTrue,
        );
        // 非本地回环 / 非 Node 代理路径。
        expect(
          PlayerBackendSelector.isNodePanProxyUrl(
              'https://cdn.example.com/spider/push/x'),
          isFalse,
        );
        expect(
          PlayerBackendSelector.isNodePanProxyUrl('http://127.0.0.1/quark-stream/x'),
          isFalse,
        );
      });

      test('isUcPlaybackUrl：*.uc.cn（排除三域）/ *.cdn.yun.cn / ucdl / ucloud'
          '（iOS L4576-4588）', () {
        // *.uc.cn：排除 drive.uc.cn / pc-api.uc.cn / www.uc.cn。
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://video.uc.cn/a.mp4'),
            isTrue);
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://drive.uc.cn/a'),
            isFalse);
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://pc-api.uc.cn/a'),
            isFalse);
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://www.uc.cn/a'),
            isFalse);
        // UC TV Token CDN 直链（iOS 坑：漏判致 UC 内核策略失效）。
        expect(
          PlayerBackendSelector.isUcPlaybackUrl(
              'https://video-play-p-zb.cdn.yun.cn/a.mp4'),
          isTrue,
        );
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://x-ucdl.aly.cn/a'),
            isTrue);
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://ucloud.example.cn/a'),
            isTrue);
        // 非 UC 域。
        expect(PlayerBackendSelector.isUcPlaybackUrl('https://cdn.baidu.com/a'),
            isFalse);
      });

      test('isUcStreamUrl：uc-stream 本地代理 或 UC 播放直链（iOS L4570-4574）', () {
        expect(
          PlayerBackendSelector.isUcStreamUrl(
              'http://127.0.0.1:18080/uc-stream/abc'),
          isTrue,
        );
        expect(
          PlayerBackendSelector.isUcStreamUrl(
              'https://video-play-p-zb.cdn.yun.cn/a.mp4'),
          isTrue,
        );
        expect(PlayerBackendSelector.isUcStreamUrl('https://cdn.baidu.com/a.mp4'),
            isFalse);
      });

      test('nodeCompatibilityReason：Node 代理复杂封装判定（iOS L1314-1333）', () {
        expect(
          PlayerBackendSelector.nodeCompatibilityReason('[xxx]01_4K.mp4'),
          isNull,
          reason: '仅含 4k 的 MP4 不得误判（iOS 刻意不含 4k 规则）',
        );
        // iOS 规则表 `.mkv` 位次先于 hevc（PlayerViewsV2.swift L1316-1331），
        // first-match 语义：同文件名命中多规则时取表序首个 → 'MKV 封装'。
        expect(
          PlayerBackendSelector.nodeCompatibilityReason('Movie 2024 hevc.mkv'),
          'MKV 封装',
          reason: '.mkv 规则先于 hevc（iOS 表序）',
        );
        expect(PlayerBackendSelector.nodeCompatibilityReason('a.hdr.mp4'),
            'HDR 视频');
        expect(
          PlayerBackendSelector.nodeCompatibilityReason('b.dts.mkv'),
          'MKV 封装',
          reason: '.mkv 规则先于 dts（iOS 表序）',
        );
        expect(
          PlayerBackendSelector.nodeCompatibilityReason('Movie 2024 hevc.mp4'),
          'HEVC/H.265',
          reason: '无容器规则命中时 hevc 生效',
        );
        expect(PlayerBackendSelector.nodeCompatibilityReason('c.dts.mkv 混流'),
            'MKV 封装');
      });

      test('hardContainerReason：139 硬容器清单（iOS L1337-1345）', () {
        for (final String f in <String>[
          'x.iso', 'x.m2ts', 'x.vob', 'x.rmvb', 'x.flv', 'x.avi', 'x.mkv',
        ]) {
          expect(PlayerBackendSelector.hardContainerReason(f), isNotNull,
              reason: f);
        }
        // 刻意不含 mp4/m3u8/hevc/hdr——139 上 AVPlayer 本就能播。
        expect(PlayerBackendSelector.hardContainerReason('x.mp4'), isNull);
        expect(PlayerBackendSelector.hardContainerReason('x.hevc.mp4'), isNull);
      });
    });

    group('driveChainFor（逐盘对齐 iOS auto 门闸）', () {
      test('quark 代理流 → mdk → libmpv → libVLC；直链 → null 落默认', () {
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: 'quark',
            url: 'http://127.0.0.1:18080/quark-stream/x',
          ),
          const <PlayerBackend>[
            PlayerBackend.mdk,
            PlayerBackend.libmpv,
            PlayerBackend.libVLC,
          ],
        );
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: 'quark',
            url: 'http://127.0.0.1:18080/quark-m3u8/x',
          ),
          isNotNull,
        );
        // 夸克直链（非代理）→ iOS 落默认 AVPlayer。
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: 'quark',
            url: 'https://dl-quark.cn/a.mp4',
          ),
          isNull,
        );
      });

      test('uc / ucNode 流 → mdk → libVLC → libmpv（禁 MPV 沉底）', () {
        for (final String p in <String>['uc', 'ucNode']) {
          expect(
            PlayerBackendSelector.driveChainFor(
              provider: p,
              url: 'http://127.0.0.1:18080/uc-stream/abc',
            ),
            const <PlayerBackend>[
              PlayerBackend.mdk,
              PlayerBackend.libVLC,
              PlayerBackend.libmpv,
            ],
            reason: p,
          );
          expect(
            PlayerBackendSelector.driveChainFor(
              provider: p,
              url: 'https://video-play-p-zb.cdn.yun.cn/a.mp4',
            ),
            const <PlayerBackend>[
              PlayerBackend.mdk,
              PlayerBackend.libVLC,
              PlayerBackend.libmpv,
            ],
            reason: '$p CDN 直链',
          );
          // 非 UC 流 → null。
          expect(
            PlayerBackendSelector.driveChainFor(
              provider: p,
              url: 'https://cdn.other.cn/a.mp4',
            ),
            isNull,
          );
        }
      });

      test('baidu / baiduNode 代理流 → mdk → libmpv → libVLC（MDK 优先）', () {
        for (final String p in <String>['baidu', 'baiduNode']) {
          expect(
            PlayerBackendSelector.driveChainFor(
              provider: p,
              url: 'http://127.0.0.1:18080/baidu-stream/x',
            ),
            const <PlayerBackend>[
              PlayerBackend.mdk,
              PlayerBackend.libmpv,
              PlayerBackend.libVLC,
            ],
            reason: p,
          );
          expect(
            PlayerBackendSelector.driveChainFor(
              provider: p,
              url: 'http://127.0.0.1:18080/spider/push/4/proxy/baidu/x',
            ),
            isNotNull,
            reason: '$p Node 代理流',
          );
          // 非代理直链 → null。
          expect(
            PlayerBackendSelector.driveChainFor(
              provider: p,
              url: 'https://d.pcs.baidu.com/file',
            ),
            isNull,
          );
        }
      });

      test('139pan：硬容器文件名 → mdk → libVLC → libmpv；非硬容器 → null', () {
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: '139pan',
            url: 'https://eos.example.cn/abc',
            resourceName: 'Movie.2024.mkv',
          ),
          const <PlayerBackend>[
            PlayerBackend.mdk,
            PlayerBackend.libVLC,
            PlayerBackend.libmpv,
          ],
        );
        // 非硬容器（EOS 直链可播）→ iOS 落默认 AVPlayer。
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: '139pan',
            url: 'https://eos.example.cn/abc',
            resourceName: 'Movie.mp4',
          ),
          isNull,
        );
      });

      test('其它 Node 盘：代理流 + 复杂封装文件名 → 命中；否则 null', () {
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: '115',
            url: 'http://127.0.0.1:18080/spider/push/4/proxy/115/x',
            resourceName: 'Show.S01.hevc.mkv',
          ),
          const <PlayerBackend>[
            PlayerBackend.mdk,
            PlayerBackend.libVLC,
            PlayerBackend.libmpv,
          ],
        );
        // 代理流但文件名普通 → null（iOS 落默认）。
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: 'xunlei',
            url: 'http://127.0.0.1:18080/spider/push/4/proxy/xunlei/x',
            resourceName: '[xxx]01_4K.mp4',
          ),
          isNull,
        );
        // 非代理 URL → null。
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: '123pan',
            url: 'https://cdn.123pan.cn/a.mkv',
            resourceName: 'a.mkv',
          ),
          isNull,
        );
      });

      test('ali 及未列盘 → null（iOS shouldPreferAliPlayer 恒 false）', () {
        expect(
          PlayerBackendSelector.driveChainFor(
            provider: 'ali',
            url: 'http://127.0.0.1:18080/ali-stream/x',
          ),
          isNull,
        );
      });
    });

    group('pickDriveBackend（平台可用性交集，等价 isXXXBuildAvailable）', () {
      const List<PlayerBackend> android = <PlayerBackend>[
        PlayerBackend.media3,
        PlayerBackend.libVLC,
      ];
      const List<PlayerBackend> desktop = <PlayerBackend>[
        PlayerBackend.libmpv,
      ];

      test('按盘链序取首个平台可用后端', () {
        // mdk 无原生实现（不在 Android 可用链）→ 跳过，取 libVLC。
        expect(
          PlayerBackendSelector.pickDriveBackend(
            driveChain: const <PlayerBackend>[
              PlayerBackend.mdk,
              PlayerBackend.libVLC,
            ],
            available: android,
          ),
          PlayerBackend.libVLC,
        );
        // mdk / libVLC 不在桌面链 → 顺延到 libmpv。
        expect(
          PlayerBackendSelector.pickDriveBackend(
            driveChain: const <PlayerBackend>[
              PlayerBackend.mdk,
              PlayerBackend.libVLC,
              PlayerBackend.libmpv,
            ],
            available: desktop,
          ),
          PlayerBackend.libmpv,
        );
      });

      test('全不可用 → null（回落源特征逻辑）', () {
        expect(
          PlayerBackendSelector.pickDriveBackend(
            driveChain: const <PlayerBackend>[PlayerBackend.libVLC],
            available: desktop,
          ),
          isNull,
        );
      });
    });
  });
}
