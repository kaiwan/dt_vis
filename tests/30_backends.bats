#!/usr/bin/env bats
# The three input back-ends: DTS text, compiled DTB, device-tree filesystem.

load helpers

setup_file() {
	command -v dtc >/dev/null 2>&1 || return 0
	mkdir -p "$BATS_TEST_DIRNAME/data"
	dtc -I dts -O dtb -q -q -q \
		-o "$BATS_TEST_DIRNAME/data/board.dtb" \
		"$BATS_TEST_DIRNAME/fixtures/board.dts"
	rm -rf "$BATS_TEST_DIRNAME/data/device-tree"
	python3 "$BATS_TEST_DIRNAME/tools/dtb2fs.py" \
		"$BATS_TEST_DIRNAME/data/board.dtb" \
		"$BATS_TEST_DIRNAME/data/device-tree"
}

need_dtc() { command -v dtc >/dev/null 2>&1 || skip "dtc not installed"; }
need_fs()  { [ -d "$DATA/device-tree" ] || skip "device-tree fixture not built"; }

@test "dts back-end: reads a source file" {
	run dtv -d all -c "$FIXTURES/board.dts"
	assert_status 0
	assert_has '"acme,demoboard"'
	assert_has "uart0: serial@9000000"
}

@test "dts back-end: reads from stdin" {
	run bash -c "'$DTVIS' -C never -a -d 1 < '$FIXTURES/board.dts'"
	assert_status 0
	assert_has "(stdin)"
	assert_has "-- cpus"
}

@test "dts back-end: explicit - means stdin" {
	run bash -c "'$DTVIS' -C never -a -d 1 - < '$FIXTURES/board.dts'"
	assert_status 0
	assert_has "-- cpus"
}

@test "dtb back-end: magic number is autodetected" {
	need_dtc
	run dtv -d all -c "$DATA/board.dtb"
	assert_status 0
	assert_has '"acme,demoboard"'
	assert_has "serial@9000000"
}

@test "dtb back-end: works through a pipe" {
	need_dtc
	run bash -c "cat '$DATA/board.dtb' | '$DTVIS' -C never -a -d 1"
	assert_status 0
	assert_has "-- cpus"
}

@test "dtb and dts back-ends agree on tree shape" {
	need_dtc
	a=$(dtv -d all -L "$FIXTURES/board.dts" | grep -v '^tests\|^/home\|\.dts$\|\.dtb$' | sort)
	b=$(dtv -d all -L "$DATA/board.dtb"     | grep -v '^tests\|^/home\|\.dts$\|\.dtb$' | sort)
	[ "$a" = "$b" ]
}

@test "dtb back-end: fragment was already merged by dtc" {
	need_dtc
	run dtv -d all "$DATA/board.dtb"
	assert_has "eeprom@50"
}

@test "fdt back-end: walks a device-tree directory" {
	need_fs
	run dtv -d all -c "$DATA/device-tree"
	assert_status 0
	assert_has '"acme,demoboard"'
	assert_has "serial@9000000"
}

@test "fdt back-end: decodes cell properties like dtc does" {
	need_fs
	run dtv -d all -p reg -w 0 "$DATA/device-tree"
	assert_has "memory@40000000  <0x40000000 0x20000000>"
}

@test "fdt back-end: decodes string properties" {
	need_fs
	run dtv -d all -p status -w 0 "$DATA/device-tree"
	assert_has 'serial@9000000  "okay"'
}

@test "fdt back-end: decodes byte-string properties" {
	need_fs
	run dtv -d all -p local-mac-address -w 0 "$DATA/device-tree"
	assert_has "[de ad be ef 00 01]"
}

@test "fdt back-end: empty file is a boolean property" {
	need_fs
	d="$BATS_TEST_TMPDIR/dt"
	mkdir -p "$d/node"
	: >"$d/node/some-flag"
	run dtv -d all -p some-flag "$d"
	assert_has "(bool)"
}

@test "--type fdt on a regular file is rejected" {
	run "$DTVIS" -t fdt "$FIXTURES/board.dts"
	assert_status 2
	assert_has "needs a directory"
}

@test "--type dts forces source parsing of a .dtb-named file" {
	f="$BATS_TEST_TMPDIR/notreally.dtb"
	printf '/ { forced { }; };\n' >"$f"
	run dtv -t dts -d 1 "$f"
	assert_status 0
	assert_has "forced"
}

@test "a directory is detected as fdt without --type" {
	need_fs
	run dtv -d 0 "$DATA/device-tree"
	assert_status 0
}
