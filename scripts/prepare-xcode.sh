#!/usr/bin/env bash
# Xcode ignores a dependency package's Package.resolved. Seed its disposable workspace
# from the app's committed lock after every XcodeGen regeneration.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && -d "$1" && "$1" == *.xcodeproj ]] || { echo 'usage: prepare-xcode.sh App.xcodeproj' >&2; exit 2; }
python3 scripts/check-dependencies.py
lock_dir="$1/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$lock_dir"
cp Configuration/Package.resolved "$lock_dir/Package.resolved"
