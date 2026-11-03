/// 契约层：SQLite Schema 与迁移链
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 本文件是该 DDL 的 Dart 移植，**任何修改必须同步两侧**。
///
/// 数据库版本历史：
///   v1 — 9 张基础表
///   v2 — zhanyuan / apiyuan 重建（唯一约束调整）
///   v3 — 新增 search_history 表
///   v4 — download 表新增 4 个可空字段（云盘支持）
library;

/// 当前 Schema 版本（对应 iOS 端 `supportedSchemaVersion`）。
///
/// ⚠️ 与 iOS 端 `BackupManager.supportedSchemaVersion` 保持一致；改动需双端同步。
const int kSchemaVersion = 4;

/// 全部数据表名（9 张 + sqlite_sequence 为 SQLite 内部表）。
const List<String> kAllTables = <String>[
  'zhanyuan',
  'apiyuan',
  'subscription',
  'favorite',
  'history',
  'download',
  'settings',
  'jiexisetting',
  'search_history',
];

/// v1 建表语句：9 张基础表。
///
/// 注意：`zhanyuan` / `apiyuan` 在 v2 被重建，此处保留 v1 原始定义以支持
/// 从零建库时的迁移链完整性校验。
const List<String> _v1CreateTables = <String>[
  // 自建源
  '''
CREATE TABLE zhanyuan (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  name          TEXT    NOT NULL,
  searchUrl     TEXT    NOT NULL,
  searchUA      TEXT    NOT NULL DEFAULT '',
  playUA        TEXT    NOT NULL DEFAULT '',
  websearchurl  TEXT    NOT NULL DEFAULT '',
  searchname    TEXT    NOT NULL DEFAULT '',
  searchid      TEXT    NOT NULL DEFAULT '',
  searchpic     TEXT    NOT NULL DEFAULT '',
  searchstarr   TEXT    NOT NULL DEFAULT '',
  detaillist    TEXT    NOT NULL DEFAULT '',
  detailxl      TEXT    NOT NULL DEFAULT '',
  detailjs      TEXT    NOT NULL DEFAULT '',
  detailjsurl   TEXT    NOT NULL DEFAULT '',
  isActive      BOOLEAN NOT NULL DEFAULT 1,
  updatedAt     INTEGER NOT NULL,
  dyurl         TEXT    NOT NULL DEFAULT '',
  UNIQUE(name)
);
''',
  // API 源
  '''
CREATE TABLE apiyuan (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT    NOT NULL,
  searchurl   TEXT    NOT NULL,
  searchua    TEXT    NOT NULL DEFAULT '',
  detailurl   TEXT    NOT NULL DEFAULT '',
  detailua    TEXT    NOT NULL DEFAULT '',
  isActive    BOOLEAN NOT NULL DEFAULT 1,
  dyurl       TEXT    NOT NULL DEFAULT '',
  UNIQUE(name)
);
''',
  // 订阅
  '''
CREATE TABLE subscription (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  dyname     TEXT    NOT NULL,
  dyurl      TEXT    NOT NULL UNIQUE,
  dyzz       TEXT    NOT NULL DEFAULT '',
  lastSyncAt INTEGER NOT NULL
);
''',
  // 收藏
  '''
CREATE TABLE favorite (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  name      TEXT    NOT NULL,
  laiyuan   TEXT    NOT NULL DEFAULT '',
  imgurl    TEXT    NOT NULL DEFAULT '',
  detailurl TEXT    NOT NULL DEFAULT '',
  detailua  TEXT    NOT NULL DEFAULT '',
  xianlu    INTEGER NOT NULL DEFAULT 0,
  jishu     INTEGER NOT NULL DEFAULT 0,
  addedAt   INTEGER NOT NULL
);
''',
  // 历史
  '''
CREATE TABLE history (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  name         TEXT    NOT NULL,
  laiyuan      TEXT    NOT NULL DEFAULT '',
  imgurl       TEXT    NOT NULL DEFAULT '',
  detailurl    TEXT    NOT NULL DEFAULT '',
  detailua     TEXT    NOT NULL DEFAULT '',
  xianlu       INTEGER NOT NULL DEFAULT 0,
  jishu        INTEGER NOT NULL DEFAULT 0,
  progress     REAL    NOT NULL DEFAULT 0,
  lastPlayedAt INTEGER NOT NULL
);
''',
  // 下载
  '''
CREATE TABLE download (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  name           TEXT    NOT NULL,
  laiyuan        TEXT    NOT NULL DEFAULT '',
  imgurl         TEXT    NOT NULL DEFAULT '',
  detailurl      TEXT    NOT NULL DEFAULT '',
  playurl        TEXT    NOT NULL DEFAULT '',
  jishu          INTEGER NOT NULL DEFAULT 0,
  progress       REAL    NOT NULL DEFAULT 0,
  status         TEXT    NOT NULL DEFAULT 'pending',
  filePath       TEXT    NOT NULL DEFAULT '',
  fileSize       INTEGER NOT NULL DEFAULT 0,
  downloadedSize INTEGER NOT NULL DEFAULT 0,
  addedAt        INTEGER NOT NULL
);
''',
  // 设置
  '''
CREATE TABLE settings (
  key       TEXT PRIMARY KEY,
  value     TEXT NOT NULL DEFAULT '',
  updatedAt INTEGER NOT NULL
);
''',
  // 解析设置
  '''
CREATE TABLE jiexisetting (
  bianma TEXT PRIMARY KEY,
  zhuurl TEXT NOT NULL DEFAULT '',
  beiurl TEXT NOT NULL DEFAULT ''
);
''',
  // 搜索历史（v1 即存在，v3 时补充索引语义）
  '''
CREATE TABLE search_history (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  keyword    TEXT    NOT NULL,
  searchedAt INTEGER NOT NULL
);
''',
];

