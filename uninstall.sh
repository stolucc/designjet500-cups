#!/bin/bash
#
# uninstall.sh -- removes the HP DesignJet 500 CUPS driver (queue, PPDs,
# filter, bundled Ghostscript on macOS). Asks for sudo when it needs it.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

case $(uname -s) in
    Darwin) exec "$HERE/scripts/uninstall-macos.sh" "$@" ;;
    Linux)  exec "$HERE/scripts/uninstall-linux.sh" "$@" ;;
    *)      echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
