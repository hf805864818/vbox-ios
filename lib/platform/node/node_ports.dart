/// 平台层：Node 常驻系统端口矩阵（批次 I · ND-01）。
///
/// 唯一真相源：iOS `NodeRuntimeManager.swift` L37-L45（`mainPort` / `catpawPort` /
/// `healthPort` / `lxPort` / `lxHealthPort`）+ 总方案 §4.2「5 端口矩阵」。
///
/// iOS 端口为**固定值**（无冲突递增），故 Flutter 端同样固定，保证
/// `node_http_client` / `node_pan_client` / `node_login_client` / `bili_auth_client`
/// 等已交付消费方硬编码的 58080 / 58083 与宿主实际监听端口一致。
library;

/// 端口矩阵（对齐 iOS `launchNodeEngine` 注入的环境变量）。
abstract final class NodePorts {
  /// kstore bundle 主端口（网盘系统默认，对齐 iOS `mainPort` / `PORT`）。
  static const int main = 58080;

  /// Dart 侧保留端口（对齐 iOS `activePort + 1` / `DART_PORT`）。
  ///
  /// iOS relisten 协议会把它写进 `.relisten`；Flutter 不移植该握手（NS-16），
  /// 但仍按矩阵注入环境变量，保持与 `main.js` 的 ABI 一致。
  static const int dart = 58081;

  /// 健康探测端口（对齐 iOS `healthPort` / `HEALTH_PORT`）。
  static const int health = 58082;

  /// lx-music 桥接端口（对齐 iOS `lxPort` / `LX_PORT`）。
  static const int lx = 58083;

  /// lx-music 桥接健康端口（对齐 iOS `lxHealthPort` / `LX_HEALTH_PORT`）。
  static const int lxHealth = 58084;

  /// catpaw bundle 端口（远程源阶段可选启用，对齐 iOS `catpawPort`）。
  static const int catpaw = 2333;

  /// 全部端口（日志 / 状态展示用）。
  static const List<int> all = <int>[catpaw, main, dart, health, lx, lxHealth];
}