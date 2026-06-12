#!/usr/bin/env ruby
# frozen_string_literal: true

# 在 CI 阶段把 MPVKit + 8 个核心依赖 xcframework 注入到 vbox target：
#   1. 添加 PBXFileReference（如未存在）
#   2. 加入 Frameworks build phase（Link Required）
#   3. 加入 Embed Frameworks build phase（Embed & Sign + CodeSignOnCopy）
#
# 该脚本是幂等的：重复运行不会重复添加。
# 仅在验证分支 / CI 中临时调用，main 的 pbxproj 不应包含 Link/Embed 的副本。
# 不会处理 vbox/Libraries/MPV/Freedom/ 下的任何文件，自由度内核独立分支再处理。

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../vbox.xcodeproj', __dir__)
TARGET_NAME = 'vbox'

LIB_ROOT = 'vbox/Libraries/MPV'
DEPS_ROOT = 'vbox/Libraries/MPV/MPVKitDependencies'

# 顺序敏感：MPVKit wrapper 依赖 Libmpv，Libmpv 依赖 FFmpeg 组件。
FRAMEWORKS = [
  { name: 'MPVKit.xcframework',          relative_path: "#{LIB_ROOT}/MPVKit.xcframework" },
  { name: 'Libmpv.xcframework',          relative_path: "#{DEPS_ROOT}/Libmpv.xcframework" },
  { name: 'Libavcodec.xcframework',      relative_path: "#{DEPS_ROOT}/Libavcodec.xcframework" },
  { name: 'Libavdevice.xcframework',     relative_path: "#{DEPS_ROOT}/Libavdevice.xcframework" },
  { name: 'Libavfilter.xcframework',     relative_path: "#{DEPS_ROOT}/Libavfilter.xcframework" },
  { name: 'Libavformat.xcframework',     relative_path: "#{DEPS_ROOT}/Libavformat.xcframework" },
  { name: 'Libavutil.xcframework',       relative_path: "#{DEPS_ROOT}/Libavutil.xcframework" },
  { name: 'Libswresample.xcframework',   relative_path: "#{DEPS_ROOT}/Libswresample.xcframework" },
  { name: 'Libswscale.xcframework',      relative_path: "#{DEPS_ROOT}/Libswscale.xcframework" }
].freeze

def find_or_create_group(project, path_components)
  group = project.main_group
  path_components.each do |segment|
    next_group = group.children.find { |child| child.is_a?(Xcodeproj::Project::Object::PBXGroup) && child.display_name == segment }
    next_group ||= group.new_group(segment)
    group = next_group
  end
  group
end

def ensure_file_reference(project, framework)
  existing = project.files.find do |file|
    file.path == framework[:relative_path] || file.display_name == framework[:name]
  end
  return existing if existing

  group = find_or_create_group(project, %w[vbox Libraries MPV])
  ref = group.new_file(File.expand_path(framework[:relative_path], File.dirname(PROJECT_PATH)))
  ref.path = framework[:relative_path]
  ref.source_tree = 'SOURCE_ROOT'
  ref.last_known_file_type = 'wrapper.xcframework'
  ref
end

def ensure_in_frameworks_phase(target, file_ref)
  phase = target.frameworks_build_phase
  return if phase.files_references.include?(file_ref)

  build_file = phase.add_file_reference(file_ref, true)
  build_file.settings = { 'ATTRIBUTES' => ['Required'] } if build_file
end

def embed_phase(target)
  phase = target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
  return phase if phase

  phase = target.new_copy_files_build_phase('Embed Frameworks')
  phase.symbol_dst_subfolder_spec = :frameworks
  phase
end

def ensure_in_embed_phase(target, file_ref)
  phase = embed_phase(target)
  return if phase.files_references.include?(file_ref)

  build_file = phase.add_file_reference(file_ref, true)
  build_file.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] } if build_file
end

def main
  unless File.directory?(PROJECT_PATH)
    abort "找不到 Xcode project: #{PROJECT_PATH}"
  end

  project = Xcodeproj::Project.open(PROJECT_PATH)
  target = project.targets.find { |t| t.name == TARGET_NAME }
  abort "找不到 target: #{TARGET_NAME}" unless target

  changed = []
  FRAMEWORKS.each do |framework|
    abs = File.expand_path(framework[:relative_path], File.dirname(PROJECT_PATH))
    unless File.exist?(abs)
      warn "跳过（文件不存在）: #{framework[:relative_path]}"
      next
    end

    ref = ensure_file_reference(project, framework)
    ensure_in_frameworks_phase(target, ref)
    ensure_in_embed_phase(target, ref)
    changed << framework[:name]
  end

  if changed.empty?
    puts '没有可注入的 framework，请先运行 scripts/fetch_mpv_dependencies.sh。'
    exit 1
  end

  project.save
  puts '已注入 Link + Embed:'
  changed.each { |name| puts "  - #{name}" }
  puts '注意：该脚本只在 CI / 验证分支临时使用，不应把改动后的 pbxproj 合回 main。'
end

main
