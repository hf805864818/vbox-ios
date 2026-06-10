#!/bin/bash
# 自动将 Swift 文件添加到 Xcode 项目

set -e

FILE_NAME="BaiduProxyClient.swift"
FILE_PATH="vbox/Services/${FILE_NAME}"
PBXPROJ="vbox.xcodeproj/project.pbxproj"

# 检查文件是否存在
if [ ! -f "${FILE_PATH}" ]; then
    echo "Error: ${FILE_PATH} not found!"
    exit 1
fi

# 找到当前最大的 A 和 B 编号
MAX_A=$(grep -oE 'A[0-9]+' "${PBXPROJ}" | sed 's/A//' | sort -n | tail -1)
MAX_B=$(grep -oE 'B[0-9]+' "${PBXPROJ}" | sed 's/B//' | sort -n | tail -1)

NEW_A="A$((MAX_A + 1))"
NEW_B="B$((MAX_B + 1))"

echo "Adding ${FILE_NAME} with IDs: ${NEW_A} (BuildFile), ${NEW_B} (FileReference)"

# 1. 在 PBXBuildFile section 添加
sed -i "/A10029 \/\* TokenWebView.swift in Sources \*\/ = {isa = PBXBuildFile; fileRef = B10031 \/\* TokenWebView.swift \*\/; };/a\\
\\t\\t${NEW_A} /* ${FILE_NAME} in Sources */ = {isa = PBXBuildFile; fileRef = ${NEW_B} /* ${FILE_NAME} */; };" "${PBXPROJ}"

# 2. 在 PBXFileReference section 添加
sed -i "/B10034 \/\* DoubanImageProxyServer.swift \*\/ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DoubanImageProxyServer.swift; sourceTree = \"<group>\"; };/a\\
\\t\\t${NEW_B} /* ${FILE_NAME} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${FILE_NAME}; sourceTree = \"<group>\"; };" "${PBXPROJ}"

# 3. 在 PBXGroup 中添加文件引用
sed -i "/B10034 \/\* DoubanImageProxyServer.swift \*\/,/{
    /B10034 \/\* DoubanImageProxyServer.swift \*\/,/{
        /);/a\\
\\t\\t\\t\\t${NEW_B} /* ${FILE_NAME} */,
    }
}" "${PBXPROJ}"

# 4. 在 PBXSourcesBuildPhase 中添加编译引用
sed -i "/A10029 \/\* TokenWebView.swift in Sources \*\/,/{
    /A10029 \/\* TokenWebView.swift in Sources \*\/,/{
        /);/a\\
\\t\\t\\t\\t${NEW_A} /* ${FILE_NAME} in Sources */,
    }
}" "${PBXPROJ}"

echo "✅ ${FILE_NAME} added to Xcode project successfully!"
echo ""
echo "Verifying..."
grep -c "${FILE_NAME}" "${PBXPROJ}"
