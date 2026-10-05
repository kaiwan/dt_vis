#!/usr/bin/env bats
# Include following (-i / -I / --origin): resolution order, search paths,
# cycle and duplicate handling, and provenance tagging.

load helpers

INC="$BATS_TEST_DIRNAME/fixtures/inc"
KTREE="$BATS_TEST_DIRNAME/fixtures/ktree/arch/arm64/boot/dts/acme/board.dts"

# ---------------------------------------------------------------- basics ---

@test "without -i, fragments targeting included labels stay unresolved" {
	run dtv -d all "$INC/board.dts"
	assert_status 0
	assert_has "unresolved"
	assert_has "&i2c_a"
	assert_has "&pmic_glink"
	assert_lacks "-- eeprom@50"
}

@test "with -i, fragments resolve and the merged tree appears" {
	run dtv -d all -i -I "$INC/incdir" "$INC/board.dts"
	assert_status 0
	assert_lacks "unresolved"
	assert_has "-- soc: soc@0"
	assert_has "-- pmic_glink: pmic-glink"
	assert_has "-- extra_node: extra@1"
}

@test "a fragment's children land under the included node" {
	run dtv -d all -i -I "$INC/incdir" "$INC/board.dts"
	assert_has "-- eeprom@50"
	# eeprom is / -> soc -> i2c_a -> eeprom, i.e. depth 3
	run dtv -d 2 -i -I "$INC/incdir" "$INC/board.dts"
	assert_lacks "-- eeprom@50"
}

@test "a fragment's property overrides the included file's value" {
	run dtv -d all -i -I "$INC/incdir" -p status "$INC/board.dts"
	assert_has 'i2c_a: i2c@a000  "okay"'
	assert_lacks '"disabled"'
}

@test "quoted includes resolve relative to the including file, not the cwd" {
	# soc-base.dtsi does #include "sub/pmic.dtsi"; that path only makes
	# sense relative to soc-base.dtsi's own directory
	cd /
	run dtv -d all -i "$INC/soc-base.dtsi"
	assert_status 0
	assert_has "-- pmic_glink: pmic-glink"
}

@test "a bare filename argument works (dirname of the input is \".\")" {
	cd "$INC"
	run dtv -d all -i board.dts
	assert_status 0
	assert_has "-- pmic_glink: pmic-glink"
}

@test "-i reads includes when the input arrives on stdin" {
	cd "$INC"
	run bash -c "'$DTVIS' -C never -a -d all -i -I incdir < board.dts"
	assert_status 0
	assert_has "-- soc: soc@0"
	assert_has "(stdin)"
}

# ----------------------------------------------------------- search path ---

@test "an angle include is found through -I" {
	run dtv -d all -i -I "$INC/incdir" "$INC/board.dts"
	assert_has "-- extra_node: extra@1"
}

@test "--include-path= long form works and -I may be repeated" {
	run dtv -d all -i --include-path=/nonexistent -I "$INC/incdir" "$INC/board.dts"
	assert_status 0
	assert_has "-- extra_node: extra@1"
}

@test "empty entries in the include path are skipped" {
	# the empty entry has to sit between two real ones, otherwise bash's
	# ${var:+...} collapses it away before awk ever sees the list
	run dtv -d all -i -I /nonexistent -I "" -I "$INC/incdir" "$INC/board.dts"
	assert_status 0
	assert_has "-- extra_node: extra@1"
}

@test "\".\" and \"..\" components in an include path are normalised away" {
	run dtv -d all -i -I "$INC/./incdir" "$INC/board.dts"
	assert_status 0
	assert_has "-- extra_node: extra@1"
	run dtv -d all -i -I "$INC/sub/../incdir" "$INC/board.dts"
	assert_status 0
	assert_has "-- extra_node: extra@1"
}

@test "\"..\" inside a quoted include resolves against the includer" {
	d="$BATS_TEST_TMPDIR/updir"
	mkdir -p "$d/a" "$d/b"
	printf '#include "../b/side.dtsi"\n/ { main { }; };\n' >"$d/a/m.dts"
	printf '/ { sideways { }; };\n' >"$d/b/side.dtsi"
	run dtv -d 1 -i "$d/a/m.dts"
	assert_status 0
	assert_has "-- sideways"
	assert_has "-- main"
}

@test "an unfindable include warns and leaves the fragment unresolved" {
	run dtv -d all -i "$INC/board.dts"
	assert_status 0
	assert_has "&extra_node"
	assert_has "unresolved"
}

