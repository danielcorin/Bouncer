#!/usr/bin/env bash
# The single deterministic merge gate. Any command failure fails the check.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$(python3 -c 'import json; print(json.load(open("API/generation.json"))["coreModule"].removesuffix("Core"))')"
project="$app.xcodeproj"
scripts/check-generated.sh
python3 scripts/check-dependencies.py
python3 scripts/check-ui-boundary.py
python3 scripts/test-verification.py
python3 scripts/test-generator.py
swift test --package-path Packages/AppAutomation
mise exec -- xcodegen generate
xcodebuild -quiet -project "$project" -scheme "$app" \
  -destination 'platform=macOS' -derivedDataPath build \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build test
python3 scripts/test-compiler-boundary.py
xcodebuild -quiet -project "$project" -scheme "${app}AutomationFixture" \
  -destination 'platform=macOS' -derivedDataPath build \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
python3 scripts/test-automation.py
python3 scripts/test-scenarios.py
if [[ -d Sources/Mobile ]]; then
  xcodebuild -quiet -project "$project" -scheme "${app}Mobile" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios \
    -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
fi
scripts/verify-no-coverage.sh "build/Build/Products/Debug/$app.app"
echo "PASS: generated sources, UI boundaries, operation coverage, transport scenarios, and platform builds."
