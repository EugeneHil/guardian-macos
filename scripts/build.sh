#!/usr/bin/env bash
# Generate the project, build unsigned (Xcode cannot sign ES entitlements ad hoc), then ad-hoc sign.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
source scripts/common.sh

mkdir -p build
run_tuist generate --no-open
xcodebuild -workspace Warden.xcworkspace -scheme WardenApp -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build >build/build.log 2>&1 \
  || { grep -E "error:" build/build.log | head -20 || true; tail -n 40 build/build.log; exit 1; }
scripts/sign.sh build/Build/Products/Debug/WardenApp.app
