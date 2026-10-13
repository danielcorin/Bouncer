#!/usr/bin/env bash
# Build Release signed with the Developer ID identity and install via try-it.
# With a Team ID on both binaries, the root helper only accepts connections
# from a Bouncer app signed by the same team (see PeerVerifier).
set -euo pipefail
cd "$(dirname "$0")/.."
team="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Configuration/Local.xcconfig)"
[[ -n "$team" ]] || { echo "Set DEVELOPMENT_TEAM in Configuration/Local.xcconfig" >&2; exit 1; }
mise exec -- xcodegen generate >/dev/null
xcodebuild -quiet -project Bouncer.xcodeproj -scheme Bouncer -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build-signed \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$team" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" build
app=build-signed/Build/Products/Release/Bouncer.app
codesign --force --options runtime --timestamp=none --sign "Developer ID Application" "$app/Contents/Helpers/bouncer"
codesign --force --options runtime --timestamp=none --identifier llc.wvlen.Bouncer.helper \
  --sign "Developer ID Application" "$app/Contents/Helpers/BouncerHelper"
codesign --force --options runtime --timestamp=none --entitlements App.entitlements --sign "Developer ID Application" "$app"
codesign --verify --strict "$app"
scripts/verify-no-coverage.sh "$app"
exec .agents/skills/try-it/scripts/try-it.sh --app "$app" "$@"
