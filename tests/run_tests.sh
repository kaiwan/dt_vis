#!/usr/bin/env bash
#
# run_tests.sh -- the whole quality gate in one command.
#
#   1. static analysis   : shellcheck (bash), gawk --lint (awk), py_compile
#   2. dynamic analysis  : the bats suite, run under every awk on the box
#   3. coverage          : tools/coverage.sh (stats + HTML report)
#
# Usage: tests/run_tests.sh [--no-coverage]

set -o errexit
set -o nounset
set -o pipefail
export LC_ALL=C

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
do_cov=1
[[ ${1:-} == --no-coverage ]] && do_cov=0

fail=0
hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
bad() { printf '\033[31mFAIL\033[0m: %s\n' "$*"; fail=1; }
good() { printf '\033[32mok\033[0m: %s\n' "$*"; }

# ---------------------------------------------------------------- static ---
hdr "static analysis"

if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -x -S style \
		"$ROOT/dt_vis.sh" "$ROOT/tools/coverage.sh" \
		"$ROOT/tests/run_tests.sh" "$ROOT/tests/helpers.bash"; then
		good "shellcheck clean (severity: style)"
	else
		bad "shellcheck"
	fi
else
	echo "skip: shellcheck not installed"
fi

if command -v gawk >/dev/null 2>&1; then
	lint_ok=1
	for a in "$ROOT"/lib/*.awk "$ROOT"/tools/*.awk; do
		# --lint reports dubious constructs; run the program over /dev/null
		# so only compile-time diagnostics can fire.
		out=$(gawk --lint -v hits=/dev/null -v list=/dev/null -f "$a" </dev/null >/dev/null 2>&1 || true)
		# "no program text" / runtime warnings from an empty run are noise
		out=$(printf '%s\n' "$out" | grep -v 'reference to uninitialized' | grep -v '^$' || true)
		if [[ -n $out ]]; then
			printf '%s: %s\n' "${a#"$ROOT"/}" "$out"
			lint_ok=0
		fi
	done
	if ((lint_ok)); then good "gawk --lint clean"; else bad "gawk --lint"; fi
else
	echo "skip: gawk not installed"
fi

if command -v python3 >/dev/null 2>&1; then
	if python3 -m py_compile "$ROOT/tests/tools/dtb2fs.py"; then
		good "python3 -m py_compile"
	else
		bad "py_compile"
	fi
fi

# --------------------------------------------------------------- dynamic ---
hdr "test suite"

awks=()
for a in mawk gawk busybox-awk original-awk awk; do
	command -v "$a" >/dev/null 2>&1 && awks+=("$a")
done
# de-duplicate by resolved path
declare -A seen=()
run_awks=()
for a in "${awks[@]}"; do
	p=$(readlink -f "$(command -v "$a")")
	[[ -n ${seen[$p]:-} ]] && continue
	seen[$p]=1
	run_awks+=("$a")
done

for a in "${run_awks[@]}"; do
	printf '\n-- awk implementation: %s --\n' "$a"
	if DT_VIS_AWK=$a bats "$ROOT/tests"; then
		good "suite passes under $a"
	else
		bad "suite under $a"
	fi
done

# -------------------------------------------------------------- coverage ---
if ((do_cov)); then
	hdr "coverage"
	if command -v gawk >/dev/null 2>&1 && command -v bats >/dev/null 2>&1; then
		bash "$ROOT/tools/coverage.sh" || bad "coverage run"
	else
		echo "skip: coverage needs gawk and bats"
	fi
fi

hdr "result"
if ((fail)); then
	echo "one or more checks FAILED"
	exit 1
fi
echo "all checks passed"
