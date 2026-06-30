import re

with open("vbox.xcodeproj/project.pbxproj", "r") as f:
    content = f.read()

# Files to add: (name, group, fileRefID, buildFileID)
# group: "Models", "Services", "Views"
files = [
    ("YBoxService2.swift",       "Services", "B10200", "A10200"),
    ("WelfareCrawlerService.swift", "Services", "B10201", "A10201"),
    ("WelfareCrawlerConfig.swift",   "Models",  "B10202", "A10202"),
    ("WelfareSubViews.swift",      "Views",   "B10203", "A10203"),
]

# --- 1. Add PBXBuildFile entries ---
idx = content.find("/* End PBXBuildFile section */")
extra = ""
for name, group, fr, bf in files:
    extra += f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};\n"
content = content[:idx] + extra + content[idx:]

# --- 2. Add PBXFileReference entries ---
idx = content.find("/* End PBXFileReference section */")
extra = ""
for name, group, fr, bf in files:
    extra += f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
content = content[:idx] + extra + content[idx:]

# --- 3. Add to groups (Models / Services / Views) ---
for group_name in ["Models", "Services", "Views"]:
    group_files = [(n, fr) for n, g, fr, bf in files if g == group_name]
    if not group_files:
        continue

    # Find the group in content
    pattern = rf'(\t\t(G[0-9A-F]+) /\* {group_name} \*/ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)(.*?)(\t\t\t\);)'
    m = re.search(pattern, content, re.DOTALL)
    if not m:
        print(f"WARNING: Group {group_name} not found!")
        continue

    prefix, gid, children_str, suffix = m.groups()

    new_children = children_str
    for name, fr in group_files:
        if fr not in new_children:
            new_children += f"\t\t\t\t{fr} /* {name} */,\n"

    content = content[:m.start()] + prefix + new_children + suffix + content[m.end():]

# --- 4. Add to PBXSourcesBuildPhase ---
idx = content.find("/* End PBXSourcesBuildPhase section */")
extra = ""
for name, group, fr, bf in files:
    extra += f"\t\t\t\t{bf} /* {name} in Sources */,\n"
content = content[:idx] + extra + content[idx:]

with open("vbox.xcodeproj/project.pbxproj", "w") as f:
    f.write(content)
print("Done - added 4 files to Xcode project")
