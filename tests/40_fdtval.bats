#!/usr/bin/env bats
# Unit tests for lib/fdtval.awk -- the FDT property value type heuristic.
# Input is fed the same way dt_vis.sh feeds it: `od -An -v -tu1`.

load helpers

# val <hex bytes...>  -> the DTS token fdtval.awk produces
val() {
	local f="$BATS_TEST_TMPDIR/p.bin"
	printf '%s' "$1" | xxd -r -p >"$f"
	od -An -v -tu1 -- "$f" | "${DT_VIS_AWK:-awk}" -f "$LIBDIR/fdtval.awk"
}

@test "empty input yields an empty string" {
	run val ""
	[ "$output" = '""' ]
}

@test "NUL-terminated printable text is a string" {
	# "okay\0"
	run val "6f6b617900"
	[ "$output" = '"okay"' ]
}

@test "several NUL-separated strings become a string list" {
	# "arm,pl011\0arm,primecell\0"
	run val "61726d2c706c3031310061726d2c7072696d6563656c6c00"
	[ "$output" = '"arm,pl011", "arm,primecell"' ]
}

@test "two cells that look like text are still cells" {
	# <0x40000000 0x20000000> = 40 00 00 00 20 00 00 00; '@' and ' ' are
	# printable and the last byte is NUL, but the embedded empty strings
	# rule it out -- this is the case dtc gets right and a naive check does not.
	run val "4000000020000000"
	[ "$output" = '<0x40000000 0x20000000>' ]
}

@test "a single all-zero cell is a cell, not an empty string" {
	run val "00000000"
	[ "$output" = '<0x0>' ]
}

@test "one cell decodes as one hex word" {
	run val "00000068"
	[ "$output" = '<0x68>' ]
}

@test "non-printable bytes with length %% 4 == 0 decode as cells" {
	run val "deadbeef"
	[ "$output" = '<0xdeadbeef>' ]
}

@test "non-printable bytes not a multiple of 4 decode as a byte string" {
	run val "deadbeef0001"
	[ "$output" = '[de ad be ef 00 01]' ]
}

@test "a quote inside a string value is escaped" {
	# "a\"b\0"
	run val "61226200"
	[ "$output" = '"a\"b"' ]
}

@test "a backslash inside a string value is escaped" {
	# "a\\b\0"
	run val "615c6200"
	[ "$output" = '"a\\b"' ]
}

@test "text not NUL-terminated is not treated as a string" {
	# "okay" with no terminator, 4 bytes -> cells
	run val "6f6b6179"
	[ "$output" = '<0x6f6b6179>' ]
}

@test "high-bit bytes are not printable" {
	run val "c3a90000"
	[ "$output" = '<0xc3a90000>' ]
}
