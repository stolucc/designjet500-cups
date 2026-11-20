#!/bin/bash
#
# uninstall-linux.sh -- removes the DesignJet 500 driver from Linux
# (queue, PPDs, filter).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

QUEUE=HP_DesignJet_500
PPD_DIR=/usr/share/cups/model/designjet500

if command -v cups-config >/dev/null 2>&1; then
    SERVERBIN=$(cups-config --serverbin)
elif [ -d /usr/lib64/cups ]; then
    SERVERBIN=/usr/lib64/cups
else
    SERVERBIN=/usr/lib/cups
fi

if lpstat -p "$QUEUE" >/dev/null 2>&1; then
    lpadmin -x "$QUEUE"
    echo "removed queue $QUEUE"
fi
rm -f "$SERVERBIN/filter/pdftocdnj500"
rm -rf "$PPD_DIR"
echo "removed $SERVERBIN/filter/pdftocdnj500 and $PPD_DIR"
