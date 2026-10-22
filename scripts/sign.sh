#!/usr/bin/env bash
# Ad-hoc sign a built app inside-out (ADR-0001 finding 1): extension first, then the app.
# Usage: scripts/sign.sh [path/to/WardenApp.app]
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/Build/Products/Debug/WardenApp.app}"
ext="$app/Contents/Library/SystemExtensions/io.github.eugenehil.warden.ext.systemextension"

codesign --force --sign - --entitlements DlpExtension/DlpExtension.entitlements "$ext"
codesign --force --sign - --entitlements WardenApp/WardenApp.entitlements "$app"
codesign -dvv --entitlements - "$ext" 2>&1 | grep -E "Identifier|Signature|endpoint-security|TeamIdentifier"
echo "built: $app"
