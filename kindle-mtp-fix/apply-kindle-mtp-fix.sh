#!/bin/sh
# Applies the "MTP + KOReader at the same time" fix on a jailbroken MTP Kindle (run as root on the Kindle).
# Safe to re-run, e.g. after a kpm reinstall of KOReader overwrites documents/KOReader.sh.
#   1. Installs the KOReader user patch that resumes volumd (survives KOReader OTA updates).
#   2. Makes the library launcher start KOReader in a private mount namespace where /mnt/us bypasses fsp.

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER=/mnt/us/documents/KOReader.sh
PATCH_DIR=/mnt/us/koreader/patches
MARKER="# kindle-mtp-coexist"
LAUNCH_CMD="/var/local/kmc/bin/kpm launch koreader --asap"

mkdir -p "$PATCH_DIR"
cp "$HERE/1-kindle-mtp-coexist.lua" "$PATCH_DIR/"
echo "Installed $PATCH_DIR/1-kindle-mtp-coexist.lua"

if grep -q "$MARKER" "$LAUNCHER"; then
    echo "$LAUNCHER already patched"
    exit 0
fi
if [ "$(tail -n 1 "$LAUNCHER")" != "$LAUNCH_CMD" ]; then
    echo "Unexpected last line in $LAUNCHER, not touching it" >&2
    exit 1
fi

cp "$LAUNCHER" /mnt/us/koreader/KOReader.sh.pre-mtp-fix
# Keep the scriptlet header (name/icon) intact and only replace the final launch command.
sed -i '$d' "$LAUNCHER"
cat >> "$LAUNCHER" <<EOF
$MARKER
# Start KOReader in a private mount namespace where /mnt/us is the userstore itself (/mnt/base-us) rather than
# the fsp FUSE proxy, which locks every on-device process out while a computer has MTP open.
# koreader/patches/1-kindle-mtp-coexist.lua then lets volumd run, so MTP and KOReader work at the same time.
if grep -q ' /mnt/us fuse.fsp ' /proc/mounts && [ -d /mnt/base-us/koreader ] && unshare -m true 2>/dev/null; then
    exec unshare -m sh -c 'mount --make-rprivate / ; mount --bind /mnt/base-us /mnt/us ; exec $LAUNCH_CMD'
fi
$LAUNCH_CMD
EOF
echo "Patched $LAUNCHER (backup: /mnt/us/koreader/KOReader.sh.pre-mtp-fix)"
