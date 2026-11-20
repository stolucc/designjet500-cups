# HP DesignJet 500 driver for macOS and Linux

Print to an HP DesignJet 500 (24 in C7769B or 42 in C7770B) over USB from a
current Mac or Linux box. HP's last Mac driver predates Apple silicon, Apple's
legacy HP bundle stops at macOS 12, and Gutenprint dropped macOS in 2024.
This is a small CUPS driver that fills that gap.

Verified on a DesignJet 500 42 in (C7770B) from an M4 MacBook on macOS
Sequoia 15.7.4. The Linux path uses the same filter and PPD with the
distribution's Ghostscript; it is written to the CUPS spec but has not yet been
run on real Linux hardware by the author. Reports welcome.

## Quick start

```sh
git clone https://github.com/stolucc/designjet500-cups.git
cd designjet500-cups
./install.sh          # 24 inch model
./install.sh --42in   # 42 inch model
```

That's it. The script detects your OS, asks for `sudo` when it needs it,
installs the driver, finds the printer on USB and creates a queue named
`HP_DesignJet_500`. Then print from any application, or:

```sh
lp -d HP_DesignJet_500 -o PageSize=A1 -o cupsPrintQuality=Normal drawing.pdf
```

If the printer wasn't plugged in during install, run `./install.sh` again
once it is, or add it through your system's printer settings and pick
"HP DesignJet 500 24in" / "42in" as the driver.

## Requirements

**macOS** (13 Ventura or later, Apple silicon or Intel)

