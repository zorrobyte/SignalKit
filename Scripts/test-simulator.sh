#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
result_root=${RESULT_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/SignalKit-checks.XXXXXX")}
mkdir -p "$result_root"
simulator_id=${SIMULATOR_ID:-$(xcrun simctl list devices available -j | jq -r '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.name | startswith("iPhone"))][0].udid')}
test "$simulator_id" != null
xcodebuild -version
echo "Results: $result_root"
node Scripts/audit-public.mjs
xcodebuild -scheme SignalKit-Package -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$result_root/DerivedData" -resultBundlePath "$result_root/TestResults.xcresult" \
  -enableCodeCoverage YES test CODE_SIGNING_ALLOWED=NO
xcrun xccov view --report --json "$result_root/TestResults.xcresult" > "$result_root/coverage.json"
node Scripts/check-coverage.mjs "$result_root/coverage.json"
xcodebuild -scheme SignalKit-Package -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$result_root/DerivedData" build CODE_SIGNING_ALLOWED=NO
