#!/usr/bin/env bats
# Structural semantics: depth limiting, multi-root merge, fragments, deletes.

load helpers

SM="$BATS_TEST_DIRNAME/fixtures/sm8750-like.dtsi"

@test "-d 0 shows only the root node" {
	run dtv -d 0 "$SM"
	assert_status 0
	assert_has "/"
	assert_lacks "-- cpus"
}

@test "-d 1 shows direct children of / and nothing deeper" {
	run dtv -d 1 "$SM"
	assert_has "-- cpus"
	assert_has "soc: soc@0"
	assert_lacks "-- cpu@0"
}

@test "-d 2 shows grandchildren" {
	run dtv -d 2 "$SM"
	assert_has "cpu0: cpu@0"
	assert_lacks "l2_0: l2-cache"
}

@test "-d all shows the whole tree" {
	run dtv -d all "$SM"
	assert_has "l2_0: l2-cache"
	assert_has "-- core1"
}

@test "cut-off nodes are annotated with their hidden child count" {
	run dtv -d 1 "$SM"
	assert_has "soc: soc@0  ...4"
	assert_has "cpus  ...3"
}

@test "leaf nodes get no child-count annotation" {
	run dtv -d 1 "$SM"
	assert_has "-- timer"
	assert_lacks "timer  ..."
}

@test "a second / { } block merges into the first" {
	run dtv -d 1 "$SM"
	assert_has "-- thermal-zones"
	assert_has "-- cpus"
}

@test "&label fragment merges into the labelled node" {
	# &soc { spmi: spmi@c400000 { ... }; }
	run dtv -d 2 "$SM"
	assert_has "spmi: spmi@c400000"
}

@test "&label fragment property overrides the original" {
	# i2c0 is status="disabled" in the root block, "okay" in the fragment
	run dtv -d all -p status "$SM"
	assert_has 'i2c0: i2c@a80000  "okay"'
}

@test "&label fragment child lands under the right parent" {
	run dtv -d all "$SM"
	assert_has "-- eeprom@50"
	# eeprom is at depth 4 (/ soc qupv3 i2c0 eeprom), so -d 3 must hide it
	run dtv -d 3 "$SM"
	assert_lacks "-- eeprom@50"
}

@test "&{/path} reference resolves against the tree" {
	run dtv -d all -p capacity-dmips-mhz "$SM"
	assert_has 'cpu1: cpu@100  <1024>'
}

@test "unresolvable fragment is reported, not silently dropped" {
	run dtv -d 1 "$SM"
	assert_has "unresolved fragments"
	assert_has "&pmic_glink"
}

@test "/delete-node/ inside a fragment removes the node from the target" {
	run dtv -d all "$SM"
	assert_lacks "-- hyp@80000000"
}

@test "/delete-property/ inside a fragment removes the property" {
	run dtv -d all -p dma-names "$SM"
	assert_lacks "dma-names"
	assert_lacks '"tx"'
}

@test "/delete-node/ in the same block removes the node" {
	f=$(mkdts <<-'EOF'
		/ {
			keep { };
			gone { child { }; };
			/delete-node/ gone;
		};
	EOF
	)
	run dtv -d all "$f"
	assert_has "-- keep"
	assert_lacks "-- gone"
	assert_lacks "-- child"
}

@test "/delete-node/ &label; removes the labelled node" {
	f=$(mkdts <<-'EOF'
		/ { keep { }; vic: victim { }; };
		/ { /delete-node/ &vic; };
	EOF
	)
	run dtv -d all "$f"
	assert_has "-- keep"
	assert_lacks "-- victim"
}

@test "labels are shown by default and hidden with -L" {
	run dtv -d 2 "$SM"
	assert_has "cpu0: cpu@0"
	run dtv -d 2 -L "$SM"
	assert_has "-- cpu@0"
	assert_lacks "cpu0:"
}

@test "-c is shorthand for -p compatible and does not duplicate it" {
	run dtv -d 1 -c -p compatible "$SM"
	assert_has '"qcom,sm8750"'
	# the value must appear exactly once on the root line
	n=$(printf '%s\n' "$output" | head -2 | tail -1 | grep -c 'qcom,sm8750' || true)
	[ "$n" -eq 1 ]
}

@test "-w elides long values, -w 0 does not" {
	run dtv -d all -w 8 -p compatible "$SM"
	assert_has '"qcom,sm'
	assert_lacks '"qcom,sm8750"'
	run dtv -d all -w 0 -p compatible "$SM"
	assert_has '"qcom,sm8750"'
}

@test "multiple properties are prefixed with their names" {
	run dtv -d all -p reg,status -w 0 "$SM"
	assert_has 'status="okay"'
	assert_has 'reg=<'
}

@test "a single property is printed as a bare value" {
	run dtv -d 1 -p compatible "$SM"
	assert_has '/  "qcom,sm8750"'
	assert_lacks 'compatible='
}

@test "-b puts each property on its own line" {
	run dtv -d 1 -b -c "$SM"
	assert_has '+ compatible = "qcom,sm8750"'
}

@test "--stats reports node, property and fragment counts" {
	run dtv -d 1 -s "$SM"
	assert_has "nodes, max depth"
	assert_has "unresolved fragment(s)"
}

@test "node ordering follows source order" {
	run dtv -d 1 "$SM"
	# cpus is declared before soc in the fixture
	ci=$(printf '%s\n' "$output" | grep -n -- '-- cpus' | cut -d: -f1)
	si=$(printf '%s\n' "$output" | grep -n -- '-- soc' | cut -d: -f1)
	[ "$ci" -lt "$si" ]
}
