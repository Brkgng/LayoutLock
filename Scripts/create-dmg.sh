#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /path/to/LayoutLock.app /path/to/LayoutLock.dmg" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT_DIR="$(cd "$(dirname "$2")" && pwd)"
OUTPUT_DMG="$OUTPUT_DIR/$(basename "$2")"
APP_NAME="$(basename "$APP")"
VOLUME_NAME="${APP_NAME%.app}"
TEAM_ID="894AUNHU54"
BUNDLE_ID="com.berkergungor.layoutlock"

if [ ! -d "$APP" ]; then
  echo "App not found: $APP" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP"; then
  echo "App signature is invalid: $APP" >&2
  exit 1
fi

DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP" 2>&1)"
if ! grep -Fq "identifier \"$BUNDLE_ID\"" <<< "$DESIGNATED_REQUIREMENT" ||
  ! grep -Fq "certificate leaf[field.1.2.840.113635.100.6.1.13]" <<< "$DESIGNATED_REQUIREMENT" ||
  ! grep -Fq "certificate leaf[subject.OU] = \"$TEAM_ID\"" <<< "$DESIGNATED_REQUIREMENT"; then
  echo "App must have LayoutLock's Developer ID identity before creating a DMG." >&2
  exit 1
fi

APP_ICON="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$APP_ICON" ]; then
  echo "App icon not found: $APP_ICON" >&2
  exit 1
fi

if mount | grep -F " on /Volumes/$VOLUME_NAME (" >/dev/null; then
  echo "A $VOLUME_NAME disk image is already mounted. Eject it in Finder, then try again." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/layoutlock-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
READ_WRITE_DMG="$WORK_DIR/LayoutLock-read-write.dmg"
IS_MOUNTED=false

cleanup() {
  if [ "$IS_MOUNTED" = true ]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR/.background"
ditto "$APP" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$SCRIPT_DIR/DMG/background.png" "$STAGING_DIR/.background/background.png"
cp "$APP_ICON" "$STAGING_DIR/.VolumeIcon.icns"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$READ_WRITE_DMG" >/dev/null

hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  "$READ_WRITE_DMG" >/dev/null
IS_MOUNTED=true

if ! osascript "$SCRIPT_DIR/DMG/configure-finder.applescript" "$VOLUME_NAME" "$APP_NAME"; then
  echo "Unable to configure the DMG window. Review the Finder error above, then try again." >&2
  exit 1
fi
# Finder removes the staged volume icon while saving the window layout.
cp "$APP_ICON" "$MOUNT_POINT/.VolumeIcon.icns"
SetFile -a C "$MOUNT_POINT"
sync

hdiutil detach "$MOUNT_POINT" >/dev/null
IS_MOUNTED=false

hdiutil convert \
  "$READ_WRITE_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG" >/dev/null

SIGNING_IDENTITIES="$(security find-identity -v -p codesigning)"
SIGNING_IDENTITY="$(awk -v team_id="$TEAM_ID" '
  /Developer ID Application:/ && index($0, "(" team_id ")") { print $2; exit }
' <<< "$SIGNING_IDENTITIES")"
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "No valid Developer ID Application identity found for team $TEAM_ID." >&2
  exit 1
fi

codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --timestamp \
  "$OUTPUT_DMG"

echo "Created $OUTPUT_DMG"
