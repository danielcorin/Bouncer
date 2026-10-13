#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --quick ]]; then
    exec python3 scripts/generated-files.py --quick
fi
exec scripts/generate-api.sh --check
