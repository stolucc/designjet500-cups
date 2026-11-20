#!/bin/bash
#
# install-macos.sh -- macOS installer for the HP DesignJet 500 CUPS driver.
# Normally run through ../install.sh, which picks the OS.
#
#   ./install.sh            24 inch model (C7769B)
#   ./install.sh --42in     42 inch model (C7770B)
#   ./install.sh --no-queue install files only (then use Printers & Scanners)
#   ./install.sh --check    prerequisites only, no root needed
#
# What it installs:
#   /Library/Printers/cdnj500/bin/gs                       bundled static Ghostscript
#   /Library/Printers/cdnj500/filter/pdftocdnj500          the CUPS filter
#   /Library/Printers/PPDs/Contents/Resources/HP-DesignJet_500-{24in,42in}.ppd
#   a print queue "HP_DesignJet_500" bound to the USB printer, if one is found
#
# Ghostscript must live under /Library/Printers: cupsd runs filters in a
# sandbox that cannot read /opt/local, /opt/homebrew or /usr/local. If
# vendor/gs/bin/gs is missing, this script builds it first (build-gs.sh,
# needs the Xcode command line tools, takes a couple of minutes).

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST=/Library/Printers/cdnj500
PPD_DIR=/Library/Printers/PPDs/Contents/Resources
PPD_SRC=$HERE/ppd/macos
QUEUE=HP_DesignJet_500
MODEL=24in
ADD_QUEUE=1
CHECK_ONLY=0
BUNDLED_GS=$HERE/vendor/gs/bin/gs

for arg in "$@"; do
    case $arg in
        --42in)     MODEL=42in ;;
        --24in)     MODEL=24in ;;
        --no-queue) ADD_QUEUE=0 ;;
        --check)    CHECK_ONLY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Capture "gs -h" fully before grepping: with pipefail, "gs -h | grep -q"
# fails whenever grep exits before gs has finished writing (SIGPIPE, 141).
gs_has_cdnj500() {
    local help_text
    [ -x "$1" ] || return 1
    help_text=$("$1" -h 2>/dev/null) || return 1
    printf '%s\n' "$help_text" | grep -qw cdnj500
}

# --- bundled Ghostscript ---------------------------------------------------
if ! gs_has_cdnj500 "$BUNDLED_GS"; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "bundled Ghostscript not built yet; install.sh will build it (./build-gs.sh)"
        exit 0
    fi
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "Xcode command line tools are needed to build Ghostscript: run  xcode-select --install  and retry." >&2
        exit 1
    fi
    echo "bundled Ghostscript not found, building it now (one-off, a few minutes) ..."
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$HERE/build-gs.sh"
    else
        "$HERE/build-gs.sh"
    fi
    gs_has_cdnj500 "$BUNDLED_GS" || { echo "build did not produce a usable $BUNDLED_GS" >&2; exit 1; }
fi
if otool -L "$BUNDLED_GS" | grep -Eq '^\s*/(opt|usr/local)/'; then
    echo "bundled Ghostscript links against /opt or /usr/local libraries; the CUPS sandbox would block it. Rebuild with ./build-gs.sh" >&2
    exit 1
fi
echo "Ghostscript with cdnj500: $BUNDLED_GS"

for f in "$HERE/filter/pdftocdnj500" "$PPD_SRC/HP-DesignJet_500-24in.ppd" "$PPD_SRC/HP-DesignJet_500-42in.ppd"; do
    [ -r "$f" ] || { echo "missing $f (run ppd/make-ppd.sh?)" >&2; exit 1; }
done

if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "re-running with sudo ..."
    exec sudo "$0" "$@"
fi

# --- files -----------------------------------------------------------------
# cupsd refuses filters that are not root-owned or are group/world writable.
install -d -o root -g wheel -m 755 "$DEST" "$DEST/filter" "$DEST/bin"
install    -o root -g wheel -m 755 "$BUNDLED_GS" "$DEST/bin/gs"
install    -o root -g wheel -m 755 "$HERE/filter/pdftocdnj500" "$DEST/filter/pdftocdnj500"
install -d -o root -g wheel -m 755 "$PPD_DIR"
install    -o root -g wheel -m 644 "$PPD_SRC/HP-DesignJet_500-24in.ppd" "$PPD_DIR/"
install    -o root -g wheel -m 644 "$PPD_SRC/HP-DesignJet_500-42in.ppd" "$PPD_DIR/"
echo "installed gs to $DEST/bin, filter to $DEST/filter and PPDs to $PPD_DIR"

if ! gs_has_cdnj500 "$DEST/bin/gs"; then
    echo "installed $DEST/bin/gs does not run; aborting" >&2
    exit 1
fi

for model in 24in 42in; do
    if ! cupstestppd -q "$PPD_DIR/HP-DesignJet_500-$model.ppd"; then
        echo "warning: cupstestppd reports problems with the $model PPD:" >&2
        cupstestppd "$PPD_DIR/HP-DesignJet_500-$model.ppd" >&2 || true
    fi
done

[ "$ADD_QUEUE" -eq 1 ] || exit 0

# --- queue -----------------------------------------------------------------
probe_uri() {
    lpinfo -v 2>/dev/null | awk '$1 == "direct" && $2 ~ /^usb:/ && tolower($2) ~ /designjet/ { print $2; exit }'
}

# The DesignJet 500 reports "DesignJet 500" as its USB product string and
# "DesignJet 500 (C77xxB)" in its IEEE-1284 device ID. Apple's USB backend
# matches a queue by make+model from the device ID, so the queue must be
# bound to the device-ID form or it stays "offline". Re-probe if the plain
# form shows up (it does while the printer is busy or just powered on).
URI=$(probe_uri)
attempt=0
while [ -n "$URI" ] && [[ $URI != *%28C77* && $URI != *\(C77* ]] && [ "$attempt" -lt 4 ]; do
    attempt=$((attempt + 1))
    echo "printer reported '$URI' (no model code); re-probing ($attempt/4) ..."
    sleep 3
    URI=$(probe_uri)
done
if [ -n "$URI" ] && [[ $URI != *%28C77* && $URI != *\(C77* ]]; then
    echo "warning: printer still reports the short URI; if the queue shows 'offline' later, re-run install.sh with the printer idle" >&2
fi
if [ -z "$URI" ]; then
    cat <<EOF

No USB DesignJet detected right now. Plug it in, switch it on, then either
re-run this installer, or add it in System Settings > Printers & Scanners,
choose "Select Software..." and pick "HP DesignJet 500 $MODEL".
EOF
    exit 0
fi

echo "found printer at $URI"
# Re-create rather than modify: a stale "offline-report" state reason from an
# earlier failed connection survives lpadmin -p changes (Apple's USB backend
# only clears it in the same process that set it) and keeps the printer
# marked "Offline" in the GUI. Deleting the queue resets it.
if lpstat -p "$QUEUE" >/dev/null 2>&1; then
    lpadmin -x "$QUEUE"
fi
lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_DIR/HP-DesignJet_500-$MODEL.ppd" \
    -D "HP DesignJet 500" -o printer-is-shared=false
cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true
echo "queue '$QUEUE' added with the $MODEL PPD"
echo "test print:  lp -d $QUEUE -o PageSize=A4 -o cupsPrintQuality=Draft some-file.pdf"
