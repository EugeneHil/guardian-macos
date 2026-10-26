#!/usr/bin/env bash
# Run the tests with coverage and gate the Swift logic at >= 80 % lines (see coverage_gate.py excludes).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/test.sh --coverage
reports=()
for scheme in DlpExtensionTests GuardianAppTests; do
  json="build/$scheme.coverage.json"
  xcrun xccov view --report --json "build/$scheme.xcresult" >"$json"
  reports+=("$json")
done
python3 -I -B scripts/coverage_gate.py --min 80 "${reports[@]}"
