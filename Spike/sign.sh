#!/usr/bin/env bash
# THROWAWAY SPIKE: build unsigned, then ad-hoc sign with the restricted entitlements.
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -workspace Spike.xcworkspace -scheme SpikeApp -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build > build.log 2>&1 \
  || { grep -E "error:" build.log | head; exit 1; }
app="build/Build/Products/Debug/SpikeApp.app"
ext="$app/Contents/Library/SystemExtensions/SpikeExt.systemextension"
codesign --force --sign - --entitlements Ext/SpikeExt.entitlements "$ext"
codesign --force --sign - --entitlements App/SpikeApp.entitlements "$app"
codesign -dvv --entitlements - "$ext" 2>&1 | grep -E "Identifier|Signature|endpoint-security|TeamIdentifier"
echo "built: $app"
