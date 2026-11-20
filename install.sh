#!/bin/bash
#
# install.sh -- installs the HP DesignJet 500 CUPS driver on macOS or Linux.
#
#   ./install.sh            24 inch model (C7769B)
#   ./install.sh --42in     42 inch model (C7770B)
#   ./install.sh --no-queue install driver files only, add the printer yourself
#   ./install.sh --check    only check prerequisites, no root needed
#
# Detects the OS and hands over to scripts/install-macos.sh or
# scripts/install-linux.sh. Asks for sudo when it needs it.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

case $(uname -s) in
    Darwin) exec "$HERE/scripts/install-macos.sh" "$@" ;;
    Linux)  exec "$HERE/scripts/install-linux.sh" "$@" ;;
    *)      echo "unsupported OS: $(uname -s). This driver targets macOS and Linux (CUPS)." >&2; exit 1 ;;
esac
