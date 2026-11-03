-- vbox 契约层 v1.0 · SQLite DDL
-- 来源：vbox iOS DatabaseManager.swift（GRDB migrations v1-v4）逆向提取
-- 冻结日期：2026-09-29
-- 约束：Flutter 端必须生成完全一致的 schema，且支持 v1→v4 迁移链

-- ============================================================
-- v1_createTables
-- ============================================================

CREATE TABLE IF NOT EXISTS zhanyuan (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    searchUrl    TEXT NOT NULL,
    searchUA     TEXT NOT NULL DEFAULT 'Mozilla/5.0 (Linux; Android 12; Redmi K30 Pro Build/SKQ1.220303.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 Mobile Safari/537.36',
    playUA       TEXT NOT NULL DEFAULT '',
    websearchurl TEXT NOT NULL DEFAULT '',
    searchname   TEXT NOT NULL DEFAULT '',
    searchid     TEXT NOT NULL DEFAULT '',
    searchpic    TEXT NOT NULL DEFAULT '',
    searchstarr  TEXT NOT NULL DEFAULT '',
    detaillist   TEXT NOT NULL DEFAULT '',
    detailxl     TEXT NOT NULL DEFAULT '',
    detailjs     TEXT NOT NULL DEFAULT '',
    detailjsurl  TEXT NOT NULL DEFAULT '',
    isActive     BOOLEAN NOT NULL DEFAULT 1,
    updatedAt    INTEGER NOT NULL,
    -- v2 新增
    dyurl        TEXT NOT NULL DEFAULT '',
    UNIQUE(name, dyurl)          -- v2 将 v1 的 UNIQUE(name) 改为 UNIQUE(name, dyurl)
);

CREATE TABLE IF NOT EXISTS apiyuan (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT NOT NULL,
    searchurl TEXT NOT NULL,
    searchua  TEXT NOT NULL DEFAULT '',
    detailurl TEXT NOT NULL DEFAULT '',
    detailua  TEXT NOT NULL DEFAULT '',
    isActive  BOOLEAN NOT NULL DEFAULT 1,
    -- v2 新增
    dyurl     TEXT NOT NULL DEFAULT '',
    UNIQUE(name, dyurl)          -- v2 将 v1 的 UNIQUE(name) 改为 UNIQUE(name, dyurl)
);

CREATE TABLE IF NOT EXISTS subscription (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    dyname      TEXT NOT NULL,
    dyurl       TEXT NOT NULL UNIQUE,
    dyzz        TEXT NOT NULL DEFAULT '',
    lastSyncAt  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS favorite (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT NOT NULL,
    laiyuan   TEXT NOT NULL DEFAULT '',
    imgurl    TEXT NOT NULL DEFAULT '',
    detailurl TEXT NOT NULL DEFAULT '',
    detailua  TEXT NOT NULL DEFAULT '',
    xianlu    INTEGER NOT NULL DEFAULT 0,
    jishu     INTEGER NOT NULL DEFAULT 0,
    addedAt   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS history (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    laiyuan      TEXT NOT NULL DEFAULT '',
    imgurl       TEXT NOT NULL DEFAULT '',
    detailurl    TEXT NOT NULL DEFAULT '',
    detailua     TEXT NOT NULL DEFAULT '',
    xianlu       INTEGER NOT NULL DEFAULT 0,
    jishu        INTEGER NOT NULL DEFAULT 0,
    progress     REAL NOT NULL DEFAULT 0,
    lastPlayedAt INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key       TEXT PRIMARY KEY,
    value     TEXT NOT NULL DEFAULT '',
    updatedAt INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS jiexisetting (
    bianma TEXT PRIMARY KEY,
    zhuurl TEXT NOT NULL DEFAULT '',
    beiurl TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS search_history (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    keyword    TEXT NOT NULL,
    searchedAt INTEGER NOT NULL
);

-- ============================================================
-- v2_add_dyurl  「迁移方式：重建表」
-- 客户端升级时对已存在的 zhanyuan/apiyuan 执行：
--   1) CREATE TABLE xxx_v2 (... UNIQUE(name, dyurl))
--   2) INSERT INTO xxx_v2 SELECT <旧列>, '' FROM xxx
--   3) DROP TABLE xxx
--   4) ALTER TABLE xxx_v2 RENAME TO xxx
-- 注意：Flutter 端 sqflite 必须复刻完全相同的迁移顺序
-- ============================================================

-- ============================================================
-- v3_add_download
-- ============================================================

CREATE TABLE IF NOT EXISTS download (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT NOT NULL,
    laiyuan        TEXT NOT NULL DEFAULT '',
    imgurl         TEXT NOT NULL DEFAULT '',
    detailurl      TEXT NOT NULL DEFAULT '',
    playurl        TEXT NOT NULL DEFAULT '',
    jishu          INTEGER NOT NULL DEFAULT 0,
    progress       REAL NOT NULL DEFAULT 0,
    status         TEXT NOT NULL DEFAULT 'pending',   -- pending|downloading|completed|failed
    filePath       TEXT NOT NULL DEFAULT '',
    fileSize       INTEGER NOT NULL DEFAULT 0,
    downloadedSize INTEGER NOT NULL DEFAULT 0,
    addedAt        INTEGER NOT NULL
    -- v4 新增 4 列（见下）
);

-- ============================================================
-- v4_add_download_columns  「迁移方式：ALTER TABLE ADD COLUMN」
-- 关键：4 个字段均为可空（旧数据为 NULL），Flutter 模型必须可空
-- ============================================================

ALTER TABLE download ADD COLUMN sourceType TEXT;   -- "normal" | "cloud"
ALTER TABLE download ADD COLUMN engineKey  TEXT;   -- 蜘蛛引擎 key
ALTER TABLE download ADD COLUMN vodId      TEXT;   -- playerContent 参数
ALTER TABLE download ADD COLUMN headers    TEXT;   -- JSON 编码请求头

-- ============================================================
-- 最终表结构快照（迁移后状态）
-- ============================================================
-- 表清单：zhanyuan, apiyuan, subscription, favorite, history,
--         settings, jiexisetting, search_history, download  （共 9 张）
--
-- 唯一约束：
--   zhanyuan.name + zhanyuan.dyurl
--   apiyuan.name  + apiyuan.dyurl
--   subscription.dyurl
--
-- 主键：
--   zhanyuan/apiyuan/subscription/favorite/history/download/search_history → id (AUTOINCREMENT)
--   settings.key / jiexisetting.bianma → TEXT 主键
