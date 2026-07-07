import re

with open("vbox.xcodeproj/project.pbxproj", "r") as f:
    content = f.read()

new_ids = {
    "ShortDramaService.swift": ("B10126", "A10126"),
    "ShortDramaView.swift": ("B10127", "A10127"),
    "ShortDramaDetailView.swift": ("B10128", "A10128"),
}

# PBXBuildFile
idx = content.find("/* End PBXBuildFile section */")
extra = ""
for name, (fr, bf) in new_ids.items():
    extra += f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};\n"
content = content[:idx] + extra + content[idx:]

# PBXFileReference
idx = content.find("/* End PBXFileReference section */")
extra = ""
for name, (fr, bf) in new_ids.items():
    extra += f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
content = content[:idx] + extra + content[idx:]

# Views group
m = __import__("re").search(r"([0-9A-F]+) /\* Views \*/", content)
if m:
    gid = m.group(1)
    pat = r"(\t\t\t\t" + re.escape(gid) + r' \*\/ = \{\n\t\t\t\t\tisa = PBXGroup;\n\t\t\t\t\tchildren = \(\n)(.*?)(\t\t\t\t\t\);)'
    def add_v(m2):
        h, c, f = m2.groups()
        for name, (fr, bf) in new_ids.items():
            if "View" in name and fr not in c:
                c += f"\t\t\t\t\t\t{fr} /* {name} */,\n"
        return h + c + f
    content = re.sub(pat, add_v, content, count=1, flags=re.DOTALL)

# Services group
m = __import__("re").search(r"([0-9A-F]+) /\* Services \*/", content)
if m:
    gid = m.group(1)
    pat = r"(\t\t\t\t" + re.escape(gid) + r' \*\/ = \{\n\t\t\t\t\tisa = PBXGroup;\n\t\t\t\t\tchildren = \(\n)(.*?)(\t\t\t\t\t\);)'
    def add_s(m2):
        h, c, f = m2.groups()
        for name, (fr, bf) in new_ids.items():
            if "Service" in name and fr not in c:
                c += f"\t\t\t\t\t\t{fr} /* {name} */,\n"
        return h + c + f
    content = re.sub(pat, add_s, content, count=1, flags=re.DOTALL)

# Sources phase
idx = content.find("/* End PBXSourcesBuildPhase section */")
extra = ""
for name, (fr, bf) in new_ids.items():
    extra += f"\t\t\t\t{bf} /* {name} in Sources */,\n"
content = content[:idx] + extra + content[idx:]

with open("vbox.xcodeproj/project.pbxproj", "w") as f:
    f.write(content)
print("Done")
