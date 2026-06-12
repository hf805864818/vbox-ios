#!/usr/bin/env ruby
# frozen_string_literal: true

# 在 CI 阶段把 MPVKit + MPVKitDependencies 下已安装的 xcframework 注入到 vbox target：
#   1. 添加 PBXFileReference（如未存在）
#   2. 加入 Frameworks build phase（Link Required）
#   3. 加入 Embed Frameworks build phase（Embed & Sign + CodeSignOnCopy）
#
# 该脚本是幂等的：重复运行不会重复添加。
# 仅在 CI 中临时调用，main 的 pbxproj 不固化 Link/Embed 副本。
# 不会处理 vbox/Libraries/MPV/Freedom/ 下的任何文件，自由度内核独立分支再处理。

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../vbox.xcodeproj', __dir__)
TARGET_NAME = 'vbox'

LIB_ROOT = 'vbox/Libraries/MPV'
DEPS_ROOT = 'vbox/Libraries/MPV/MPVKitDependencies'

# 顺序敏感：先 MPVKit wrapper，再 Libmpv，再 FFmpeg 核心组件，最后按静态库依赖关系注入外部依赖。
BASE_FRAMEWORKS = [
  "#{LIB_ROOT}/MPVKit.xcframework",
  "#{DEPS_ROOT}/Libmpv.xcframework",
  "#{DEPS_ROOT}/Libavcodec.xcframework",
  "#{DEPS_ROOT}/Libavdevice.xcframework",
  "#{DEPS_ROOT}/Libavfilter.xcframework",
  "#{DEPS_ROOT}/Libavformat.xcframework",
  "#{DEPS_ROOT}/Libavutil.xcframework",
  "#{DEPS_ROOT}/Libswresample.xcframework",
  "#{DEPS_ROOT}/Libswscale.xcframework"
].freeze

# 外部依赖不能简单按文件名排序。Libmpv / FFmpeg 当前预编译包会直接引用
# gnutls、libplacebo、shaderc、uavs3d、uchardet、MoltenVK 等符号；这些
# provider 必须稳定出现在核心静态库之后，且二级依赖继续排在使用方之后。
EXTERNAL_FRAMEWORK_ORDER = %w[
  Libass
  Libbluray
  Libuavs3d
  Libdovi
  Libdav1d
  Libuchardet
  Libplacebo
  Libsmbclient
  gnutls
  Libssl
  Libunibreak
  Libharfbuzz
  Libfribidi
  Libfreetype
  Libshaderc_combined
  MoltenVK
  lcms2
  Libcrypto
  hogweed
  nettle
  gmp
].freeze

SYSTEM_FRAMEWORKS = %w[
  VideoToolbox.framework
  CoreMedia.framework
  CoreVideo.framework
  AudioToolbox.framework
  AVFoundation.framework
  Metal.framework
  QuartzCore.framework
  UIKit.framework
  IOSurface.framework
  Security.framework
  libz.tbd
  libbz2.tbd
  libiconv.tbd
].freeze

def framework_entries
  root = File.dirname(PROJECT_PATH)
  base = BASE_FRAMEWORKS.map do |relative_path|
    { name: File.basename(relative_path), relative_path: relative_path }
  end

  installed_by_name = Dir.glob(File.join(root, DEPS_ROOT, '*.xcframework')).each_with_object({}) do |path, memo|
    relative_path = path.sub("#{root}/", '')
    memo[File.basename(relative_path, '.xcframework')] = {
      name: File.basename(relative_path),
      relative_path: relative_path
    }
  end

  ordered_external = EXTERNAL_FRAMEWORK_ORDER.filter_map { |name| installed_by_name.delete(name) }
  remaining_external = installed_by_name.values.sort_by { |item| item[:name] }

  (base + ordered_external + remaining_external).uniq { |item| item[:relative_path] }
end

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

def ensure_system_framework(target, name)
  phase = target.frameworks_build_phase
  return if phase.files_references.any? { |ref| ref.display_name == name || ref.path&.end_with?(name) }

  group = find_or_create_group(target.project, ['Frameworks'])
  if name.end_with?('.framework')
    ref = group.new_file("System/Library/Frameworks/#{name}")
    ref.source_tree = 'SDKROOT'
    phase.add_file_reference(ref, true)
  elsif name.end_with?('.tbd')
    ref = group.new_file("usr/lib/#{name}")
    ref.source_tree = 'SDKROOT'
    ref.last_known_file_type = 'sourcecode.text-based-dylib-definition'
    phase.add_file_reference(ref, true)
  end
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
  framework_entries.each do |framework|
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

  SYSTEM_FRAMEWORKS.each do |name|
    ensure_system_framework(target, name)
    changed << name
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
