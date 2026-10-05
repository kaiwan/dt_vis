#!/usr/bin/env bats
# Corner cases that the main suite does not reach: invocation paths,
# engine defaults, and the rarely-taken branches of the parser.

load helpers

@test "invoked through a symlink, the script still finds lib/" {
	ln -s "$(cd "$(dirname "$DTVIS")" && pwd)/$(basename "$DTVIS")" \
		"$BATS_TEST_TMPDIR/dtv-link"
	run "$BATS_TEST_TMPDIR/dtv-link" -C never -a -d 1 "$FIXTURES/board.dts"
	assert_status 0
	assert_has "-- cpus"
}

@test "invoked through a relative symlink, the script still finds lib/" {
	cd "$BATS_TEST_TMPDIR"
	ln -s "$DTVIS" ./rel-link
	run ./rel-link -C never -a -d 1 "$FIXTURES/board.dts"
	assert_status 0
	assert_has "-- cpus"
}

@test "--type=dtb long form with = is honoured" {
	command -v dtc >/dev/null 2>&1 || skip "dtc not installed"
	run "$DTVIS" --type=dtb --color=never -a -d 1 "$DATA/board.dtb"
	assert_status 0
	assert_has "-- cpus"
}

@test "default --color auto emits no escapes when stdout is not a tty" {
	run "$DTVIS" -a -d 1 "$FIXTURES/board.dts"
	assert_status 0
	assert_lacks $'\033['
}

@test "engine defaults apply when no -v options are passed" {
	# exercises the "if (maxdepth == \"\")" style defaults in dts2tree.awk
	run "${DT_VIS_AWK:-awk}" -f "$LIBDIR/dts2tree.awk" <"$FIXTURES/board.dts"
	assert_status 0
	assert_has "── cpus"   # depth defaults to 1, box glyphs by default
	assert_lacks "-- cpu@0"
}

@test "engine default renders box-drawing glyphs" {
	run "${DT_VIS_AWK:-awk}" -f "$LIBDIR/dts2tree.awk" <"$FIXTURES/board.dts"
	assert_has $'├'
}

@test "/delete-property/ on the same node removes it" {
	f=$(mkdts <<-'EOF'
		/ { a { status = "okay"; /delete-property/ status; }; };
	EOF
	)
	run dtv -d 1 -p status "$f"
	assert_status 0
	assert_lacks "okay"
}

