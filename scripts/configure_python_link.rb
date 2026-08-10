#!/usr/bin/env ruby
# frozen_string_literal: true

# 把 Python.framework 集成进 vbox 主 target（仿照 configure_mpvkit_link.rb）
# 用法: ruby scripts/configure_python_link.rb
#
# 1. 复制 Python.framework 到 vbox/Libraries/python-ios/
# 2. 修改 project.pbxproj: 添加 Python.framework 到 Frameworks + Embed Frameworks
# 3. 添加 Header Search Paths 到主 target

require 'xcodeproj'
require 'fileutils'

puts "🐍 配置 Python.framework 链接..."

# 1. 定位项目
project_path = 'vbox.xcodeproj'
project = Xcodeproj::Project.open(project_path)
app_target = project.targets.find { |t| t.name == 'vbox' }
abort '未找到 vbox target' unless app_target
puts "✅ 找到 target: #{app_target.name}"

# 2. Python framework 源/目标路径
python_src = 'vbox/Libraries/python-ios'
framework_name = 'Python.framework'
spec_path = File.join(python_src, framework_name)

# 3. 如果 Python.framework 目录不存在，尝试从 libpython3.14.a 构建
unless File.directory?(spec_path)
  # Python.framework 可能没被复制, 尝试在当前工作区找
  candidates = Dir.glob('**/Python.framework').select { |d| d.include?('iphoneos') }
  if candidates.empty?
    puts "⚠️ 未找到 Python.framework，尝试用 libpython3.14.a 方式"
    lib = File.join(python_src, 'libpython3.14.a')
    if File.exist?(lib)
      puts "✅ 找到 libpython3.14.a (#{File.size(lib)} bytes)"
      # 创建最小 framework 结构
      FileUtils.mkdir_p(spec_path)
      FileUtils.mkdir_p(File.join(spec_path, 'Headers'))
      FileUtils.cp(lib, File.join(spec_path, 'Python'))
      puts "✅ 已创建最小 Python.framework"
    end
  else
    # 用找到的真 framework
    src = candidates.first
    FileUtils.rm_rf(spec_path)
    FileUtils.mkdir_p(File.dirname(spec_path))
    FileUtils.cp_r(src, spec_path)
    puts "✅ 复制 Python.framework: #{src} → #{spec_path}"
  end
end

# 4. 添加 PBXFileReference
file_ref = project.files.find { |f| f.path == File.join('vbox/Libraries/python-ios', 'Python.framework') }
unless file_ref
  file_ref = project.new(File.join('vbox/Libraries/python-ios', 'Python.framework'))
  project.main_group.files << file_ref
  puts "✅ 添加 PBXFileReference: Python.framework"
end

# 5. 添加到 Frameworks build phase (如果不在)
frameworks_phase = app_target.frameworks_build_phases
unless frameworks_phase.files_references.include?(file_ref)
  frameworks_phase.add_file_reference(file_ref)
  puts "✅ 添加 Python.framework 到 Frameworks"
end

# 6. 复制到Embed Frameworks phase (如果需要嵌入)
embed_phase = app_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
if embed_phase
  unless embed_phase.files_references.include?(file_ref)
    # 需要 ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, )
    build_file = embed_phase.add_file_reference(file_ref)
    build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
    puts "✅ 添加 Python.framework 到 Embed Frameworks"
  end
end

# 7. 设置 Header Search Paths (主 target)
app_target.build_configurations.each do |config|
  config.build_settings['HEADER_SEARCH_PATHS'] ||= []
  paths = config.build_settings['HEADER_SEARCH_PATHS']
  paths = [paths] unless paths.is_a?(Array)
  paths << '$(SRCROOT)/vbox/Libraries/python-ios/Headers' unless paths.include?('$(SRCROOT)/vbox/Libraries/python-ios/Headers')
  paths << '$(SRCROOT)/vbox/Libraries/python-ios/Python.framework/Headers' unless paths.include?('$(SRCROOT)/vbox/Libraries/python-ios/Python.framework/Headers')
  config.build_settings['HEADER_SEARCH_PATHS'] = paths
end

# 7.5. 把 PythonBridge.m + PythonSpiderEngine.swift 加入编译源 (sources)
source_phase = app_target.source_build_phase
bridge_files = ['vbox/Libraries/PythonBridge.m', 'vbox/Services/PythonSpiderEngine.swift']
bridge_files.each do |rel_path|
  next if source_phase.files.any? { |f| f.file_ref&.path == File.basename(rel_path) }
  # 找到或创建 fileRef
  file_ref = project.files.find { |f| f.path == rel_path }
  unless file_ref
    file_ref = project.new(rel_path)
    file_ref.source_tree = 'SOURCE_ROOT'
    file_ref.path = rel_path
    # 需设置 file reference 到 groups
    project.main_group.files << file_ref if project.main_group.files.find { |f| f.path == rel_path }.nil?
  end
  source_phase.add_file_reference(file_ref)
  puts "✅ 添加编译源: #{rel_path}"
end

# 8. 确保主 target 链接时能找到 Python 符号
app_target.build_configurations.each do |config|
  config.build_settings['LIBRARY_SEARCH_PATHS'] ||= []
  libs = config.build_settings['LIBRARY_SEARCH_PATHS']
  libs = [libs] unless libs.is_a?(Array)
  libs << '$(SRCROOT)/vbox/Libraries/python-ios/Python.framework' unless libs.include?('$(SRCROOT)/vbox/Libraries/python-ios/Python.framework')
  config.build_settings['LIBRARY_SEARCH_PATHS'] = libs
end

project.save
puts "🎉 Python.framework 集成完成！"
