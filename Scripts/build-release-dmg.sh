#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/LayoutLock.dmg" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$(dirname "$1")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DMG="$(cd "$OUTPUT_DIR" && pwd)/$(basename "$1")"

if mount | grep -F " on /Volumes/LayoutLock (" >/dev/null; then
  echo "A LayoutLock disk image is already mounted. Eject it in Finder, then try again." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/layoutlock-release.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

xcodebuild archive \
  -project "$PROJECT_DIR/LayoutLock.xcodeproj" \
  -scheme LayoutLock \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$WORK_DIR/LayoutLock.xcarchive" \
  -derivedDataPath "$WORK_DIR/DerivedData"

xcodebuild -exportArchive \
  -archivePath "$WORK_DIR/LayoutLock.xcarchive" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions-DeveloperID.plist" \
  -exportPath "$WORK_DIR/export"

"$SCRIPT_DIR/create-dmg.sh" "$WORK_DIR/export/LayoutLock.app" "$OUTPUT_DMG"
