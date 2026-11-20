#!/bin/bash
#
# uninstall-macos.sh -- removes the DesignJet 500 driver from macOS
# (queue, PPDs, filter, bundled Ghostscript).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

QUEUE=HP_DesignJet_500
DEST=/Library/Printers/cdnj500
PPD_DIR=/Library/Printers/PPDs/Contents/Resources

if lpstat -p "$QUEUE" >/dev/null 2>&1; then
    lpadmin -x "$QUEUE"
    echo "removed queue $QUEUE"
fi
rm -f "$PPD_DIR/HP-DesignJet_500-24in.ppd" "$PPD_DIR/HP-DesignJet_500-42in.ppd"
rm -rf "$DEST"
echo "removed $DEST and the PPDs"
