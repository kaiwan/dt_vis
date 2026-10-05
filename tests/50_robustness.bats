#!/usr/bin/env bats
# Malformed and edge-case input: the tool must never hang, crash or lie.

load helpers

@test "empty input produces just the root" {
	run bash -c "printf '' | '$DTVIS' -C never -a -d 1"
	assert_status 0
	assert_has "/"
}

@test "input with no root node at all does not crash" {
	f=$(mkdts <<-'EOF'
		/dts-v1/;
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
}

@test "stray closing brace is warned about, not fatal" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		};
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_has "stray"
}

@test "unbalanced open brace at EOF is warned about" {
	f=$(mkdts <<-'EOF'
		/ { a { b { };
	EOF
	)
	run dtv -d 2 "$f"
	assert_status 0
	assert_has "unbalanced braces"
}

@test "-q suppresses parser warnings but keeps the tree" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		};
	EOF
	)
	run dtv -q -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_lacks "stray"
}

@test "unterminated block comment does not swallow the tree silently" {
	f=$(mkdts <<-'EOF'
		/ { a { }; };
		/* runaway
		b { };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_lacks "-- b"
}

@test "a node redeclared twice is merged, not duplicated" {
	f=$(mkdts <<-'EOF'
		/ { a { x { }; }; };
		/ { a { y { }; }; };
	EOF
	)
	run dtv -d all "$f"
	assert_has "-- x"
	assert_has "-- y"
	n=$(printf '%s\n' "$output" | grep -c -- '-- a$' || true)
	[ "$n" -eq 1 ]
}

@test "later property assignment wins" {
	f=$(mkdts <<-'EOF'
		/ { a { status = "disabled"; }; };
		/ { a { status = "okay"; }; };
	EOF
	)
	run dtv -d 1 -p status "$f"
	assert_has '"okay"'
	assert_lacks '"disabled"'
}

@test "a fragment referring to itself is not merged into itself" {
	f=$(mkdts <<-'EOF'
		/ { };
		lbl: &lbl { };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "unresolved"
}

@test "deeply nested tree does not blow up the parser" {
	f="$BATS_TEST_TMPDIR/deep.dts"
	{
		printf '/ {\n'
		for i in $(seq 1 200); do printf 'n%d {\n' "$i"; done
		for i in $(seq 1 200); do printf '};\n'; done
		printf '};\n'
	} >"$f"
	run dtv -d all "$f"
	assert_status 0
	assert_has "-- n200"
}

@test "wide tree is rendered completely" {
	f="$BATS_TEST_TMPDIR/wide.dts"
	{
		printf '/ {\n'
		for i in $(seq 1 500); do printf '\tn%d { compatible = "c%d"; };\n' "$i" "$i"; done
		printf '};\n'
	} >"$f"
	run dtv -d 1 -c "$f"
	assert_status 0
	assert_has '"c500"'
	n=$(printf '%s\n' "$output" | grep -c '^[|`]-- n' || true)
	[ "$n" -eq 500 ]
}

@test "CRLF line endings are tolerated" {
	f="$BATS_TEST_TMPDIR/crlf.dts"
	printf '/ {\r\n\ta { compatible = "x";\r\n\t};\r\n};\r\n' >"$f"
	run dtv -d 1 -c "$f"
	assert_status 0
	assert_has "-- a"
	assert_has '"x"'
}

@test "node names with commas, dots and pluses survive" {
	f=$(mkdts <<-'EOF'
		/ { "weird" { }; a.b,c+d@1f { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_has "-- a.b,c+d@1f"
}

@test "a property before any node is ignored, not attributed to /" {
	f=$(mkdts <<-'EOF'
		stray = "x";
		/ { a { }; };
	EOF
	)
	run dtv -d 1 -p stray "$f"
	assert_status 0
	assert_lacks '"x"'
}

@test "binary garbage input terminates" {
	f="$BATS_TEST_TMPDIR/garbage.bin"
	head -c 4096 /dev/urandom >"$f"
	run timeout 30 "$DTVIS" -C never -a -q -d 1 -t dts "$f"
	[ "$status" -ne 124 ]
}