@test "the missing-include warning names the file and line" {
	run bash -c "'$DTVIS' -C never -a -d 1 -i '$INC/board.dts' 2>&1 >/dev/null"
	assert_has 'board.dts:9: warning: cannot find include "vendor/extra.dtsi"'
}

@test "-q silences include warnings" {
	run bash -c "'$DTVIS' -C never -a -d 1 -i -q '$INC/board.dts' 2>&1 >/dev/null"
	[ -z "$output" ]
}

@test "a C header include is skipped silently, not reported missing" {
	run bash -c "'$DTVIS' -C never -a -d 1 -i -I '$INC/incdir' '$INC/board.dts' 2>&1 >/dev/null"
	assert_lacks "fake.h"
	run dtv -d 1 -s -i -I "$INC/incdir" "$INC/board.dts"
	assert_has "1 header(s) skipped"
}

@test "a malformed #include line is ignored" {
	d="$BATS_TEST_TMPDIR/mal"
	mkdir -p "$d"
	printf '#include "\n/ { a { }; };\n' >"$d/m.dts"
	run dtv -d 1 -i "$d/m.dts"
	assert_status 0
	assert_has "-- a"
}

@test "the basedir fallback finds an include the includer's own directory lacks" {
	# b.dtsi lives in dir B (reached via -I) and includes "c.dtsi", which
	# exists only next to the primary input in dir A
	a="$BATS_TEST_TMPDIR/A"; b="$BATS_TEST_TMPDIR/B"
	mkdir -p "$a" "$b"
	printf '#include <b.dtsi>\n/ { top { }; };\n' >"$a/main.dts"
	printf '#include "c.dtsi"\n/ { frome { }; };\n' >"$b/b.dtsi"
	printf '/ { fromc { }; };\n' >"$a/c.dtsi"
	run dtv -d 1 -i -I "$b" "$a/main.dts"
	assert_status 0
	assert_has "-- fromc"
	assert_has "-- frome"
}

# -------------------------------------------------- kernel auto-detection ---

@test "the kernel tree's include-prefixes directory is auto-detected" {
	run dtv -d all -i "$KTREE"
	assert_status 0
	assert_has "-- auto_node: auto@1"
	assert_lacks "unresolved"
}

@test "--no-auto-include turns the auto-detection off" {
	run dtv -d all -i --no-auto-include -q "$KTREE"
	assert_status 0
	assert_has "unresolved"
	assert_has "&auto_node"
}

@test "auto-detection is harmless when there is no kernel tree above" {
	run dtv -d all -i -I "$INC/incdir" "$INC/board.dts"
	assert_status 0
	assert_lacks "unresolved"
}

# ------------------------------------------------ duplicates and cycles ----

@test "including the same file twice reads it once" {
	run dtv -d all -s -i -I "$INC/incdir" "$INC/board.dts"
	assert_has "3 file(s) read, 1 repeat(s) skipped"
}

@test "a duplicate include does not duplicate nodes" {
	run dtv -d all -i -I "$INC/incdir" "$INC/board.dts"
	n=$(printf '%s\n' "$output" | grep -c -- '-- pmics$' || true)
	[ "$n" -eq 1 ]
}

@test "an include cycle terminates" {
	run timeout 30 "$DTVIS" -C never -a -d all -s -i "$INC/cyc/a.dtsi"
	assert_status 0
	assert_has "-- from-a"
	assert_has "-- from-b"
}

@test "include nesting deeper than the limit is refused, not followed forever" {
	d="$BATS_TEST_TMPDIR/deepinc"
	mkdir -p "$d"
	for i in $(seq 1 120); do
		printf '#include "n%d.dtsi"\n/ { lvl%d { }; };\n' "$((i + 1))" "$i" \
			>"$d/n$i.dtsi"
	done
	printf '/ { bottom { }; };\n' >"$d/n121.dtsi"
	run timeout 60 "$DTVIS" -C never -a -d 1 -i "$d/n1.dtsi"
	assert_status 0
	assert_has "nesting deeper than"
	assert_has "-- lvl1"
	assert_lacks "-- bottom"
}

@test "an include chain well within the limit is followed to the end" {
	d="$BATS_TEST_TMPDIR/okinc"
	mkdir -p "$d"
	for i in $(seq 1 60); do
		printf '#include "n%d.dtsi"\n/ { lvl%d { }; };\n' "$((i + 1))" "$i" \
			>"$d/n$i.dtsi"
	done
	printf '/ { bottom { }; };\n' >"$d/n61.dtsi"
	run timeout 60 "$DTVIS" -C never -a -d 1 -i "$d/n1.dtsi"
	assert_status 0
	assert_has "-- bottom"
	assert_lacks "nesting deeper than"
}

