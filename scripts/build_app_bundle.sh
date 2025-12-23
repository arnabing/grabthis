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

echo "Ad-hoc codesigning (required for some macOS privacy prompts)…"
# IMPORTANT:
# Re-signing with ad-hoc identity (-) on every build can cause macOS privacy permissions (TCC)
# to behave like they're "resetting" after rebuilds because the code identity changes.
#
# If you want permissions to persist across frequent rebuilds, set a stable identity:
#   export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"   (recommended)
# or another consistent identity in your keychain.
#
# If not set, we skip signing to avoid changing the identity every time.
if [[ -n "${GRABTHIS_CODESIGN_IDENTITY:-}" ]]; then
  echo "Codesigning with identity: $GRABTHIS_CODESIGN_IDENTITY"
  codesign --force --sign "$GRABTHIS_CODESIGN_IDENTITY" --timestamp=none "$APP_DIR" >/dev/null 2>&1 || true
else
  # Try to find a stable codesign identity automatically.
  # Prefer Apple Development (local dev), fall back to Developer ID Application if present.
  AUTO_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\"\\(Apple Development:.*\\)\".*/\\1/p' | head -n 1 || true)"
  if [[ -z "$AUTO_ID" ]]; then
    AUTO_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\"\\(Developer ID Application:.*\\)\".*/\\1/p' | head -n 1 || true)"
  fi
  if [[ -n "$AUTO_ID" ]]; then
    echo "Auto-selected codesign identity: $AUTO_ID"
    codesign --force --sign "$AUTO_ID" --timestamp=none "$APP_DIR" >/dev/null 2>&1 || true
  else
    echo "Skipping codesign (no Apple Development identity found). Set GRABTHIS_CODESIGN_IDENTITY if you want stable TCC permissions."
  fi
fi

echo "Done:"
echo "  $APP_DIR"
echo "Run:"
echo "  open \"$APP_DIR\""


