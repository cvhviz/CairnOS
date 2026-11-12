#!/bin/sh
# Adds MapLibre's dSYM to an archive, so App Store Connect can symbolicate crashes inside the map
# and stops warning "The archive did not include a dSYM for the MapLibre.framework".
#
# MapLibre's Swift package ships its framework without a dSYM; the matching one is published
# beside each release on GitHub. Run as the Cairn scheme's archive post-action (project.yml),
# with ARCHIVE_PATH and SRCROOT set. The download is cached per version, and the dSYM is only
# copied when its UUID matches the framework actually in the archive.
#
# Usage: ARCHIVE_PATH=… SRCROOT=… ci/add-maplibre-dsym.sh
set -eu

log() { echo "add-maplibre-dsym: $*" >&2; }

: "${ARCHIVE_PATH:?ARCHIVE_PATH is not set}"
: "${SRCROOT:?SRCROOT is not set}"

# The pinned MapLibre version: the exactVersion under the MapLibre package in project.yml.
VERSION=$(awk '/^  MapLibre:/ { found = 1 } found && /exactVersion:/ { print $2; exit }' "$SRCROOT/project.yml")
if [ -z "$VERSION" ]; then
  log "couldn't read the MapLibre version from project.yml; skipping"
  exit 0
fi

FRAMEWORK=$(find "$ARCHIVE_PATH/Products" -path '*/Frameworks/MapLibre.framework/MapLibre' -type f | head -1)
if [ -z "$FRAMEWORK" ]; then
  log "no MapLibre.framework in the archive; skipping"
  exit 0
fi

CACHE="${HOME}/Library/Caches/Cairn/maplibre-dsym/${VERSION}"
DSYM="$CACHE/MapLibre_ios_device.framework.dSYM"
if [ ! -d "$DSYM" ]; then
  mkdir -p "$CACHE"
  URL="https://github.com/maplibre/maplibre-native/releases/download/ios-v${VERSION}/MapLibre_ios_device.framework.dSYM.zip"
  log "downloading $URL"
  if ! curl -fsSL "$URL" -o "$CACHE/dsym.zip"; then
    log "download failed; the archive keeps no MapLibre dSYM"
    exit 0
  fi
  unzip -q -o "$CACHE/dsym.zip" -d "$CACHE"
  rm -f "$CACHE/dsym.zip"
fi

uuids() { xcrun dwarfdump --uuid "$1" | awk '{ print $2 }' | sort; }
DWARF=$(find "$DSYM/Contents/Resources/DWARF" -type f | head -1)
if [ "$(uuids "$FRAMEWORK")" != "$(uuids "$DWARF")" ]; then
  log "the ${VERSION} dSYM doesn't match the archived framework's UUID; skipping"
  exit 0
fi

# Named as the framework it describes, as Xcode names its own.
DEST="$ARCHIVE_PATH/dSYMs/MapLibre.framework.dSYM"
rm -rf "$DEST"
mkdir -p "$ARCHIVE_PATH/dSYMs"
cp -R "$DSYM" "$DEST"
mv "$DEST/Contents/Resources/DWARF/$(basename "$DWARF")" "$DEST/Contents/Resources/DWARF/MapLibre"
log "added MapLibre ${VERSION} dSYM ($(uuids "$FRAMEWORK" | tr '\n' ' '))"
