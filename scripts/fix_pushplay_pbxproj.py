#!/usr/bin/env python3
"""修复 project.pbxproj 中 PushPlayView/PushPlayStore 的路径问题。

xcodeproj gem 的 project.new_file 会把完整路径写入 PBXFileReference.path，
但同组其他文件只用文件名。这导致 Xcode 解析时路径被重复拼接。
本脚本确保 PBXFileReference.path 只用文件名，与同组其他文件一致。
"""
import re
import sys
import uuid

PBXPROJ = "vbox.xcodeproj/project.pbxproj"

FILES = [
    {
        "name": "PushPlayView.swift",
        "correct_path": "PushPlayView.swift",
        "group_name": "Views",
        "group_path": "Views",
    },
    {
        "name": "PushPlayStore.swift",
        "correct_path": "PushPlayStore.swift",
        "group_name": "Services",
        "group_path": "Services",
    },
]


def gen_hex_id():
    return uuid.uuid4().hex[:24].upper()


def fix_pbxproj():
    with open(PBXPROJ) as f:
        content = f.read()

    for fi in FILES:
        name = fi["name"]
        correct_path = fi["correct_path"]
        group_path = fi["group_path"]

        # 1. 修复 PBXFileReference 的 path 字段
        # 匹配: {hex} /* {name} */ = {isa = PBXFileReference; ... path = {wrong_path}; ... };
        pattern = re.compile(
            r'([A-F0-9]+)\s*/\*\s*' + re.escape(name) + r'\s*\*/\s*=\s*\{'
            r'isa = PBXFileReference;'
            r'.*?'
            r'path = ([^;]+);'
            r'(.*?\};)',
            re.DOTALL,
        )
        match = pattern.search(content)
        if match:
            file_ref_id = match.group(1)
            current_path = match.group(2).strip()
            rest = match.group(3)
            if current_path != correct_path:
                # 替换 path 为正确值
                old_entry = match.group(0)
                new_entry = old_entry.replace(
                    f"path = {current_path};", f"path = {correct_path};"
                )
                content = content.replace(old_entry, new_entry)
                print(f"修复 {name}: path={current_path} -> {correct_path}")
            else:
                print(f"{name} path 已正确: {correct_path}")
        else:
            # 文件不存在，需要创建
            file_ref_id = gen_hex_id()
            # 找到所属 group 的最后一个文件引用，在其后添加
            # 找 group 的 children 数组
            group_pattern = re.compile(
                r'(/\*\s*' + re.escape(group_name) + r'\s*\*/\s*=\s*\{[^}]*?\};)',
                re.DOTALL,
            )
            group_match = group_pattern.search(content)
            if group_match:
                # 在 group 定义之前插入 PBXFileReference
                fr_entry = (
                    f"\t\t{file_ref_id} /* {name} */ = {{"
                    f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift;"
                    f" path = {correct_path}; sourceTree = \"<group>\"; }};"
                )
                # 找到 PBXFileReference section 的合适位置插入
                # 在 FourHVideoService 的 FileReference 之后插入
                anchor = '1FAAAB2C8F43495F933A2C8A /* FourHVideoService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FourHVideoService.swift; sourceTree = "<group>"; };'
                if anchor in content:
                    content = content.replace(anchor, anchor + "\n" + fr_entry)
                else:
                    print(f"警告: 找不到 FourHVideoService 的 FileReference 锚点")

            # 创建 PBXBuildFile
            build_id = gen_hex_id()
            bf_entry = (
                f"\t\t{build_id} /* {name} in Sources */ = {{"
                f"isa = PBXBuildFile; fileRef = {file_ref_id} /* {name} */; }};"
            )
            anchor_bf = 'A477C1043BC04B0A93AFB2BF /* FourHVideoService.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1FAAAB2C8F43495F933A2C8A /* FourHVideoService.swift */; };'
            if anchor_bf in content:
                content = content.replace(anchor_bf, anchor_bf + "\n" + bf_entry)

            # 添加到 group 的 children 数组
            group_children_anchor = f"\t\t\t\t\t\t\t1FAAAB2C8F43495F933A2C8A /* FourHVideoService.swift */,"
            if group_children_anchor in content:
                content = content.replace(
                    group_children_anchor,
                    group_children_anchor
                    + "\n"
                    + f"\t\t\t\t\t\t\t{file_ref_id} /* {name} */,",
                )

            # 添加到 Sources Build Phase
            src_anchor = "\t\t\t\t\t\t\t\tA477C1043BC04B0A93AFB2BF /* FourHVideoService.swift in Sources */,"
            if src_anchor in content:
                content = content.replace(
                    src_anchor,
                    src_anchor
                    + "\n"
                    + f"\t\t\t\t\t\t\t\t{build_id} /* {name} in Sources */,",
                )

            print(f"已创建 {name} (fileRef={file_ref_id}, build={build_id})")

        # 2. 确保 Sources Build Phase 中有该文件
        src_phase_pattern = re.compile(
            r'/\*\s*' + re.escape(name) + r'\s*in Sources\s*\*/',
        )
        if not src_phase_pattern.search(content):
            # 查找对应的 build ID
            build_id_match = re.search(
                r'([A-F0-9]+)\s*/\*\s*' + re.escape(name) + r'\s*in Sources\s*\*/',
                content,
            )
            if build_id_match:
                build_id = build_id_match.group(1)
                src_anchor = "\t\t\t\t\t\t\t\tA477C1043BC04B0A93AFB2BF /* FourHVideoService.swift in Sources */,"
                if src_anchor in content:
                    content = content.replace(
                        src_anchor,
                        src_anchor
                        + "\n"
                        + f"\t\t\t\t\t\t\t\t{build_id} /* {name} in Sources */,",
                    )
                    print(f"添加 {name} 到 Sources Build Phase")

        # 3. 清理重复的 Sources Build Phase 条目
        lines = content.split("\n")
        new_lines = []
        seen_in_src = set()
        for line in lines:
            m = re.search(
                r"([A-F0-9]+)\s*/\*\s*" + re.escape(name) + r"\s*in Sources\s*\*/,",
                line,
            )
            if m:
                bid = m.group(1)
                if bid in seen_in_src:
                    continue  # 跳过重复
                seen_in_src.add(bid)
            new_lines.append(line)
        content = "\n".join(new_lines)

    with open(PBXPROJ, "w") as f:
        f.write(content)
    print("完成!")


if __name__ == "__main__":
    fix_pbxproj()