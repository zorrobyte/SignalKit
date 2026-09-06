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
# Consumers may adopt the Swift 6 language mode. Prove the package and its tests
# compile there with complete concurrency checking and no warnings.
xcodebuild -scheme SignalKit-Package -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$result_root/DerivedData-swift6" build-for-testing CODE_SIGNING_ALLOWED=NO \
  SWIFT_VERSION=6 SWIFT_STRICT_CONCURRENCY=complete OTHER_SWIFT_FLAGS='-warnings-as-errors'
