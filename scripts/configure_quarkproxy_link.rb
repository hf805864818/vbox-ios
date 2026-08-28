#!/usr/bin/env ruby
# configure_quarkproxy_link.rb
# 将 gomobile 生成的 Quarkproxy.xcframework 注入 vbox.xcodeproj
# 用法: ruby scripts/configure_quarkproxy_link.rb

require 'xcodeproj'

project_path = 'vbox.xcodeproj'
xcframework_path = File.expand_path('Quarkproxy.xcframework')

puts "🔗 注入 Quarkproxy.xcframework..."

unless File.exist?(xcframework_path)
  puts "⚠️ Quarkproxy.xcframework 不存在 (#{xcframework_path})，跳过"
  exit 0
end

project = Xcodeproj::Project.open(project_path)

# 找到主 target
target = project.targets.find { |t| t.name == 'vbox' }
unless target
  puts "❌ 未找到 vbox target"
  exit 1
end

# 检查是否已链接
existing = target.frameworks_build_phases.files.find do |f|
  f.display_name.include?('Quarkproxy')
end

if existing
  puts "✅ Quarkproxy 已链接，跳过"
else
  # 添加 xcframework 引用
  framework_ref = project.files.find { |f| f.path == 'Quarkproxy.xcframework' }
  unless framework_ref
    framework_ref = project.new_file(xcframework_path)
    framework_ref.source_tree = '<group>'
  end

  # 添加到 Frameworks build phase (Embed & Sign)
  # fix: 使用正确的 xcodeproj API - new_file_reference 一步完成创建和添加
  build_file = target.frameworks_build_phase.new_file_reference(framework_ref)
  # 设置为 Embed & Sign
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] } if build_file.respond_to?(:settings=)

  puts "✅ Quarkproxy.xcframework 已添加到 Frameworks (Embed & Sign)"
end

# 添加 GoProxyManager.swift 到编译源
swift_file = 'vbox/Bridge/GoProxyManager.swift'
if File.exist?(swift_file)
  file_ref = project.files.find { |f| f.path == 'Bridge/GoProxyManager.swift' }
  unless file_ref
    # 找到或创建 Bridge group
    bridge_group = project.groups.find { |g| g.display_name == 'Bridge' }
    unless bridge_group
      vbox_group = project.groups.find { |g| g.display_name == 'vbox' }
      if vbox_group
        bridge_group = vbox_group.new_group('Bridge', 'Bridge')
      else
        bridge_group = project.new_group('Bridge', 'Bridge')
      end
    end

    file_ref = bridge_group.new_file(File.expand_path(swift_file))
    target.add_file_references([file_ref])
    puts "✅ GoProxyManager.swift 已添加到编译源"
  else
    puts "✅ GoProxyManager.swift 已存在"
  end
end

project.save
puts "✅ 项目配置完成"
