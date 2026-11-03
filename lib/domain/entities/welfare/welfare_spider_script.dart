/// 领域层：福利 Spider 脚本实体 + 加载错误（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfareSpiderLoader.swift`
///   · `WelfareSpiderScript`（L41-L47）：platformKey / remoteURL / localURL /
///     content / loadedAt；
///   · `WelfareSpiderLoaderError`（L15-L39）：六类错误 + `errorDescription`。
///
/// 差异登记：
///   · 新增 `fetchFailed` 错误 —— iOS 下载失败直接抛 `URLError`（未枚举化），
///     Flutter 侧统一走错误枚举，便于 Service / UI 展示中文原因。
library;

import 'package:path/path.dart' as p;

/// 已下载 / 已缓存的福利 Spider 脚本（对齐 iOS `WelfareSpiderScript`）。
class WelfareSpiderScript {
  /// 构造。
  const WelfareSpiderScript({
    required this.platformKey,
    required this.remoteURL,
    required this.localURL,
    required this.content,
    required this.loadedAt,
  });

  /// 平台唯一键（与远程配置 `platformKey` 一致）。
  final String platformKey;

  /// 远程脚本地址（代理候选前的原始地址）。
  final Uri remoteURL;

  /// 本地缓存文件地址。
  final String localURL;

  /// 脚本文本内容。
  final String content;

  /// 缓存写入 / 文件修改时间。
  final DateTime loadedAt;

  /// 本地缓存文件名（对齐 iOS `localScriptPath` = `lastPathComponent`）。
  String get localScriptPath => p.basename(localURL);

  /// 脚本预览（前 28 行，对齐 iOS `WelfareSpiderService.scriptPreview`）。
  String get preview {
    final List<String> lines = content.split('\n').take(28).toList();
    return lines.join('\n');
  }
}

/// 福利 Spider 脚本加载错误（对齐 iOS `WelfareSpiderLoaderError`）。
enum WelfareSpiderLoaderError {
  /// 平台类型不是 `welfare_spider`。
  invalidServiceType,

  /// 远程平台未配置 `api` 脚本路径。
  missingAPI,

  /// 脚本类型不在 `python` / `javascript` 白名单。
  unsupportedScriptType,

  /// 脚本路径越界（只允许 `sources/welfare-js/`）。
  invalidScriptPath,

  /// 无法生成远程脚本地址。
  invalidRemoteURL,

  /// 远程脚本内容为空。
  emptyScript,

  /// 网络下载失败（Flutter 新增，iOS 抛原始 `URLError`）。
  fetchFailed;

  /// 用户可读的中文说明（对齐 iOS `errorDescription` 语义）。
  String messageOf([Object? detail]) {
    final String d = detail == null ? '' : '：$detail';
    return switch (this) {
      WelfareSpiderLoaderError.invalidServiceType =>
        '平台类型不是 welfare_spider$d',
      WelfareSpiderLoaderError.missingAPI => '远程平台未配置 api 脚本路径',
      WelfareSpiderLoaderError.unsupportedScriptType =>
        '暂不支持该脚本类型$d',
      WelfareSpiderLoaderError.invalidScriptPath =>
        '福利 Spider 只允许加载 sources/welfare-js/ 下的脚本$d',
      WelfareSpiderLoaderError.invalidRemoteURL => '无法生成远程脚本地址$d',
      WelfareSpiderLoaderError.emptyScript => '远程脚本内容为空',
      WelfareSpiderLoaderError.fetchFailed => '福利脚本下载失败$d',
    };
  }
}
