platform :ios, '16.0'

target 'vbox' do
  use_frameworks!

  # VLC 兼容播放内核，用于 MKV / HEVC / 10bit / HDR / 多音轨等系统播放器不稳定的资源
  pod 'MobileVLCKit', '3.6.0b12'

  # MDK 播放内核（wang-bin 开源），支持帧回调画中画
  # 用于复杂封装/特殊格式，作为兼容内核首选（PiP: 帧桥接）
  # swift-mdk 是 MDK 的 Swift 封装，提供 swift_mdk 模块
  pod 'swift-mdk'

  # SQLite ORM（数据库层）
  pod 'GRDB.swift'

  # HTML/XML 解析（搜索结果抓取）
  pod 'Kanna'

end
