#!/usr/bin/env bash
# Build Release with development signing and install via try-it.
# The DNS tunnel is a Network Extension app extension, which macOS only runs
# when signed with a provisioning profile; Xcode creates/refreshes it here.
set -euo pipefail
cd "$(dirname "$0")/.."
team="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Configuration/Local.xcconfig)"
[[ -n "$team" ]] || { echo "Set DEVELOPMENT_TEAM in Configuration/Local.xcconfig" >&2; exit 1; }
mise exec -- xcodegen generate >/dev/null
xcodebuild -quiet -project Bouncer.xcodeproj -scheme Bouncer -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build-dev -allowProvisioningUpdates \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO DEVELOPMENT_TEAM="$team" build
app=build-dev/Build/Products/Release/Bouncer.app
codesign --verify --strict --deep "$app"
codesign -d --entitlements - --xml "$app/Contents/PlugIns/BouncerTunnel.appex" 2>/dev/null | grep -q packet-tunnel-provider \
  || { echo "The tunnel extension is missing its Network Extension entitlement" >&2; exit 1; }
scripts/verify-no-coverage.sh "$app"
exec .agents/skills/try-it/scripts/try-it.sh --app "$app" "$@"
