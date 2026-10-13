#!/usr/bin/env bash
# One pinned package graph builds both generators. Generated output is committed.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---write}"
[[ "$mode" == --write || "$mode" == --check ]] || { echo "usage: $0 [--write|--check]" >&2; exit 2; }
package="$PWD/Packages/AppAutomation"
swift build --package-path "$package" --product app-interface >&2
swift build --package-path "$package" --product swift-openapi-generator >&2
binary_dir="$(swift build --package-path "$package" --show-bin-path)"
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
module="$(python3 -c 'import json; print(json.load(open("API/generation.json"))["coreModule"])')"
http="$(python3 -c 'import json; print("1" if json.load(open("API/generation.json")).get("http") else "")')"
"$binary_dir/swift-openapi-generator" generate API/openapi.yaml --mode types --access-modifier public --output-directory "$output/Sources/Shared/API/Generated" >&2
if [[ -n "$http" ]]; then
    "$binary_dir/swift-openapi-generator" generate API/openapi.yaml --mode server --access-modifier public --additional-import "$module" --output-directory "$output/Sources/HTTP/Generated" >&2
fi
"$binary_dir/app-interface" API/openapi.yaml "$output" "$module" ${http:+--http} >&2
python3 scripts/generated-files.py "$mode" "$output"
