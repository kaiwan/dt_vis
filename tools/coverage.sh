#!/usr/bin/env bash
#
# coverage.sh -- run the dt_vis test suite under instrumentation and produce
# statement-coverage numbers plus an annotated HTML report.
#
#   bash:  no native coverage support exists, so we use bash's own xtrace
#          with PS4 carrying $BASH_SOURCE:$LINENO.  kcov would be the usual
#          answer but it is no longer packaged for Ubuntu 24.04, and
#          bashcov needs a reachable rubygems mirror.
#   awk:   gawk's built-in profiler (--profile) reports an execution count
#          per statement; counts from every test invocation are summed.
#
# Both denominators are computed by the heuristics in tools/cov_bash.awk and
# tools/cov_awk.awk -- see Documentation/testing.md for what that means.
#
# Usage: tools/coverage.sh [outdir]      (default: <repo>/coverage)

set -o errexit
set -o nounset
set -o pipefail
export LC_ALL=C

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
COV=${1:-$ROOT/coverage}

command -v gawk >/dev/null 2>&1 || { echo "coverage.sh: gawk is required" >&2; exit 1; }
command -v bats >/dev/null 2>&1 || { echo "coverage.sh: bats is required" >&2; exit 1; }

rm -rf -- "$COV"
mkdir -p -- "$COV/trace" "$COV/awkprof" "$COV/bin" "$COV/html"
# One test drops privileges (setpriv) to exercise the "cannot read" path;
# its trace must be writable too, or that branch looks uncovered.
chmod 1777 -- "$COV/trace" "$COV/awkprof"

# --------------------------------------------------------------------------
# shims
# --------------------------------------------------------------------------

# Named dt_vis.sh so that $0 (and therefore the usage/version text) is
# unchanged; the real script is *sourced*, so $BASH_SOURCE and $LINENO in the
# trace refer to the real file, not to this shim.
cat >"$COV/bin/dt_vis.sh" <<'SHIM'
#!/usr/bin/env bash
exec 9>>"$DTVIS_COVDIR/trace/t.$$"
BASH_XTRACEFD=9
PS4='@${BASH_SOURCE}:${LINENO}@ '
set -x
# Sourced through a symlink so the script's own symlink-resolution loop is
# exercised (and therefore measured) like it is in normal use.
# shellcheck disable=SC1090
source "$DTVIS_COVDIR/bin/dt_vis-link" "$@"
SHIM

ln -sfn "$ROOT/dt_vis.sh" "$COV/bin/dt_vis-link"

cat >"$COV/bin/awk" <<'SHIM'
#!/bin/sh
prog=unknown
for a in "$@"; do
	case $a in *.awk) prog=$(basename "$a" .awk) ;; esac
done
exec gawk --profile="$DTVIS_COVDIR/awkprof/$prog.$$.prof" "$@"
SHIM

chmod +x "$COV/bin/dt_vis.sh" "$COV/bin/awk"

# --------------------------------------------------------------------------
# run the suite under instrumentation
# --------------------------------------------------------------------------
export DTVIS_COVDIR=$COV
export DTVIS_REAL=$ROOT/dt_vis.sh

echo "== running test suite under instrumentation =="
rc=0
DTVIS=$COV/bin/dt_vis.sh DT_VIS_AWK=$COV/bin/awk \
	bats "$ROOT/tests" >"$COV/bats.log" 2>&1 || rc=$?
tail -1 "$COV/bats.log"
if ((rc != 0)); then
	echo "coverage.sh: test suite failed (rc=$rc); see $COV/bats.log" >&2
	grep -E '^not ok' "$COV/bats.log" >&2 || true
	exit "$rc"
fi

# --------------------------------------------------------------------------
# bash coverage
# --------------------------------------------------------------------------
echo "== bash coverage =="
gawk -v real="$COV/bin/dt_vis-link" '
{
	s = $0
	while (match(s, /:[0-9]+@/)) {
		pre = substr(s, 1, RSTART - 1)
		if (index(pre, real) == length(pre) - length(real) + 1)
			print substr(s, RSTART + 1, RLENGTH - 2) " 1"
		s = substr(s, RSTART + RLENGTH)
	}
}' "$COV"/trace/t.* > "$COV/bash.hits"

gawk -v hits="$COV/bash.hits" -f "$ROOT/tools/cov_bash.awk" \
	"$DTVIS_REAL" > "$COV/bash.tsv"

gawk -v title="dt_vis.sh (bash)" -f "$ROOT/tools/cov_html.awk" \
	"$COV/bash.tsv" >"$COV/html/dt_vis.sh.html" 2>"$COV/bash.stats"
bash_stats=$(cat "$COV/bash.stats")

# --------------------------------------------------------------------------
# awk coverage
# --------------------------------------------------------------------------
echo "== awk coverage =="
awk_report() {
	local prog=$1 list="$COV/$1.profs"
	find "$COV/awkprof" -name "$prog.*.prof" -print > "$list"
	if [[ ! -s $list ]]; then
		echo "0 0"
		return
	fi
	gawk -v list="$list" -f "$ROOT/tools/cov_awk.awk" > "$COV/$prog.tsv"
	gawk -v title="lib/$prog.awk (awk)" -f "$ROOT/tools/cov_html.awk" \
		"$COV/$prog.tsv" >"$COV/html/$prog.awk.html" 2>"$COV/$prog.stats"
	cat "$COV/$prog.stats"
}

dts_stats=$(awk_report dts2tree)
fdt_stats=$(awk_report fdtval)

# --------------------------------------------------------------------------
# summary
# --------------------------------------------------------------------------
{
	printf '%s\n' "$bash_stats dt_vis.sh"
	printf '%s\n' "$dts_stats lib/dts2tree.awk"
	printf '%s\n' "$fdt_stats lib/fdtval.awk"
} > "$COV/summary.raw"

gawk '
BEGIN { printf "\n%-22s %8s %8s %8s\n", "file", "covered", "total", "pct" }
{
	c += $1; t += $2
	printf "%-22s %8d %8d %7.1f%%\n", $3, $1, $2, ($2 ? 100*$1/$2 : 100)
}
END {
	printf "%-22s %8s %8s %8s\n", "----------------------", "--------", "--------", "--------"
	printf "%-22s %8d %8d %7.1f%%\n", "TOTAL", c, t, (t ? 100*c/t : 100)
}' "$COV/summary.raw" | tee "$COV/summary.txt"

# index page
{
	echo '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>dt_vis coverage</title>'
	echo '<style>body{background:#0f1115;color:#d8dee9;font:15px/1.6 system-ui,sans-serif;margin:0;padding:2rem}'
	echo 'a{color:#8fd694}pre{background:#171a21;padding:1rem;border-radius:6px;overflow:auto}</style></head><body>'
	echo '<h1>dt_vis coverage</h1><pre>'
	sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' "$COV/summary.txt"
	echo '</pre><ul>'
	echo '<li><a href="dt_vis.sh.html">dt_vis.sh</a></li>'
	echo '<li><a href="dts2tree.awk.html">lib/dts2tree.awk</a></li>'
	echo '<li><a href="fdtval.awk.html">lib/fdtval.awk</a></li>'
	echo '</ul></body></html>'
} > "$COV/html/index.html"

echo
echo "HTML report: $COV/html/index.html"
echo "Uncovered lines are listed in $COV/*.tsv (state 'U')."
