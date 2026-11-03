# vbox 契约层索引 v1.0

> **冻结日期**：2026-09-29
> **契约版本**：`contract-v1.0`
> **来源**：从 `vboxapp/vbox/`（iOS Swift 实现）逆向提取
> **约束**：Flutter 端必须严格遵循本契约；契约变更须走门禁流程（同步三端 + conformance）

---

## 1. 契约文件清单

| 文件 | 类型 | 内容 | 状态 |
|------|------|------|------|
| `schema/schema_v1.sql` | SQLite DDL | 9 表 + v1→v4 迁移链 | ✅ |
| `schema/prefs_keys_v1.json` | 键名契约 | 98 键 + 7 敏感键（v1.3，B3 裁定） | ✅ |
| `schema/site_v1.json` | JSON Schema | SiteConfig（20 字段） | ✅ |
| `schema/welfare_v1.json` | JSON Schema | 福利平台（29 字段） | ✅ |
| `schema/manifest_v1.json` | JSON Schema | 远程源 manifest + all_sources | ✅ |
| `docs/abi_v1.md` | ABI 规范 | Spider 5 引擎统一接口 | ✅ |
| `docs/backup_v1.md` | 格式规范 | AES-256-GCM + PBKDF2 备份 | ✅ |
| `docs/bug_report_template.yaml` | 模板 | 人测结构化反馈 | ✅ |
| `docs/stage_check_template.yaml` | 模板 | E.10b 阶段检查报告 | ✅ |
| `docs/android-compat.md` | 清单 | minSdk 24 依赖与配置 | ✅ |

---

## 2. 一致性测试样本

| 文件 | 内容 | 用途 |
|------|------|------|
| `conformance/fixtures/sample_v4.sqlite3` | SQLite 样本（9 表 + v4 可空字段验证） | 数据库互通测试 |
| `conformance/fixtures/spider_io_v1.json` | Spider 5 操作 I/O + 容错用例 + 编码链 | 引擎行为比对 |
| `conformance/fixtures/backup_v1.json` | 加密参数 + envelope + payload + 11 测试用例 | 备份双向验证 |

---

## 3. 核心约束速查

### 3.1 数据库

| 约束 | 值 |
|------|-----|
| 表数 | 9（zhanyuan/apiyuan/subscription/favorite/history/settings/jiexisetting/search_history/download） |
| 迁移链 | v1→v2（重建表）→v3（新建 download）→v4（ALTER ADD COLUMN ×4） |
| v2 唯一约束变更 | `UNIQUE(name)` → `UNIQUE(name, dyurl)` |
| v4 可空字段 | `sourceType` / `engineKey` / `vodId` / `headers` |

### 3.2 加密

| 参数 | 值 |
|------|-----|
| 算法 | AES-256-GCM |
| KDF | PBKDF2-HMAC-SHA256 |
| 迭代次数 | **100,000** |
| salt | **16 字节** |
| IV | **12 字节** |
| 密钥 | **32 字节** |
| GCM tag | **16 字节** |
| AAD | 无 |
| 压缩 | **无** |

### 3.3 Spider

| 约束 | 值 |
|------|-----|
| 操作数 | 5（home/search/category/detail/player） |
| 引擎数 | 5（JavaScriptCore / QuickJS / Node / NodeLX / Python） |
| HTTP 超时 | 15s |
| 容错字段 | `type_id`/`type_name`/`vod_id`/`vod_name`/`vod_pic` 支持 String/Int/Double |
| urls 回填 | `urls ?? [url]`（url 非空时） |

### 3.4 平台

| 约束 | 值 |
|------|-----|
| minSdk | **24**（Android 7.0） |
| compileSdk / targetSdk | 36 |
| 分辨率覆盖 | 96.6% |
| 分发 | 侧载（不提交商店） |

---

## 4. 契约变更门禁

```
提出变更
   ↓
评估影响（三端？ 数据？ 备份？）
   ↓
更新契约文件 + 版本号
   ↓
同步三端实现
   ↓
跑 conformance 全部用例
   ↓
人工评审
   ↓
打新 tag（contract-v1.1）
```

**规则**：
- 契约变更**不得**只改一端
- 若 iOS 实现与契约不符 → **以 iOS 为准**修订契约（D1）
- conformance 未通过 → 不得发布

---

## 5. 阶段检查（D13 / E.10b）

每阶段完成后必须输出《阶段遗漏检查报告》（模板见 `docs/stage_check_template.yaml`）：

**六类扫描**：契约一致性 / 数据与状态 / 平台差异 / 功能完整性 / 质量基线 / 交付物与文档

**硬门禁**：不通过不得进入下一阶段。

---

## 6. 推送流程（D15）

```
阶段完成 → E.10b 检查通过 → 人工确认
              ↓
        ① 更新版本号
        ② 提交（含 Stage check: pass 标记）
        ③ push vboxapp/main
        ④ 打 tag（stage-N）
        ⑤ 远程校验
```

---

## 7. 目录结构（vboxapp）

```
vboxapp/
├── vbox/                    iOS 现有代码（Swift，契约来源）
├── contract/                ⭐ 契约层
│   ├── schema/              DDL + JSON Schema
│   └── docs/                ABI / 备份 / 模板 / 兼容清单
├── conformance/             ⭐ 一致性测试
│   ├── fixtures/            测试样本
│   └── runner/              各端运行器
├── lib/                     Flutter 业务层（待建）
├── go-proxy/                Go 代理（复用）
├── quickjs/                 QuickJS（复用）
└── .github/                 CI（待改造为多端）
```

---

## 8. 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-09-29 | 首次冻结（第 0 阶段产物） |
