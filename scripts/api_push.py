#!/usr/bin/env python3
"""当 github.com:443 不可达时，用 GitHub REST API（api.github.com）推送提交。

归并说明（D2 闭环，v6.27）：本文件由原 `api_push.py`（全量上传版）与
`api_push2.py`（diff 模式版）归并而来，采用 diff 模式实现：
只上传「本地 HEAD 相对远程 HEAD 有差异」的文件，用 base_tree 叠加，
parent = 远程真实 SHA → 保证 fast-forward；`api_push2.py` 已删除。

要点：
  · CI_MANAGED 文件（.version / Info.plist / project.pbxproj / CHANGELOG.md）
    永不纳入推送/删除集 —— 防止本地旧值回推、回退 CI 自动 bump 的版本号
    （历史上曾回退 3.1615 → 3.1614）。
  · 关闭 core.quotepath，避免非 ASCII 路径被转义后与远程路径比对误判。
  · --dry-run 只显示差异，不推送。

用法：
  python3 scripts/api_push.py            # 自动 diff 推送
  python3 scripts/api_push.py --dry-run  # 只显示差异，不推送
"""
from __future__ import annotations

import base64
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

REPO = "q2787244398/vboxapp"
TOKEN = os.environ["GITHUB_TOKEN"]
ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.github.com"

# 不纳入版本控制的路径前缀（本地临时日志等）
SKIP_PREFIXES = (".uploads/", ".git/")

# CI 自动提交管理的文件（版本号 bump / CHANGELOG 自动更新）。
# 本地旧值若被推送回去会回退 CI 的自动提交（例：曾回退 3.1615 → 3.1614），
# 因此这些文件永不纳入推送/删除集。
CI_MANAGED = frozenset({
    "vbox/Info.plist",
    "vbox.xcodeproj/project.pbxproj",
    "CHANGELOG.md",
    # build-ipa.yml 的版本 bump 任务会写入该文件（`git add … .version`），
    # changelog.yml 亦以它为触发源 → 属 CI 管理，本地旧值不得回推。
    ".version",
})

COMMIT_MSG = """feat(stage-1): backup_manager — AES-256-GCM + PBKDF2 字节级兼容

- lib/data/backup_manager.dart
  · PBKDF2-HMAC-SHA256 / 100000 迭代 / key 32B / salt 16B / iv 12B / tag 16B / 无 AAD
  · cipher='AES-256-GCM'、kdf='PBKDF2-HMAC-SHA256' 字面值精确匹配
  · 口令 UTF-8；标准 Base64；不压缩
  · BackupEnvelope/BackupMeta/BackupCategory(9) + 5 种错误类型
- scripts/check_backup_contract.py  备份契约验证（5 组，含 AES-GCM 往返）

第 1 轮进度：契约镜像 ✅ 模型 ✅ database_manager ✅ prefs_manager ✅ backup_manager ✅"""


def req(method: str, url: str, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", f"Bearer {TOKEN}")
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "vbox-ci")
    if data:
        r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=90) as resp:
        return json.loads(resp.read() or "null")


def local_files() -> dict[str, str]:
    """本地 HEAD 的 path→blob-sha。"""
    # 必须关闭 core.quotepath，否则非 ASCII 路径会被转义成 \346\250\241...，
    # 与远程真实路径无法比对（会反复误判为新增/删除）
    out = subprocess.run(
        ["git", "-c", "core.quotepath=false", "ls-tree", "-r", "HEAD"],
        cwd=ROOT, capture_output=True, check=True
    ).stdout.decode(errors="surrogateescape")
    res = {}
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        mode, typ, sha = meta.split()
        res[path] = sha
    return res


def local_head_message() -> str:
    """取本地 HEAD 的提交信息，使远程提交信息与本地一致。"""
    out = subprocess.run(
        ["git", "log", "-1", "--pretty=%B"], cwd=ROOT,
        capture_output=True, check=True
    ).stdout.decode(errors="replace")
    return out.strip()


def main() -> int:
    dry = "--dry-run" in sys.argv
    ref = req("GET", f"{API}/repos/{REPO}/git/ref/heads/main")
    base_sha = ref["object"]["sha"]
    base_tree = req("GET", f"{API}/repos/{REPO}/git/commits/{base_sha}")["tree"]["sha"]
    print("远程 HEAD:", base_sha[:8])

    tree = req("GET", f"{API}/repos/{REPO}/git/trees/{base_tree}?recursive=1")
    remote = {e["path"]: e["sha"] for e in tree["tree"] if e["type"] == "blob"}

    local = local_files()
    changed = [
        p for p, sha in local.items()
        if (not p.startswith(SKIP_PREFIXES) and p not in CI_MANAGED
        and remote.get(p) != sha)
    ]
    # 删除集：远程有、本地 HEAD 已无（base_tree 会保留未声明的旧条目，
    # 必须显式传 sha=None 才能删除）
    deleted = [
        p for p in remote
        if p not in local and not p.startswith(SKIP_PREFIXES) and p not in CI_MANAGED
    ]
    print(f"需上传: {len(changed)} 个文件 · 需删除: {len(deleted)} 个")
    for p in changed:
        print("   ", "~" if p in remote else "+", p)
    for p in sorted(deleted):
        print("    -", p)
    if dry:
        return 0
    if not changed and not deleted:
        print("无差异，无需推送")
        return 0

    items = []
    for path in changed:
        p = ROOT / path
        if not p.exists():
            continue
        blob = p.read_bytes()
        try:
            content, enc = blob.decode("utf-8"), "utf-8"
        except UnicodeDecodeError:
            content, enc = base64.b64encode(blob).decode(), "base64"
        mode = "100755" if path.endswith(".sh") else "100644"
        res = req("POST", f"{API}/repos/{REPO}/git/blobs",
                  {"content": content, "encoding": enc})
        items.append({"path": path, "mode": mode, "type": "blob", "sha": res["sha"]})
    for path in sorted(deleted):
        items.append({"path": path, "mode": "100644", "type": "blob", "sha": None})

    new_tree = req("POST", f"{API}/repos/{REPO}/git/trees",
                   {"base_tree": base_tree, "tree": items})
    msg = local_head_message() or COMMIT_MSG
    if deleted:
        msg += f"\n\n(远程同步删除 {len(deleted)} 个文件)"
    commit = req("POST", f"{API}/repos/{REPO}/git/commits",
                 {"message": msg, "tree": new_tree["sha"], "parents": [base_sha]})
    upd = req("PATCH", f"{API}/repos/{REPO}/git/refs/heads/main",
              {"sha": commit["sha"], "force": False})
    print("✅ 已推送:", upd["object"]["sha"][:8])

    # 回写远程 SHA，便于本地对齐
    (ROOT / ".git" / "REMOTE_HEAD").write_text(commit["sha"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
