#!/bin/bash
#
# bump-version.sh - Increment app version numbers
#
# Usage:
#   ./scripts/bump-version.sh patch   # 0.2.0 -> 0.2.1 (bug fixes)
#   ./scripts/bump-version.sh minor   # 0.2.0 -> 0.3.0 (new features)
#   ./scripts/bump-version.sh major   # 0.2.0 -> 1.0.0 (breaking changes)
#   ./scripts/bump-version.sh build   # Just increment build number
#   ./scripts/bump-version.sh set 1.0.0  # Set specific version
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLIST="$PROJECT_DIR/Support/GrabThisApp-Info.plist"

# Get current version
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")

echo "Current: v$CURRENT_VERSION (build $CURRENT_BUILD)"

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
PATCH=${PATCH:-0}  # Default to 0 if not present

bump_type="${1:-build}"

case "$bump_type" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    build)
        # Just increment build, keep version same
        ;;
    set)
        if [ -z "$2" ]; then
            echo "Error: 'set' requires a version number (e.g., ./bump-version.sh set 1.0.0)"
            exit 1
        fi
        IFS='.' read -r MAJOR MINOR PATCH <<< "$2"
        PATCH=${PATCH:-0}
        ;;
    *)
        echo "Usage: $0 [major|minor|patch|build|set <version>]"
        echo ""
        echo "Examples:"
        echo "  $0 patch     # Bug fixes: 0.2.0 -> 0.2.1"
        echo "  $0 minor     # New features: 0.2.0 -> 0.3.0"
        echo "  $0 major     # Breaking changes: 0.2.0 -> 1.0.0"
        echo "  $0 build     # Just increment build number"
        echo "  $0 set 1.0.0 # Set specific version"
        exit 1
        ;;
esac

# Construct new version
NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_BUILD=$((CURRENT_BUILD + 1))

# Update plist
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEW_BUILD" "$PLIST"

echo "Updated: v$NEW_VERSION (build $NEW_BUILD)"

# Show what changed
if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
    echo ""
    echo "Version: $CURRENT_VERSION -> $NEW_VERSION"
fi
echo "Build:   $CURRENT_BUILD -> $NEW_BUILD"

# Remind about git tag
echo ""
echo "Don't forget to commit and tag:"
echo "  git add Support/GrabThisApp-Info.plist"
echo "  git commit -m \"Bump version to $NEW_VERSION (build $NEW_BUILD)\""
echo "  git tag v$NEW_VERSION"
