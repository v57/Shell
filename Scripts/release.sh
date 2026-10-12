#!/bin/zsh
# Builds the direct download for GitHub Releases: a Developer ID signed,
# notarized and stapled Shell.zip, served at the stable link
# https://github.com/v57/Shell/releases/latest/download/Shell.zip
#
# Needs, once per Mac:
# - a "Developer ID Application" certificate for team AUCR797TMH in the keychain
#   (Xcode > Settings > Accounts > Manage Certificates);
# - a notarytool profile:
#   xcrun notarytool store-credentials shell-notary --apple-id <id> --team-id AUCR797TMH
# Before the first release, deploy the CloudKit schema to Production in the
# CloudKit Console (Release builds use the production environment).
#
# Usage: Scripts/release.sh   (NOTARY_PROFILE=<name> to use another profile)
set -euo pipefail

root=${0:A:h:h}
out=$root/build/release
profile=${NOTARY_PROFILE:-shell-notary}

rm -rf $out
mkdir -p $out
cd $root

echo "Archiving"
xcodebuild archive -project Shell.xcodeproj -scheme Shell -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $out/Shell.xcarchive > $out/archive.log

echo "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath $out/Shell.xcarchive \
  -exportOptionsPlist Config/ExportOptions-DeveloperID.plist -exportPath $out/export > $out/export.log
app=$out/export/Shell.app
codesign --verify --strict --deep $app

echo "Notarizing"
ditto -c -k --keepParent $app $out/Shell-notarize.zip
xcrun notarytool submit $out/Shell-notarize.zip --keychain-profile $profile --wait
xcrun stapler staple $app
spctl --assess --type execute --verbose $app

ditto -c -k --keepParent $app $out/Shell.zip
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $app/Contents/Info.plist)
echo "Shell $version: $out/Shell.zip ($(du -h $out/Shell.zip | cut -f1))"
shasum -a 256 $out/Shell.zip
