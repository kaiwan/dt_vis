#!/usr/bin/env bats
# Lexical layer: comments, strings, cpp directives.
# These are the cases where a naive line-oriented parser goes wrong.

load helpers

@test "braces and semicolons inside a string literal are inert" {
	f=$(mkdts <<-'EOF'
		/ {
			a { s = "has { and } and ; inside"; };
			b { };
		};
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_has "-- b"
	assert_lacks "warning"
}

@test "a string containing /* does not open a comment" {
	f=$(mkdts <<-'EOF'
		/ {
			a { s = "/* not a comment"; };
			b { };
		};
	EOF
	)
	run dtv -d 1 -p s -w 0 "$f"
	assert_has '"/* not a comment"'
	assert_has "-- b"
}

@test "a string containing // does not open a line comment" {
	f=$(mkdts <<-'EOF'
		/ { a { url = "http://example.com/x"; }; };
	EOF
	)
	run dtv -d 2 -p url -w 0 "$f"
	assert_has 'http://example.com/x'
}

@test "escaped quote inside a string does not end it" {
	f=$(mkdts <<-'EOF'
		/ { a { s = "he said \"};\" ok"; }; b { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_has "-- a"
	assert_has "-- b"
	assert_lacks "warning"
}

@test "block comment spanning many lines is removed" {
	f=$(mkdts <<-'EOF'
		/ {
			/* this comment
			   contains a {
			   and a };
			   and a ; too
			 */
			a { };
		};
	EOF
	)
	run dtv -d 1 "$f"
	assert_has "-- a"
	assert_lacks "warning"
}

@test "line comment to end of line is removed" {
	f=$(mkdts <<-'EOF'
		/ {
			a { }; // trailing }; junk ;
			b { };
		};
	EOF
	)
	run dtv -d 1 "$f"
	assert_has "-- a"
	assert_has "-- b"
	assert_lacks "warning"
}

@test "cpp #include and #define lines are ignored" {
	f=$(mkdts <<-'EOF'
		#include <dt-bindings/gpio/gpio.h>
		#define FOO 1
		/ { a { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_lacks "warning"
}

@test "multi-line #define continuation is fully skipped" {
	f=$(mkdts <<-'EOF'
		#define MAC(a, b) \
			{ this would break a naive parser } \
			; and so would this ;
		/ { a { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_status 0
	assert_has "-- a"
	assert_lacks "warning"
}

@test "#address-cells is a property, not a cpp directive" {
	f=$(mkdts <<-'EOF'
		/ {
			#address-cells = <2>;
			#size-cells = <0>;
			a { };
		};
	EOF
	)
	run dtv -d 1 -p '#address-cells' -w 0 "$f"
	assert_has "<2>"
	assert_has "-- a"
}

@test "#if / #endif are stripped but both branches remain (documented limitation)" {
	f=$(mkdts <<-'EOF'
		/ {
		#ifdef CONFIG_A
			a { };
		#else
			b { };
		#endif
		};
	EOF
	)
	run dtv -d 1 "$f"
	assert_has "-- a"
	assert_has "-- b"
}

@test "multi-line cell array property is read as one value" {
	f=$(mkdts <<-'EOF'
		/ { a {
			interrupts = <0 1 2>,
				     <3 4 5>;
		}; };
	EOF
	)
	run dtv -d 2 -p interrupts -w 0 "$f"
	assert_has "<0 1 2>, <3 4 5>"
}

@test "byte-string property is preserved" {
	f=$(mkdts <<-'EOF'
		/ { a { mac = [de ad be ef 00 01]; }; };
	EOF
	)
	run dtv -d 2 -p mac -w 0 "$f"
	assert_has "[de ad be ef 00 01]"
}

@test "boolean property renders as (bool)" {
	f=$(mkdts <<-'EOF'
		/ { a { cache-unified; }; };
	EOF
	)
	run dtv -d 2 -p cache-unified "$f"
	assert_has "(bool)"
}

@test "multiple labels on one node are all shown" {
	f=$(mkdts <<-'EOF'
		/ { one: two: node@0 { }; };
	EOF
	)
	run dtv -d 1 "$f"
	assert_has "one,two: node@0"
}
