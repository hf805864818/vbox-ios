platform :ios, '16.0'

target 'vbox' do
  use_frameworks!

  # VLC 兼容播放内核，用于 MKV / HEVC / 10bit / HDR / 多音轨等系统播放器不稳定的资源
  pod 'MobileVLCKit', '3.6.0b12'

  # MDK 播放内核（wang-bin 开源），支持帧回调画中画
  # 用于复杂封装/特殊格式，作为兼容内核首选（PiP: 帧桥接）
  pod 'mdk', git: 'https://github.com/wang-bin/mdk-sdk.git', tag: '2025-06-06'
end
