/// 数据层：远程源清单数据源。
///
/// 契约：`contract/schema/manifest_v1.json`
/// 逆向来源：iOS `vbox/Services/RemoteSourceConfigManager.swift`。
///
/// 校验链：HTTP 2xx → JSON 对象 → 必需文件条目 `allSources` → `configVersion` 格式。
library;

import '../../../core/errors/exceptions.dart';
import '../../../core/errors/failures.dart';
import '../../../core/network/http_client.dart';
import '../../../core/utils/json_utils.dart';
import '../../../core/utils/result.dart';
import '../../../domain/entities/remote_source/remote_source.dart';

/// 远程源清单数据源。
class RemoteManifestDatasource {
  /// 构造。
  RemoteManifestDatasource({
    required HttpClient client,
    Map<String, String> headers = const <String, String>{},
  })  : _client = client,
        _headers = headers;

  final HttpClient _client;
  final Map<String, String> _headers;

  /// 拉取并校验清单。
  Future<Result<RemoteManifest>> fetch(
    String url, {
    bool forceRefresh = false,
  }) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return const Err<RemoteManifest>(
        ValidationFailure('清单地址非法（需 http/https 绝对地址）'),
      );
    }

    try {
      final HttpClientResponse res = await _client.get(
        uri,
        headers: <String, String>{
          ..._headers,
          if (forceRefresh) 'cache-control': 'no-cache',
        },
      );
      if (!res.isOk) {
        return Err<RemoteManifest>(
          NetworkFailure(
            'HTTP ${res.statusCode}：$uri',
            code: ErrorCode.httpStatus,
          ),
        );
      }

      final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
      if (json == null) {
        return const Err<RemoteManifest>(ParseFailure('清单不是 JSON 对象'));
      }

      final RemoteManifest manifest = RemoteManifest.fromJson(json);
      if (!manifest.hasRequiredFiles) {
        return const Err<RemoteManifest>(
          ParseFailure(
            '清单缺少必需文件条目 ${RemoteManifest.keyAllSources}',
          ),
        );
      }
      if (!manifest.hasValidConfigVersion) {
        return Err<RemoteManifest>(
          ParseFailure('configVersion 格式非法：${manifest.configVersion}'),
        );
      }
      return Success<RemoteManifest>(manifest);
    } catch (e) {
      return Err<RemoteManifest>(Failure.from(e));
    }
  }
}
