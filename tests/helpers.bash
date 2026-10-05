# Shared helpers for the dt_vis bats suite.
# shellcheck shell=bash
# $output, $status and $lines are set by bats' `run`.
# shellcheck disable=SC2154

# DTVIS may be overridden (tools/coverage.sh points it at an xtrace shim).
DTVIS="${DTVIS:-${BATS_TEST_DIRNAME}/../dt_vis.sh}"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
DATA="${BATS_TEST_DIRNAME}/data"
LIBDIR="${BATS_TEST_DIRNAME}/../lib"
export DTVIS FIXTURES DATA LIBDIR

# Run dt_vis with colour off and ASCII glyphs, so assertions stay readable.
dtv() {
	"$DTVIS" -C never -a "$@"
}

# Write $1 to a scratch .dts file and echo its path.
mkdts() {
	local f
	f="$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/dtvis.XXXXXX.dts")"
	cat >"$f"
	printf '%s\n' "$f"
}

# $output and $status are set by bats' `run`.
# shellcheck disable=SC2154

# Assert that $output contains the literal string $1.
assert_has() {
	if [[ $output != *"$1"* ]]; then
		printf 'expected output to contain: %s\n--- actual ---\n%s\n' "$1" "$output" >&2
		return 1
	fi
}

# Assert that $output does NOT contain the literal string $1.
assert_lacks() {
	if [[ $output == *"$1"* ]]; then
		printf 'expected output NOT to contain: %s\n--- actual ---\n%s\n' "$1" "$output" >&2
		return 1
	fi
}

skip_if_root() {
	[ "$(id -u)" -ne 0 ] || skip "running as root: DAC permission checks do not apply"
}

assert_status() {
	if [[ $status -ne $1 ]]; then
		printf 'expected exit status %s, got %s\n--- output ---\n%s\n' "$1" "$status" "$output" >&2
		return 1
	fi
}
