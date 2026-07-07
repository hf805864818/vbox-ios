#!/bin/bash

cd "$(dirname "$0")/.."

if [ -f ".version" ]; then
    source .version
else
    MAJOR_VERSION=3
    BASE_BUILD=0
fi

COMMIT_COUNT=$(git rev-list --count HEAD)
EXISTING_BUILD=$(grep -m 1 "CURRENT_PROJECT_VERSION =" vbox.xcodeproj/project.pbxproj | sed -E 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/')

if [ -n "${EXISTING_BUILD}" ]; then
    BUILD_NUMBER=$((EXISTING_BUILD + 1))
else
    BUILD_NUMBER=$((COMMIT_COUNT + BASE_BUILD))
fi

MARKETING_VERSION="${MAJOR_VERSION}.${BUILD_NUMBER}"

echo "=== Auto Version Bump ==="
echo "Major Version: ${MAJOR_VERSION}"
echo "Base Build: ${BASE_BUILD}"
echo "Commit Count: ${COMMIT_COUNT}"
echo "Total Build Number: ${BUILD_NUMBER}"
echo "Marketing Version: ${MARKETING_VERSION}"
echo "========================="

echo "Updating vbox.xcodeproj/project.pbxproj..."
sed -i.bak "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};/g" vbox.xcodeproj/project.pbxproj
sed -i.bak "s/MARKETING_VERSION = [0-9]*\.[0-9]*;/MARKETING_VERSION = ${MARKETING_VERSION};/g" vbox.xcodeproj/project.pbxproj
rm -f vbox.xcodeproj/project.pbxproj.bak

echo "Updating vbox/Info.plist..."
sed -i.bak "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>[0-9]*\.[0-9]*<\/string>/<string>${MARKETING_VERSION}<\/string>/}" vbox/Info.plist
sed -i.bak "/<key>CFBundleVersion<\/key>/{n;s/<string>[0-9]*<\/string>/<string>${BUILD_NUMBER}<\/string>/}" vbox/Info.plist
rm -f vbox/Info.plist.bak

echo ""
echo "✅ Version updated successfully!"
echo "📦 New Version: ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