# ---------------------------------------------------------------- origin ---

@test "--origin tags each node with the file that declared it" {
	run dtv -d all -i -I "$INC/incdir" --origin "$INC/board.dts"
	assert_status 0
	assert_has "-- soc: soc@0  [soc-base.dtsi]"
	assert_has "-- pmics  [pmic.dtsi]"
	assert_has "-- eeprom@50  [board.dts]"
}

@test "--origin marks nodes that a later file also contributed to" {
	run dtv -d all -i -I "$INC/incdir" --origin "$INC/board.dts"
	assert_has "-- i2c_a: i2c@a000  [soc-base.dtsi +1]"
}

@test "--origin shows the basename, not the full path" {
	run dtv -d all -i -I "$INC/incdir" --origin "$INC/board.dts"
	assert_lacks "[$INC/soc-base.dtsi]"
}

@test "--origin works without -i, naming the single input file" {
	run dtv -d 1 --origin "$FIXTURES/board.dts"
	assert_status 0
	assert_has "[board.dts]"
}

@test "--origin plus a property both appear on the node line" {
	run dtv -d all -i -I "$INC/incdir" --origin -p status "$INC/board.dts"
	assert_has '[pmic.dtsi +1]  "okay"'
}

# --------------------------------------------------------- other inputs ----

@test "/include/ \"file\"; is followed too" {
	d="$BATS_TEST_TMPDIR/dtcinc"
	mkdir -p "$d"
	printf '/dts-v1/;\n/include/ "part.dtsi";\n/ { here { }; };\n' >"$d/m.dts"
	printf '/ { there { }; };\n' >"$d/part.dtsi"
	run dtv -d 1 -i "$d/m.dts"
	assert_status 0
	assert_has "-- here"
	assert_has "-- there"
}

@test "/include/ inside a node body keeps the node stack" {
	d="$BATS_TEST_TMPDIR/dtcinc2"
	mkdir -p "$d"
	printf '/ { outer {\n/include/ "part.dtsi";\nsibling { };\n}; };\n' >"$d/m.dts"
	printf 'inner { };\n' >"$d/part.dtsi"
	run dtv -d all -i "$d/m.dts"
	assert_status 0
	assert_has "-- outer"
	assert_has "-- inner"
	# the statement that carried the directive must not leak into the next
	# node header once the included file has been read
	assert_has "-- sibling"
	assert_lacks "part.dtsi\""
}

@test "an unterminated comment in an include does not leak into the includer" {
	d="$BATS_TEST_TMPDIR/leak"
	mkdir -p "$d"
	printf '#include "bad.dtsi"\n/ { survivor { }; };\n' >"$d/m.dts"
	printf '/ { inbad { }; };\n/* runaway\n' >"$d/bad.dtsi"
	run dtv -d 1 -i "$d/m.dts"
	assert_status 0
	assert_has "-- survivor"
	assert_has "-- inbad"
	assert_has "unterminated comment"
}

@test "-i is ignored for dtb input, with a note" {
	command -v dtc >/dev/null 2>&1 || skip "dtc not installed"
	run bash -c "'$DTVIS' -C never -a -d 1 -i '$DATA/board.dtb' 2>&1 >/dev/null"
	assert_has "ignored for dtb input"
}

@test "-i is ignored for fdt input, with a note" {
	[ -d "$DATA/device-tree" ] || skip "device-tree fixture not built"
	run bash -c "'$DTVIS' -C never -a -d 1 -i '$DATA/device-tree' 2>&1 >/dev/null"
	assert_has "ignored for fdt input"
}

@test "-q silences the ignored-for-dtb note" {
	command -v dtc >/dev/null 2>&1 || skip "dtc not installed"
	run bash -c "'$DTVIS' -C never -a -d 1 -i -q '$DATA/board.dtb' 2>&1 >/dev/null"
	[ -z "$output" ]
}

@test "--stats reports the include tally only when -i was given" {
	run dtv -d 1 -s -i -I "$INC/incdir" "$INC/board.dts"
	assert_has "-- includes:"
	run dtv -d 1 -s "$INC/board.dts"
	assert_lacks "-- includes:"
}