/// v2 迁移：重建 zhanyuan / apiyuan，将唯一约束从 `name` 改为 `(name, dyurl)`。
///
/// 动机：同一站点可来自多个订阅源（dyurl 区分），仅按 name 唯一会误删。
const List<String> _v2Migrate = <String>[
  // zhanyuan：重建并改唯一约束
  '''
CREATE TABLE zhanyuan_new (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  name          TEXT    NOT NULL,
  searchUrl     TEXT    NOT NULL,
  searchUA      TEXT    NOT NULL DEFAULT '',
  playUA        TEXT    NOT NULL DEFAULT '',
  websearchurl  TEXT    NOT NULL DEFAULT '',
  searchname    TEXT    NOT NULL DEFAULT '',
  searchid      TEXT    NOT NULL DEFAULT '',
  searchpic     TEXT    NOT NULL DEFAULT '',
  searchstarr   TEXT    NOT NULL DEFAULT '',
  detaillist    TEXT    NOT NULL DEFAULT '',
  detailxl      TEXT    NOT NULL DEFAULT '',
  detailjs      TEXT    NOT NULL DEFAULT '',
  detailjsurl   TEXT    NOT NULL DEFAULT '',
  isActive      BOOLEAN NOT NULL DEFAULT 1,
  updatedAt     INTEGER NOT NULL,
  dyurl         TEXT    NOT NULL DEFAULT '',
  UNIQUE(name, dyurl)
);
''',
  'INSERT INTO zhanyuan_new SELECT * FROM zhanyuan;',
  'DROP TABLE zhanyuan;',
  'ALTER TABLE zhanyuan_new RENAME TO zhanyuan;',
  // apiyuan：同样重建
  '''
CREATE TABLE apiyuan_new (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT    NOT NULL,
  searchurl   TEXT    NOT NULL,
  searchua    TEXT    NOT NULL DEFAULT '',
  detailurl   TEXT    NOT NULL DEFAULT '',
  detailua    TEXT    NOT NULL DEFAULT '',
  isActive    BOOLEAN NOT NULL DEFAULT 1,
  dyurl       TEXT    NOT NULL DEFAULT '',
  UNIQUE(name, dyurl)
);
''',
  'INSERT INTO apiyuan_new SELECT * FROM apiyuan;',
  'DROP TABLE apiyuan;',
  'ALTER TABLE apiyuan_new RENAME TO apiyuan;',
];

/// v3 迁移：为搜索历史补索引（表已在 v1 建好）。
const List<String> _v3Migrate = <String>[
  'CREATE INDEX IF NOT EXISTS idx_search_history_time ON search_history(searchedAt DESC);',
  'CREATE INDEX IF NOT EXISTS idx_history_time ON history(lastPlayedAt DESC);',
  'CREATE INDEX IF NOT EXISTS idx_favorite_time ON favorite(addedAt DESC);',
];

/// v4 迁移：download 表新增 4 个可空字段（云盘 / 网盘下载支持）。
///
/// ⚠️ 这 4 个字段**必须可空**——旧版本写入的行这些列为 NULL，
/// 读取时需容忍 NULL（conformance fixture `sample_v4.sqlite3` 已覆盖此用例）。
const List<String> _v4Migrate = <String>[
  'ALTER TABLE download ADD COLUMN sourceType TEXT;',
  'ALTER TABLE download ADD COLUMN engineKey  TEXT;',
  'ALTER TABLE download ADD COLUMN vodId      TEXT;',
  'ALTER TABLE download ADD COLUMN headers    TEXT;',
];

/// v4 新增的可空列名（读取时需容忍 NULL）。
const List<String> kDownloadV4NullableColumns = <String>[
  'sourceType',
  'engineKey',
  'vodId',
  'headers',
];

/// 按版本号返回该版本的迁移语句。
///
/// 用法：`for (var v = 1; v <= kSchemaVersion; v++) { ... }`
/// 约定：版本 N 的语句把库从 N-1 升到 N；v1 即初始建库。
List<String> migrationFor(int version) {
  switch (version) {
    case 1:
      return _v1CreateTables;
    case 2:
      return _v2Migrate;
    case 3:
      return _v3Migrate;
    case 4:
      return _v4Migrate;
    default:
      throw ArgumentError.value(version, 'version', '未知的 Schema 版本');
  }
}

/// 完整迁移链（从空库到 [kSchemaVersion]）。
List<String> fullMigrationChain() {
  final List<String> all = <String>[];
  for (int v = 1; v <= kSchemaVersion; v++) {
    all.addAll(migrationFor(v));
  }
  return all;
}