@test "/delete-node/ outside any node is not fatal" {
	f=$(mkdts <<-'EOF'
		/delete-node/ nothing;
		/ { a { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
}

@test "/delete-property/ outside any node is not fatal" {
	f=$(mkdts <<-'EOF'
		/delete-property/ nothing;
		/ { a { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
}

@test "&{/} refers to the root node" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		&{/} { b { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_has "-- b"
	assert_lacks "unresolved"
}

@test "a trailing slash in a path reference is ignored" {
	# NB: the "//" form cannot be tested here -- the comment stripper eats it
	# as a line comment, and "//" is not legal in a device tree path anyway.
	# See Documentation/limitations.md.
	f=$(mkdts <<-'EOF'
		/ { a { c { }; }; };
		&{/a/c/} { deep-child { }; };
	EOF
	)
	run dtv -d all "$f"
	assert_status 0
	assert_has "-- deep-child"
	assert_lacks "unresolved"
}

@test "fdt back-end reports a property it cannot read" {
	# fault injection: an "od" on PATH that always fails
	bin="$BATS_TEST_TMPDIR/fakebin"
	mkdir -p "$bin"
	printf '#!/bin/sh\nexit 1\n' >"$bin/od"
	chmod +x "$bin/od"
	d="$BATS_TEST_TMPDIR/dt2"
	mkdir -p "$d/node"
	printf 'okay\0' >"$d/node/status"
	PATH="$bin:$PATH" run dtv -d all -p status -w 0 "$d"
	assert_status 0
	assert_has "<unreadable>"
}

@test "a dtb without dtc installed is a clear error" {
	command -v dtc >/dev/null 2>&1 || skip "dtc not installed"
	# PATH with everything dt_vis needs except dtc
	bin="$BATS_TEST_TMPDIR/nodtc"
	mkdir -p "$bin"
	for t in awk gawk mawk od cat tr mktemp rm dirname basename readlink sh bash; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$bin/$t"
	done
	PATH="$bin" run "$DTVIS" -C never -a -d 1 "$DATA/board.dtb"
	assert_status 2
	assert_has "dtc is not installed"
}

@test "an unreadable file is reported (as a non-root user)" {
	command -v setpriv >/dev/null 2>&1 || skip "setpriv not available"
	[ "$(id -u)" -eq 0 ] || skip "needs root in order to drop privileges"
	d=$(mktemp -d /tmp/dtvis-perm.XXXXXX)
	chmod 755 "$d"
	printf '/ { };\n' >"$d/noread.dts"
	chmod 000 "$d/noread.dts"
	run setpriv --reuid=65534 --regid=65534 --clear-groups "$DTVIS" -d 1 "$d/noread.dts"
	rm -rf "$d"
	assert_status 2
	assert_has "cannot read"
}

@test "a path reference to a nonexistent node is reported unresolved" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		&{/no/such/node} { x { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "unresolved"
	assert_has "&{/no/such/node}"
}

@test "an anonymous node body is ignored with a warning" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		{ ghost { inner { }; }; };
	EOF
	)
	run dtv -d all "$f"
	assert_status 0
	assert_has "-- a"
	assert_has "anonymous"
	assert_lacks "-- ghost"
	assert_lacks "-- inner"
}

@test "a property with an empty name is ignored" {
	f=$(mkdts <<-'EOF'
		/ { a { = "novalue"; ok = "yes"; }; };
	EOF
	)
	run dtv -d 1 -p ok "$f"
	assert_status 0
	assert_has '"yes"'
}

@test "a top-level node that is neither / nor &ref is adopted under /" {
	f=$(mkdts <<-'EOF'
		orphan { child { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- orphan"
	assert_has "not / or &ref"
}

@test "--stats reports parse anomalies when the input is malformed" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		};
	EOF
	)
	run dtv -d 1 -s -q "$f"
	assert_status 0
	assert_has "parse anomalies"
	assert_has "stray brace"
}

@test "--stats on clean input reports no anomalies" {
	run dtv -d 1 -s "$FIXTURES/board.dts"
	assert_status 0
	assert_lacks "parse anomalies"
}

@test "-p naming a property no node has produces a bare tree" {
	run dtv -d 1 -p no-such-property "$FIXTURES/board.dts"
	assert_status 0
	assert_has "-- cpus"
	assert_lacks "="
}

@test "an empty -p list behaves like no -p at all" {
	a=$(dtv -d 1 "$FIXTURES/board.dts")
	b=$(dtv -d 1 -p ',' "$FIXTURES/board.dts")
	[ "$a" = "$b" ]
}

@test "/omit-if-no-ref/ prefix does not become part of the node name" {
	f=$(mkdts <<-'EOF2'
		/ {
			/omit-if-no-ref/ pinmux: pin@0 { compatible = "x"; };
			b { };
		};
	EOF2
	)
	run dtv -d 1 -c "$f"
	assert_status 0
	assert_has "pinmux: pin@0"
	assert_has '"x"'
	assert_lacks "omit-if-no-ref"
}

@test "a /plugin/ overlay parses without crashing" {
	f=$(mkdts <<-'EOF2'
		/dts-v1/;
		/plugin/;
		&{/soc} { newdev@1 { compatible = "acme,new"; }; };
	EOF2
	)
	run dtv -d all -c "$f"
	assert_status 0
	assert_has "unresolved"
	assert_has "&{/soc}"
}
