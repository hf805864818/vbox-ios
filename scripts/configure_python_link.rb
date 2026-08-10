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
file_ref = project.files.find { |f| f.path == 'Libraries/python-ios/Python.framework' || f.path == 'Python.framework' }
unless file_ref
  file_ref = project.main_group.new_file('Libraries/python-ios/Python.framework')
  file_ref.last_known_file_type = 'wrapper.framework'
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

# ============================================================
# [修复] 7.1. 设置 Framework Search Paths (主 target)
# ------------------------------------------------------------
# 根因: 链接器报错 "ld: framework 'Python' not found"
#   原脚本设置了 LIBRARY_SEARCH_PATHS (-L) 和 HEADER_SEARCH_PATHS,
#   但缺少 FRAMEWORK_SEARCH_PATHS (-F)。
#   Python.framework 在 vbox/Libraries/python-ios/ 子目录下,
#   而已注册的 -F 路径只到 vbox/Libraries/。
# 修复: 将 $(SRCROOT)/vbox/Libraries/python-ios 添加到 FRAMEWORK_SEARCH_PATHS。
# ============================================================
app_target.build_configurations.each do |config|
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] ||= []
  fw_paths = config.build_settings['FRAMEWORK_SEARCH_PATHS']
  fw_paths = [fw_paths] unless fw_paths.is_a?(Array)
  fw_paths << '$(SRCROOT)/vbox/Libraries/python-ios' unless fw_paths.include?('$(SRCROOT)/vbox/Libraries/python-ios')
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = fw_paths
end
puts "✅ 添加 Framework Search Paths: $(SRCROOT)/vbox/Libraries/python-ios"

# 7.5. 把 PythonBridge.m + PythonSpiderEngine.swift 加入编译源 (sources)
source_phase = app_target.source_build_phase

# 递归查找指定名字的 PBXGroup (用递归+短名，避免 path 嵌套干扰)
def find_group_by_name(project, group_name)
  group = project.main_group.recursive_children.find do |c|
    c.respond_to?(:files) && (c.name == group_name || c.path == group_name)
  end
  group
end

# 明确: PythonBridge.m → Libraries group; PythonSpiderEngine.swift → Services group
bridge_files = {
  'PythonBridge.m' => 'Libraries',
  'PythonSpiderEngine.swift' => 'Services'
}
bridge_files.each do |file_name, group_name|
  next if source_phase.files.any? { |f| f.file_ref&.path == file_name }
  target_group = find_group_by_name(project, group_name)
  abort "未找到 #{group_name} group" unless target_group
  file_ref = target_group.new_file(file_name)
  file_ref.path = file_name
  file_ref.source_tree = '<group>'
  puts "✅ 添加编译源: #{file_name} → #{group_name} group"
  source_phase.add_file_reference(file_ref)
end

# 8. 确保主 target 链接时能找到 Python 符号
app_target.build_configurations.each do |config|
  config.build_settings['LIBRARY_SEARCH_PATHS'] ||= []
  libs = config.build_settings['LIBRARY_SEARCH_PATHS']
  libs = [libs] unless libs.is_a?(Array)
  libs << '$(SRCROOT)/vbox/Libraries/python-ios/Python.framework' unless libs.include?('$(SRCROOT)/vbox/Libraries/python-ios/Python.framework')
  config.build_settings['LIBRARY_SEARCH_PATHS'] = libs
end

# ============================================================
# [关键修复] 把 Python 标准库 (python-stdlib) 加进 Copy Bundle Resources
# ------------------------------------------------------------
# 根因: Py_Initialize() 需要 <AppBundle>/python-stdlib 下的标准库,
#   但仓库 vbox/Resources/python-stdlib/ 没有被 Xcode 的
#   Copy Bundle Resources 阶段引用, 导致标准库没打进 IPA。
#   → Py_Initialize 找不到 encodings/os 等 → SIGABRT 闪退无日志
# 修复: 将 vbox/Resources/python-stdlib 整个文件夹作为 folder reference
#   加入 Copy Bundle Resources 阶段, 这样 .py 标准库会原样进 App bundle。
# ============================================================
resources_phase = app_target.resources_build_phase
stdlib_path = 'Resources/python-stdlib'
# folder reference 依赖
stdlib_file_ref = project.files.find { |f| f.path == stdlib_path || f.path == 'vbox/Resources/python-stdlib' }
unless stdlib_file_ref
  stdlib_file_ref = project.main_group.new_file(stdlib_path)
  stdlib_file_ref.last_known_file_type = 'folder'
  stdlib_file_ref.path = stdlib_path
  stdlib_file_ref.source_tree = '<group>'
  stdlib_file_ref.explicit_file_type = 'folder'
  puts "✅ 添加 python-stdlib folder reference"
end
# 确保 .py 文件的 folder 引用在 Copy Resources (文件夹引用打成 .lproj 或 folder)
unless resources_phase.files_references.include?(stdlib_file_ref)
  resources_phase.add_file_reference(stdlib_file_ref)
  puts "✅ 添加 python-stdlib 到 Copy Bundle Resources"
end

project.save
puts "🎉 Python.framework + 标准库 集成完成！"
