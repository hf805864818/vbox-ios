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
# 使用 frameworks_build_phase (单数) 而非 frameworks_build_phases (复数)
# 单数版本在 phase 不存在时自动创建，复数版本返回 nil 会导致 NoMethodError
existing = target.frameworks_build_phase.files.find do |f|
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
  # fix: 使用正确的 xcodeproj API - add_file_reference 创建 PBXBuildFile 并添加
  build_file = target.frameworks_build_phase.add_file_reference(framework_ref)
  # 设置为 Embed & Sign
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] } if build_file.respond_to?(:settings=)

  puts "✅ Quarkproxy.xcframework 已添加到 Frameworks (Embed & Sign)"
end

# 添加 GoProxyManager.swift 到编译源（幂等 + 自愈去重）
#
# 历史坑：旧实现用 `bridge_group.new_file(File.expand_path(swift_file))` 传绝对路径，
# xcodeproj 会把 f.path 记成绝对路径，而查找条件写死 'Bridge/GoProxyManager.swift'，
# 永远匹配不上 → 每次 CI 构建都重新 add 一遍。累计到 v3.1615 时 pbxproj 里已有
# 460 条重复 PBXFileReference / 460 条 PBXBuildFile（Sources 阶段同一文件 460 次）。
# 现改为：按文件名后缀匹配；命中多条时清理多余引用、保留 1 条；新增时用组内相对路径。
# 去重段整体包在 begin/rescue 里：即使 xcodeproj 行为异常也不会让构建失败。
swift_file = 'vbox/Bridge/GoProxyManager.swift'
if File.exist?(swift_file)
  matches = project.files.select { |f| f.path.to_s.end_with?('GoProxyManager.swift') }
  if matches.empty?
    bridge_group = project.groups.find { |g| g.display_name == 'Bridge' }
    unless bridge_group
      vbox_group = project.groups.find { |g| g.display_name == 'vbox' }
      if vbox_group
        bridge_group = vbox_group.new_group('Bridge', 'Bridge')
      else
        bridge_group = project.new_group('Bridge', 'Bridge')
      end
    end

    file_ref = bridge_group.new_file('GoProxyManager.swift')
    target.add_file_references([file_ref])
    puts "OK GoProxyManager.swift 已添加到编译源（相对路径，后续幂等）"
  else
    begin
      keeper = matches.first

      # 统一为「组内相对路径」：历史上这些引用是用绝对路径创建的（CI runner 上能用，
      # 本地 Xcode 会显示为失效文件）。这里把保留下来的那一条改回相对路径 + <group>。
      if keeper.respond_to?(:path=) && keeper.path.to_s != 'GoProxyManager.swift'
        keeper.path = 'GoProxyManager.swift'
        keeper.source_tree = '<group>'
      end

      removed_refs = 0
      (matches - [keeper]).each do |extra_ref|
        extra_ref.remove_from_project
        removed_refs += 1
      end

      removed_build_files = 0
      bfs = target.source_build_phase.files.select { |bf| bf.file_ref == keeper }
      (bfs - [bfs.first]).each do |extra_bf|
        extra_bf.remove_from_project
        removed_build_files += 1
      end

      if removed_refs > 0 || removed_build_files > 0
        puts "DEDUP GoProxyManager.swift: file reference -#{removed_refs}, build file -#{removed_build_files} (keep 1)"
      else
        puts "OK GoProxyManager.swift 已存在（无重复）"
      end
    rescue StandardError => e
      puts "WARN GoProxyManager.swift 去重跳过（不阻断构建）: #{e.message}"
    end
  end
end
project.save
puts "✅ 项目配置完成"
