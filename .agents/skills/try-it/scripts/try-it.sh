#!/usr/bin/env bash
# Build the macOS app in the current directory and install it to
# /Applications, replacing and relaunching any running copy. Install/launch
# logic follows Reco's publish-release.sh install_and_launch_app.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: try-it.sh [options]

Build the app project in the current directory (Release, ad-hoc signed) and
install it to /Applications, quitting a running instance first.

Options:
  --project PATH         Xcode project (default: sole *.xcodeproj here)
  --scheme NAME          Scheme (default: project name)
  --configuration NAME   Build configuration (default: Release)
  --app PATH             Install this existing .app instead of building
  --skip-launch          Install without launching
  -h, --help             Show this help
EOF
}

fail() {
    echo "try-it: $*" >&2
    exit 1
}

PROJECT=""
SCHEME=""
CONFIGURATION="Release"
APP_PATH=""
LAUNCH=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --scheme) SCHEME="$2"; shift 2 ;;
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --app) APP_PATH="$2"; shift 2 ;;
        --skip-launch) LAUNCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

# nix-darwin exports a C toolchain (LD=ld, CC, SDKROOT, nix DEVELOPER_DIR)
# that breaks xcodebuild link steps; run it in a scrubbed environment.
xcb() {
    env -i \
        HOME="$HOME" \
        USER="$USER" \
        LOGNAME="${LOGNAME:-$USER}" \
        TERM="${TERM:-xterm-256color}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcodebuild "$@"
}

shopt -s nullglob

if [[ -z "$APP_PATH" ]]; then
    projects=( *.xcodeproj )
    if [[ -z "$PROJECT" && -f project.yml && ${#projects[@]} -eq 0 ]]; then
        echo "Generating Xcode project from project.yml..."
        if command -v mise >/dev/null && [[ -f mise.toml ]]; then
            mise exec -- xcodegen generate
        else
            xcodegen generate
        fi
        projects=( *.xcodeproj )
    fi
    if [[ -z "$PROJECT" && ${#projects[@]} -gt 0 ]]; then
        PROJECT="${projects[0]}"
    fi
    [[ -n "$PROJECT" ]] || fail "no .xcodeproj found; run from the project root"
    SCHEME="${SCHEME:-$(basename "$PROJECT" .xcodeproj)}"

    DERIVED="build"
    echo "Building $SCHEME ($CONFIGURATION, ad-hoc signed)..."
    xcb -project "$PROJECT" -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
        build | tail -2

    apps=( "$DERIVED/Build/Products/$CONFIGURATION"/*.app )
    [[ ${#apps[@]} -gt 0 ]] || fail "no .app produced in $DERIVED/Build/Products/$CONFIGURATION"
    APP_PATH="${apps[0]}"
fi

[[ -d "$APP_PATH" ]] || fail "app not found: $APP_PATH"
PRODUCT_NAME="$(basename "$APP_PATH" .app)"
verifier="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)/scripts/verify-no-coverage.sh"
"$verifier" "$APP_PATH"

install_dir="/Applications"
install_path="$install_dir/$PRODUCT_NAME.app"

echo "Installing $PRODUCT_NAME in $install_dir..."

if pgrep -x "$PRODUCT_NAME" >/dev/null; then
    echo "Closing the running $PRODUCT_NAME app..."
    osascript -e "tell application \"$PRODUCT_NAME\" to quit" >/dev/null 2>&1 || true
    for ((attempt = 0; attempt < 50; attempt++)); do
        pgrep -x "$PRODUCT_NAME" >/dev/null || break
        sleep 0.1
    done
    if pgrep -x "$PRODUCT_NAME" >/dev/null; then
        echo "$PRODUCT_NAME did not quit in time; sending SIGTERM..."
        pkill -TERM -x "$PRODUCT_NAME" || true
        for ((attempt = 0; attempt < 50; attempt++)); do
            pgrep -x "$PRODUCT_NAME" >/dev/null || break
            sleep 0.1
        done
    fi
    pgrep -x "$PRODUCT_NAME" >/dev/null && fail "could not stop the running $PRODUCT_NAME app"
fi

staging_dir="$(mktemp -d "$install_dir/.$PRODUCT_NAME-install.XXXXXX")"
staged_app="$staging_dir/$PRODUCT_NAME.app"
ditto "$APP_PATH" "$staged_app"
rm -rf "$install_path"
mv "$staged_app" "$install_path"
rmdir "$staging_dir"

if [[ "$LAUNCH" -eq 1 ]]; then
    open "$install_path"
    for ((attempt = 0; attempt < 50; attempt++)); do
        pgrep -x "$PRODUCT_NAME" >/dev/null && break
        sleep 0.1
    done
    pgrep -x "$PRODUCT_NAME" >/dev/null || fail "$PRODUCT_NAME did not launch"
    echo "Installed and launched $install_path"
else
    echo "Installed $install_path"
fi
