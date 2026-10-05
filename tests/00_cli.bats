#!/usr/bin/env bats
# Command-line surface: options, validation, exit status.

load helpers

@test "--help exits 0 and shows usage" {
	run "$DTVIS" --help
	assert_status 0
	assert_has "Usage:"
	assert_has "--depth"
}

@test "-h is the same as --help" {
	run "$DTVIS" -h
	assert_status 0
	assert_has "Usage:"
}

@test "--version prints a version" {
	run "$DTVIS" --version
	assert_status 0
	assert_has "dt_vis.sh"
}

@test "-V prints a version" {
	run "$DTVIS" -V
	assert_status 0
}

@test "unknown option fails with status 2" {
	run "$DTVIS" --no-such-option
	assert_status 2
	assert_has "unknown option"
}

@test "missing argument to --depth is rejected" {
	run "$DTVIS" --depth
	assert_status 2
	assert_has "requires an argument"
}

@test "non-numeric --depth is rejected" {
	run "$DTVIS" -d banana "$FIXTURES/board.dts"
	assert_status 2
	assert_has "--depth must be"
}

@test "negative --depth other than -1 is rejected" {
	run "$DTVIS" --depth=-7 "$FIXTURES/board.dts"
	assert_status 2
}

@test "non-numeric --width is rejected" {
	run "$DTVIS" -w wide "$FIXTURES/board.dts"
	assert_status 2
	assert_has "--width must be"
}

@test "bad --color is rejected" {
	run "$DTVIS" -C mauve "$FIXTURES/board.dts"
	assert_status 2
	assert_has "--color must be"
}

@test "bad --type is rejected" {
	run "$DTVIS" -t elf "$FIXTURES/board.dts"
	assert_status 2
	assert_has "--type must be"
}

@test "nonexistent file is reported" {
	run "$DTVIS" /nonexistent/path.dts
	assert_status 2
	assert_has "no such file"
}

@test "unreadable file is reported" {
	skip_if_root
	f="$BATS_TEST_TMPDIR/unreadable.dts"
	printf '/ { };\n' >"$f"
	chmod 000 "$f"
	run "$DTVIS" "$f"
	assert_status 2
	assert_has "cannot read"
}

@test "--depth all and -d -1 are equivalent" {
	run dtv -d all "$FIXTURES/board.dts"
	a=$output
	run dtv -d -1 "$FIXTURES/board.dts"
	[ "$a" = "$output" ]
}

@test "long options with = are accepted" {
	run "$DTVIS" --depth=1 --color=never --props=compatible --width=10 "$FIXTURES/board.dts"
	assert_status 0
	assert_has "acme,demo"
}

@test "-- ends option parsing" {
	run dtv -d 0 -- "$FIXTURES/board.dts"
	assert_status 0
}

@test "--color always emits ANSI escapes; never does not" {
	run "$DTVIS" -C always -a -d 1 "$FIXTURES/board.dts"
	assert_status 0
	assert_has $'\033['
	run "$DTVIS" -C never -a -d 1 "$FIXTURES/board.dts"
	assert_lacks $'\033['
}

@test "DT_VIS_LIBDIR pointing nowhere is a clean error" {
	DT_VIS_LIBDIR=/nonexistent run "$DTVIS" "$FIXTURES/board.dts"
	assert_status 2
	assert_has "cannot find"
}
