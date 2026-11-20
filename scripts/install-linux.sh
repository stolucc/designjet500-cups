#!/bin/bash
#
# install-linux.sh -- Linux installer for the HP DesignJet 500 CUPS driver.
# Normally run through ../install.sh, which picks the OS.
#
#   ./install.sh            24 inch model (C7769B)
#   ./install.sh --42in     42 inch model (C7770B)
#   ./install.sh --no-queue install files only (then add the printer yourself)
#   ./install.sh --check    prerequisites only, no root needed
#
# What it installs:
#   <cups serverbin>/filter/pdftocdnj500          the CUPS filter
#       (serverbin is /usr/lib/cups on Debian/Ubuntu/Arch, /usr/lib64/cups
#        on Fedora; taken from cups-config when available)
#   /usr/share/cups/model/designjet500/*.ppd      PPDs (show up in lpinfo -m)
#   a print queue "HP_DesignJet_500" bound to the USB printer, if one is found
#
# Ghostscript comes from the distribution; its package includes the contrib
# "cdnj500" device on Debian, Ubuntu, Fedora, Arch and openSUSE.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
PPD_SRC=$HERE/ppd/linux
PPD_DIR=/usr/share/cups/model/designjet500
QUEUE=HP_DesignJet_500
MODEL=24in
ADD_QUEUE=1
CHECK_ONLY=0

for arg in "$@"; do
    case $arg in
        --42in)     MODEL=42in ;;
        --24in)     MODEL=24in ;;
        --no-queue) ADD_QUEUE=0 ;;
        --check)    CHECK_ONLY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

gs_has_device() {
    local help_text
    [ -x "$1" ] || return 1
    help_text=$("$1" -h 2>/dev/null) || return 1
    printf '%s\n' "$help_text" | grep -qw "$2"
}

# --- prerequisites ---------------------------------------------------------
GS=""
for candidate in /usr/bin/gs /usr/local/bin/gs; do
    if gs_has_device "$candidate" cdnj500 && gs_has_device "$candidate" pdfwrite; then
        GS=$candidate
        break
    fi
done
if [ -z "$GS" ]; then
    cat >&2 <<'EOF'
Ghostscript with the "cdnj500" device was not found in /usr/bin or /usr/local/bin.
Install it with your package manager, for example:
  Debian/Ubuntu:  sudo apt install ghostscript cups
  Fedora:         sudo dnf install ghostscript cups
  Arch:           sudo pacman -S ghostscript cups
  openSUSE:       sudo zypper install ghostscript cups
Then check:       gs -h | grep cdnj500
EOF
    exit 1
fi
echo "Ghostscript with cdnj500: $GS"

if ! command -v lpadmin >/dev/null 2>&1; then
    echo "CUPS (lpadmin) is not installed. Install the cups package and start the service." >&2
    exit 1
fi

if command -v cups-config >/dev/null 2>&1; then
    SERVERBIN=$(cups-config --serverbin)
elif [ -d /usr/lib64/cups ]; then
    SERVERBIN=/usr/lib64/cups
else
    SERVERBIN=/usr/lib/cups
fi
FILTER_DIR=$SERVERBIN/filter
[ -d "$FILTER_DIR" ] || { echo "CUPS filter directory $FILTER_DIR not found" >&2; exit 1; }
echo "CUPS filter directory: $FILTER_DIR"

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
install -o root -g root -m 755 "$HERE/filter/pdftocdnj500" "$FILTER_DIR/pdftocdnj500"
install -d -o root -g root -m 755 "$PPD_DIR"
install -o root -g root -m 644 "$PPD_SRC/HP-DesignJet_500-24in.ppd" "$PPD_DIR/"
install -o root -g root -m 644 "$PPD_SRC/HP-DesignJet_500-42in.ppd" "$PPD_DIR/"
echo "installed filter to $FILTER_DIR and PPDs to $PPD_DIR"

if command -v cupstestppd >/dev/null 2>&1; then
    for model in 24in 42in; do
        if ! cupstestppd -q "$PPD_DIR/HP-DesignJet_500-$model.ppd"; then
            echo "warning: cupstestppd reports problems with the $model PPD:" >&2
            cupstestppd "$PPD_DIR/HP-DesignJet_500-$model.ppd" >&2 || true
        fi
    done
fi

[ "$ADD_QUEUE" -eq 1 ] || exit 0

# --- queue -----------------------------------------------------------------
if ! lpstat -r >/dev/null 2>&1; then
    echo "CUPS is not running (try: sudo systemctl enable --now cups). Files are installed; re-run to add the queue." >&2
    exit 1
fi

URI=$(lpinfo -v 2>/dev/null | awk '$1 == "direct" && $2 ~ /^usb:/ && tolower($2) ~ /designjet/ { print $2; exit }')
if [ -z "$URI" ]; then
    cat <<EOF

No USB DesignJet detected right now. Plug it in, switch it on, then re-run
this installer, or add it by hand:
  sudo lpadmin -p $QUEUE -E -P $PPD_DIR/HP-DesignJet_500-$MODEL.ppd -v "\$(lpinfo -v | awk '\$2 ~ /^usb:.*[Dd]esign[Jj]et/ {print \$2; exit}')"
EOF
    exit 0
fi

echo "found printer at $URI"
if lpstat -p "$QUEUE" >/dev/null 2>&1; then
    lpadmin -x "$QUEUE"
fi
lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_DIR/HP-DesignJet_500-$MODEL.ppd" \
    -D "HP DesignJet 500" -o printer-is-shared=false
cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true
echo "queue '$QUEUE' added with the $MODEL PPD"
echo "test print:  lp -d $QUEUE -o PageSize=A4 -o cupsPrintQuality=Draft some-file.pdf"