- Xcode command line tools: `xcode-select --install`. The installer builds a
  small self-contained Ghostscript once (about two minutes). See
  [Why Ghostscript is bundled on macOS](#why-ghostscript-is-bundled-on-macos).

**Linux** (any distribution with CUPS)

- `cups` and `ghostscript` packages. The distro Ghostscript already contains
  the `cdnj500` device on Debian, Ubuntu, Fedora, Arch and openSUSE. Check
  with `gs -h | grep cdnj500`.

**Both**

- The DesignJet 500 connected by USB and switched on. No HP-GL/2 accessory
  card is needed; the driver speaks the printer's built-in PCL3GUI language.

## Options

Available in the print dialog (under "Printer Options" / "Printer Features"
on macOS, the driver tab on Linux) and on the `lp` command line:

| Option | Values | Effect |
| --- | --- | --- |
| Media Size (`PageSize`) | A4 … A1 (A0 on 42 in), Letter, Legal, Tabloid, ANSI C–E, ARCH A–E, `Custom.WxH{mm,cm,in,pt}` | raster size sent to the printer |
| Print Quality (`cupsPrintQuality`) | `Draft`, `Normal`, `High` | 300 dpi; 600 dpi; 600 dpi with resolution enhancement off |
| Color Mode (`ColorModel`) | `RGB`, `Gray` | Gray converts the page to neutral pixels and sets PJL `RENDERMODE=GRAYSCALE` |

Custom sizes go up to the roll width (24 or 42 in) and 150 in long. Copies and
page ranges are handled by CUPS. A landscape page is sent as its portrait
raster, so paper use is governed by the short side.

## How it works

The DesignJet 500's native language is HP PCL3GUI raster. Ghostscript ships a
device for exactly this printer, `cdnj500` (in `contrib/gdevcd8.c`, derived
from HP's Windows NT driver). This package wraps that device in what CUPS needs:

| Part | Role |
| --- | --- |
| `filter/pdftocdnj500` | CUPS filter: PDF in (`application/vnd.cups-pdf`), PCL3GUI out |
| `ppd/macos/*.ppd`, `ppd/linux/*.ppd` | PPDs for the 24 in and 42 in models; identical except for how they name the filter |
| `ppd/make-ppd.sh` | generates the PPDs; edit this, not the PPDs |
| `build-gs.sh` | macOS only: builds the bundled static Ghostscript |
| `scripts/install-*.sh`, `scripts/uninstall-*.sh` | per-OS installers, driven by `install.sh` / `uninstall.sh` |
| `tests/run-tests.sh` | end-to-end tests through `cupsfilter`, no printer needed |

Pipeline: application → PDF → CUPS PDF stage (`cgpdftopdf` on macOS,
`pdftopdf` on Linux) → `pdftocdnj500` → Ghostscript `cdnj500` → `usb://`
backend → printer.

Installed locations:

| | macOS | Linux |
| --- | --- | --- |
| filter | `/Library/Printers/cdnj500/filter/pdftocdnj500` | `<cups serverbin>/filter/pdftocdnj500` (`/usr/lib/cups` or `/usr/lib64/cups`) |
| PPDs | `/Library/Printers/PPDs/Contents/Resources/` | `/usr/share/cups/model/designjet500/` |
| Ghostscript | `/Library/Printers/cdnj500/bin/gs` (bundled) | `/usr/bin/gs` (distro package) |

### Why Ghostscript is bundled on macOS

cupsd on macOS runs filters inside Apple's sandbox. It can read and execute
under `/Library/Printers`, system paths and the spool, and nothing else. A
filter calling `/opt/local/bin/gs` or `/opt/homebrew/bin/gs` fails with
`Sandbox: bash deny file-read-metadata /opt/local/bin/gs`. So `build-gs.sh`
compiles Ghostscript 10.07.0 from the official source (SHA-512 checked
against the Artifex release), statically, with only the `cdnj500` and
`pdfwrite` devices and no fontconfig/dbus/cups/X. The result is a single
18 MB binary linking only `libSystem` and `libiconv`, which the installer
places under `/Library/Printers`. The binary is built on your machine and is
not part of this repository.

Two more sandbox rules the filter obeys: no bash here-strings or here-docs
(they need a temp file the sandbox denies), and Ghostscript is given a
`TMPDIR` inside the filter's own scratch directory.

## Testing without a printer

```sh
./tests/run-tests.sh
```

Pushes PDFs through the real CUPS filter chain with `cupsfilter` and checks
the PCL3GUI stream: page count, resolution, dimensions, PJL header, grayscale,
copies, custom sizes, malformed options, hostile environments. No root needed.
Runs on macOS and Linux (tests that need a missing tool are skipped and
reported).

To capture exactly what a real queue would send, bind a queue to a local
socket and listen with `nc`:

```sh
nc -l 9100 > captured.prn &
sudo lpadmin -p dj500test -E -v socket://127.0.0.1:9100 -P <path to a PPD>
lp -d dj500test somefile.pdf
```

## Troubleshooting

**"Filter failed" right after install.** The filter must be root-owned and
not group/world writable, and Ghostscript must be reachable. Check
`cupstestppd <installed ppd>`; on macOS also look for sandbox denials with
`log show --last 10m --predicate 'eventMessage CONTAINS "Sandbox"'`.

**Queue says "offline" although the printer is on (macOS).** The USB
backend matches the queue's URI against the printer's IEEE-1284 device ID,
`MODEL:DesignJet 500 (C7770B)`. While busy or just powered on the printer
sometimes answers with the plain product string `DesignJet 500`; a queue
bound to that URI never connects. Also, Apple's backend only clears the
"offline" flag inside the same process that set it, so the badge can stay
after the cause is gone. Fix for both: re-run `./install.sh --42in` (or
`--24in`) with the printer idle. It re-probes until it sees the model code and
re-creates the queue.

**Nothing prints, no error.** `lpstat -t` shows queue and job state. Enable
`cupsctl --debug-logging` and read `/var/log/cups/error_log`; the filter logs
its decisions with the prefix `pdftocdnj500:`.

**Colours wrong, streaky, or missing.** If hues are in the right place but
washed out, banded, or a primary is missing (red prints pink, green prints
cyan-grey), that's ink: a cartridge empty or a printhead dry. Use the
printer's front panel (Ink menu → cartridges / printheads / printhead
recovery / image quality print). The printer takes HP 82 colour and HP 10
black cartridges and HP 11 printheads. Ink levels are not readable over USB.

**Linux: `lpinfo -v` doesn't list the printer.** Check `lsusb` for
`03f0:0114 Hewlett-Packard` and that your user is in the `lp`/`lpadmin` group
or run the installer with `sudo`.

## Limits

- 300 and 600 dpi only, the two the device supports.
- No media-type, roll/sheet or cutter controls. The printer uses what is loaded.
- Margins in the PPD are 5 mm sides and 17 mm leading/trailing edge, the
  printer's normal margin mode; content inside them is clipped by the printer.
- Grayscale uses PJL `RENDERMODE = GRAYSCALE`; if a firmware ignores it the
  pixels are still neutral.

## Uninstall

```sh
./uninstall.sh
```

## Licence

Scripts, filter and PPDs in this repository: MIT. Ghostscript (including the
`cdnj500` device) is AGPL-3.0 and is used as a separate program; the macOS
installer builds it from source on your machine and nothing from it is
redistributed here.
