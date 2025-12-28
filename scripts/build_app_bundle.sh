#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="grabthis"
BUNDLE_NAME="GrabThisApp.app"
BUNDLE_ID="com.grabthis.app"

echo "Building SwiftPM executable…"
swift build -c debug

BIN_PATH="$(swift build -c debug --show-bin-path)"
EXEC_PATH="$BIN_PATH/GrabThisApp"

if [[ ! -f "$EXEC_PATH" ]]; then
  echo "Expected executable not found at: $EXEC_PATH" >&2
  exit 1
fi

OUT_DIR="$ROOT_DIR/build"
APP_DIR="$OUT_DIR/$BUNDLE_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"

echo "Packaging .app bundle…"
# IMPORTANT: Do NOT delete/recreate the .app on every build.
# Recreating the bundle can cause macOS privacy permissions (TCC) to stop matching,
# forcing the user to re-enable permissions each launch.
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$EXEC_PATH" "$MACOS_DIR/GrabThisApp"
chmod +x "$MACOS_DIR/GrabThisApp"

cp "$ROOT_DIR/Support/GrabThisApp-Info.plist" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Compile asset catalog (app icon)
ASSETS_DIR="$ROOT_DIR/Sources/GrabThisApp/Assets.xcassets"
if [[ -d "$ASSETS_DIR" ]]; then
  echo "Compiling asset catalog…"
  xcrun actool "$ASSETS_DIR" \
    --compile "$RES_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "/tmp/grabthis-AssetCatalog-Info.plist" \
    2>/dev/null || echo "Warning: actool failed, icon may not appear"
fi
# Clean up any stray plist from earlier builds
rm -f "$CONTENTS_DIR/AssetCatalog-Info.plist"

echo "Ad-hoc codesigning (required for some macOS privacy prompts)…"
# IMPORTANT:
# TCC permissions are tied to the app's designated requirement (bundle id + signing identity).
# If the app is unsigned or re-signed with varying identities across rebuilds, macOS will
# behave like permissions “reset”. We *require* a stable identity here for a good dev loop.
#
# Recommended:
#   export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
#
SIGN_ID="${GRABTHIS_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  # Try to find a stable codesign identity automatically.
  # Prefer Apple Development (local dev), fall back to Developer ID Application if present.
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\"\\(Apple Development:.*\\)\".*/\\1/p' | head -n 1 || true)"
  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\"\\(Developer ID Application:.*\\)\".*/\\1/p' | head -n 1 || true)"
  fi
fi

if [[ -z "$SIGN_ID" ]]; then
  cat >&2 <<'EOF'
ERROR: No stable codesigning identity found.

To keep macOS permissions (TCC) stable across rebuilds, the app must be consistently signed.

Fix:
  1) Create/install an "Apple Development" certificate in Keychain (Xcode → Settings → Accounts).
  2) Re-run this script, or set:
       export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
EOF
  exit 2
fi

echo "Codesigning with identity: $SIGN_ID"
# Sign the Mach-O first, then the bundle. Avoid ad-hoc and avoid silently swallowing failures.
codesign --force --sign "$SIGN_ID" --timestamp=none "$MACOS_DIR/GrabThisApp"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP_DIR"

echo "Done:"
echo "  $APP_DIR"
echo "Run:"
echo "  open \"$APP_DIR\""


