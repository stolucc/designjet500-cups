#!/bin/bash
#
# run-tests.sh -- exercises the DesignJet 500 driver without a printer.
#
# Pushes small PDFs through the real CUPS filter chain (cupsfilter runs the
# PDF stage and then our filter, exactly as cupsd would) and checks the
# PCL3GUI stream that would reach the printer.  Runs on macOS and Linux.
#
# Usage:  tests/run-tests.sh          (no root needed)

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cdnj500-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip - %s\n' "$1"; }

check() {
    # check DESCRIPTION COMMAND...   (command's exit status decides)
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

count_pages() { LC_ALL=C grep -a -c 'ENTER LANGUAGE=PCL3GUI' "$1"; }
job_name()    { LC_ALL=C grep -a -o 'JOB NAME="[^"]*"' "$1" | head -n 1; }
resolutions() { LC_ALL=C grep -a -o $'\e&u[0-9]*D' "$1" | tr -d '\033' | sort -u; }

OS=$(uname -s)

# A Ghostscript for the fixtures: the bundled one if built, else the system one.
GS=$HERE/vendor/gs/bin/gs
[ -x "$GS" ] || GS=$(command -v gs || true)
[ -n "$GS" ] || { echo "no Ghostscript found; cannot build fixtures" >&2; exit 1; }

# cupsfilter runs the filter named in the PPD, so point test copies of the
# macOS PPDs at the filter inside this checkout (absolute path works on both).
for model in 24in 42in; do
    sed "s#/Library/Printers/cdnj500/filter/pdftocdnj500#$HERE/filter/pdftocdnj500#" \
        "$HERE/ppd/macos/HP-DesignJet_500-$model.ppd" > "$WORK/$model.ppd"
done

run_job() {
    # run_job MODEL OUTFILE PDF [cupsfilter options...]
    local model=$1 out=$2 pdf=$3
    shift 3
    cupsfilter -e -P "$WORK/$model.ppd" -m printer/foo "$@" "$pdf" > "$out" 2> "$out.log"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
"$GS" -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="$WORK/two.pdf" -c '
    /Helvetica 40 selectfont 72 700 moveto (Page one) show
    1 0 0 setrgbcolor 100 100 200 200 rectfill showpage
    72 700 moveto 0 0 1 setrgbcolor (Page two) show showpage'

"$GS" -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="$WORK/a1.pdf" -c '
    <</PageSize [1684 2384]>> setpagedevice
    /Helvetica 150 selectfont 100 2100 moveto (A1 test) show
    0 0 1 setrgbcolor 200 200 1000 1000 rectfill showpage'

# ---------------------------------------------------------------------------
# Scripts: syntax, portability, generated files
# ---------------------------------------------------------------------------
for s in install.sh uninstall.sh build-gs.sh ppd/make-ppd.sh filter/pdftocdnj500 \
         scripts/install-macos.sh scripts/install-linux.sh scripts/uninstall-macos.sh scripts/uninstall-linux.sh; do
    check "bash -n $s" bash -n "$HERE/$s"
    check "$s is executable" test -x "$HERE/$s"
done
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck is clean" shellcheck -S warning "$HERE"/install.sh "$HERE"/uninstall.sh "$HERE"/build-gs.sh \
        "$HERE"/ppd/make-ppd.sh "$HERE"/filter/pdftocdnj500 "$HERE"/scripts/*.sh
else
    skip "shellcheck not installed"
fi
check "filter uses no macOS-only tools"    sh -c "! grep -Eq 'otool|codesign|stat -f|sed -i ' '$HERE/filter/pdftocdnj500'"
check "filter uses no here-strings or here-docs" sh -c "! grep -q '<<' '$HERE/filter/pdftocdnj500'"
check "macOS PPD points at /Library/Printers filter" grep -q '^\*cupsFilter: "application/vnd.cups-pdf 0 /Library/Printers/cdnj500/filter/pdftocdnj500"' "$HERE/ppd/macos/HP-DesignJet_500-42in.ppd"
check "Linux PPD uses the bare filter name"       grep -q '^\*cupsFilter: "application/vnd.cups-pdf 0 pdftocdnj500"' "$HERE/ppd/linux/HP-DesignJet_500-42in.ppd"
check "macOS and Linux PPDs differ only in the filter line" bash -c "diff <(grep -v cupsFilter '$HERE/ppd/macos/HP-DesignJet_500-42in.ppd') <(grep -v cupsFilter '$HERE/ppd/linux/HP-DesignJet_500-42in.ppd')"
check "generated PPDs are current (make-ppd.sh)" sh -c "d=\$(mktemp -d) && cp -R '$HERE/ppd' \"\$d/\" && (cd \"\$d/ppd\" && ./make-ppd.sh >/dev/null) && diff -r '$HERE/ppd' \"\$d/ppd\""

# ---------------------------------------------------------------------------
# PPD sanity
# ---------------------------------------------------------------------------
if command -v cupstestppd >/dev/null 2>&1; then
    for model in 24in 42in; do
        check "cupstestppd accepts the $model PPD" cupstestppd -W sizes -W filters "$WORK/$model.ppd"
    done
else
    skip "cupstestppd not installed"
fi
check "42in PPD offers A0"          grep -q '^\*PageSize A0/' "$WORK/42in.ppd"
check "24in PPD does not offer A0"  sh -c "! grep -q '^\*PageSize A0/' '$WORK/24in.ppd'"

# ---------------------------------------------------------------------------
# Rendering through cupsfilter (needs CUPS; present on macOS and most Linux)
# ---------------------------------------------------------------------------
if ! command -v cupsfilter >/dev/null 2>&1; then
    skip "cupsfilter not installed; rendering tests skipped"
else
    run_job 24in "$WORK/a3draft.prn" "$WORK/two.pdf" -o PageSize=A3 -o cupsPrintQuality=Draft
    check "A3 draft job runs through cupsfilter"      test -s "$WORK/a3draft.prn"
    check "A3 draft job yields 2 PCL3GUI pages"       test "$(count_pages "$WORK/a3draft.prn")" -eq 2
    check "A3 draft job is 300 dpi"                   test "$(resolutions "$WORK/a3draft.prn")" = "&u300D"
    check "A3 draft job has A3 dimensions (mm) in PJL" sh -c "[[ '$(job_name "$WORK/a3draft.prn")' == *'GS 297.0'*'x420'* ]]"
    check "stream starts with PJL UEL"                sh -c "LC_ALL=C head -c 9 '$WORK/a3draft.prn' | grep -q '%-12345X'"
    check "stream ends with PJL EOJ"                  sh -c "LC_ALL=C tail -c 20 '$WORK/a3draft.prn' | grep -aq 'EOJ'"
    check "RENDERMODE is COLOR for RGB jobs"          sh -c "LC_ALL=C grep -aq 'RENDERMODE = COLOR' '$WORK/a3draft.prn'"

    run_job 24in "$WORK/normal.prn" "$WORK/two.pdf" -o PageSize=A4
    check "default quality is 600 dpi"                test "$(resolutions "$WORK/normal.prn")" = "&u600D"
    check "default quality sets MAXDETAIL ON, RET ON" sh -c "LC_ALL=C grep -aq 'MAXDETAIL = ON' '$WORK/normal.prn' && LC_ALL=C grep -aq 'RET = ON' '$WORK/normal.prn'"

    run_job 24in "$WORK/high.prn" "$WORK/two.pdf" -o PageSize=A4 -o cupsPrintQuality=High
    check "High quality is 600 dpi with RET OFF"      sh -c "LC_ALL=C grep -aq 'RET = OFF' '$WORK/high.prn'"

    run_job 24in "$WORK/ipp.prn" "$WORK/two.pdf" -o PageSize=A4 -o print-quality=3
    check "IPP print-quality=3 selects draft"         test "$(resolutions "$WORK/ipp.prn")" = "&u300D"

    run_job 24in "$WORK/gray.prn" "$WORK/two.pdf" -o PageSize=A4 -o ColorModel=Gray
    check "grayscale job renders"                     test "$(count_pages "$WORK/gray.prn")" -eq 2
    check "grayscale job sets RENDERMODE GRAYSCALE"   sh -c "LC_ALL=C grep -aq 'RENDERMODE = GRAYSCALE' '$WORK/gray.prn' && ! LC_ALL=C grep -aq 'RENDERMODE = COLOR' '$WORK/gray.prn'"

    run_job 24in "$WORK/copies.prn" "$WORK/two.pdf" -n 2 -o PageSize=A4
    check "2 copies of 2 pages -> exactly 4 pages"    test "$(count_pages "$WORK/copies.prn")" -eq 4

    run_job 24in "$WORK/land.prn" "$WORK/two.pdf" -o PageSize=A4 -o landscape
    check "landscape A4 stays an A4-wide raster"      sh -c "[[ '$(job_name "$WORK/land.prn")' == *'GS 209'* ]]"

    run_job 24in "$WORK/a1.prn" "$WORK/a1.pdf" -o PageSize=A1
    check "A1 page renders on the 24in model"         sh -c "[[ '$(job_name "$WORK/a1.prn")' == *'GS 594'* ]]"

    run_job 24in "$WORK/custom.prn" "$WORK/two.pdf" -o PageSize=Custom.600x2000mm -o cupsPrintQuality=Draft
    check "custom 600x2000 mm size is honoured"       sh -c "[[ '$(job_name "$WORK/custom.prn")' == *'GS 600.0'*'x2000'* ]]"

    run_job 24in "$WORK/customin.prn" "$WORK/two.pdf" -o PageSize=Custom.24x36in -o cupsPrintQuality=Draft
    check "custom 24x36 in size is honoured"          sh -c "[[ '$(job_name "$WORK/customin.prn")' == *'GS 609.6'*'x914.4'* ]]"

    run_job 24in "$WORK/bad.prn" "$WORK/two.pdf" -o 'PageSize=../../etc/passwd'
    check "malformed PageSize falls back to A4"       sh -c "grep -q 'falling back to A4' '$WORK/bad.prn.log' && [[ '$(job_name "$WORK/bad.prn")' == *'GS 209'* ]]"

    run_job 24in "$WORK/badq.prn" "$WORK/two.pdf" -o PageSize=A4 -o 'cupsPrintQuality=;rm -rf /'
    check "malformed quality falls back to normal"    test "$(resolutions "$WORK/badq.prn")" = "&u600D"
fi

# ---------------------------------------------------------------------------
# Filter invoked directly (stdin, as cupsd does for the last filter), under
# the hostile conditions seen inside the macOS sandbox.
# ---------------------------------------------------------------------------
F=$HERE/filter/pdftocdnj500
check "filter rejects a bad argument count"       sh -c "! '$F' 1 2 3 </dev/null"
check "filter reads the PDF from stdin"           sh -c "PPD='$WORK/24in.ppd' '$F' 7 u t 1 'PageSize=A4' < '$WORK/two.pdf' 2>/dev/null | LC_ALL=C grep -aq 'PCL3GUI'"
check "filter works with an empty environment"    sh -c "env -i PPD='$WORK/24in.ppd' /bin/bash '$F' 8 u t 1 'PageSize=A4' < '$WORK/two.pdf' 2>/dev/null | LC_ALL=C grep -aq 'PCL3GUI'"
check "filter works when TMPDIR is unwritable"    sh -c "env -i TMPDIR=/ PPD='$WORK/24in.ppd' /bin/bash '$F' 9 u t 1 'PageSize=A4' < '$WORK/two.pdf' 2>/dev/null | LC_ALL=C grep -aq 'PCL3GUI'"
check "filter works when TMPDIR is empty"         sh -c "env -i TMPDIR= PPD='$WORK/24in.ppd' /bin/bash '$F' 10 u t 1 'PageSize=A4' < '$WORK/two.pdf' 2>/dev/null | LC_ALL=C grep -aq 'PCL3GUI'"
check "filter works with the Linux PPD variant"   sh -c "PPD='$HERE/ppd/linux/HP-DesignJet_500-42in.ppd' '$F' 11 u t 1 'PageSize=A0' < '$WORK/two.pdf' 2>/dev/null | LC_ALL=C grep -aq 'PCL3GUI'"

# ---------------------------------------------------------------------------
# macOS only: bundled static Ghostscript and the installer's probe
# ---------------------------------------------------------------------------
if [ "$OS" = Darwin ]; then
    BGS=$HERE/vendor/gs/bin/gs
    if [ -x "$BGS" ]; then
        check "bundled gs links only system libraries"      sh -c "! otool -L '$BGS' | grep -Eq '^[[:space:]]*/(opt|usr/local)/'"
        check "bundled gs has cdnj500 and pdfwrite"         sh -c "h=\$('$BGS' -h 2>/dev/null); printf '%s\n' \"\$h\" | grep -qw cdnj500 && printf '%s\n' \"\$h\" | grep -qw pdfwrite"
        check "bundled gs renders with an empty environment" sh -c "env -i '$BGS' -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=cdnj500 -dQuality=-1 -sOutputFile=- '$WORK/two.pdf' | LC_ALL=C grep -aq 'ENTER LANGUAGE=PCL3GUI'"
        for i in 1 2 3 4 5; do "$HERE/install.sh" --check >/dev/null 2>&1 || break; done
        check "install.sh --check passes 5 times in a row (no SIGPIPE flake)" test "$i" -eq 5
    else
        skip "bundled gs not built (run ./build-gs.sh); macOS install checks skipped"
    fi
else
    check "install.sh --check passes on Linux" "$HERE/install.sh" --check
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
