#!/usr/bin/env bash
# Run unit tests for both test schemes. Usage: scripts/test.sh [--coverage]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
source scripts/common.sh

coverage=NO
[[ "${1:-}" == "--coverage" ]] && coverage=YES

mkdir -p build
run_tuist generate --no-open
for scheme in CoreBridgeTests DlpExtensionTests WardenAppTests; do
  rm -rf "build/$scheme.xcresult"
  xcodebuild test -workspace Warden.xcworkspace -scheme "$scheme" -destination 'platform=macOS' \
    -derivedDataPath build -enableCodeCoverage "$coverage" -resultBundlePath "build/$scheme.xcresult" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" >"build/$scheme.log" 2>&1 \
    || { grep -E "error:|\*\* TEST FAILED" "build/$scheme.log" | head -20 || true; tail -n 40 "build/$scheme.log"; exit 1; }
  grep -E "\*\* TEST SUCCEEDED \*\*" "build/$scheme.log" | sed "s/^/$scheme: /"
done
