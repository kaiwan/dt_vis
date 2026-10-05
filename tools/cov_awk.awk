#!/usr/bin/awk -f
#
# cov_awk.awk -- merge a set of `gawk --profile` outputs into per-line
# statement coverage for an awk program.
#
# Usage: awk -v list=<file-of-profile-paths> -f cov_awk.awk
#
# gawk's profiler emits a pretty-printed copy of the program with an
# execution count in the left column of every statement it ran, and a blank
# column for statements it did not.  The pretty-printed listing is
# deterministic once the count column, the "# N" branch annotations and
# indentation are normalised, so counts from many runs can be summed by
# line index.
#
# Output: TSV  lineno <TAB> state <TAB> hits <TAB> text     (as cov_bash.awk)

BEGIN {
	nfiles = 0
	while ((getline p < list) > 0) {
		if (p == "") continue
		nfiles++
		i = 0
		while ((getline ln < p) > 0) {
			i++
			c = 0
			if (match(ln, /^ *[0-9]+  /)) {
				c = substr(ln, 1, RLENGTH) + 0
				body = substr(ln, RLENGTH + 1)
			} else
				body = ln
			HITS[i] += c
			if (nfiles == 1) TEXT[i] = body
			if (i > NL) NL = i
		}
		close(p)
	}
	close(list)

	for (i = 1; i <= NL; i++) {
		t = TEXT[i]
		sub(/[ \t]*#[ \t]*[0-9]+[ \t]*$/, "", t)	# branch annotation
		sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
		state = "N"
		if (countable(t)) state = (HITS[i] > 0 ? "E" : "U")
		printf "%d\t%s\t%d\t%s\n", i, state, HITS[i], TEXT[i]
	}
}

function countable(s) {
	if (s == "") return 0
	if (s ~ /^#/) return 0				# comment / section header
	if (s ~ /^[}{]$/) return 0
	if (s ~ /^\} else \{$/) return 0
	if (s ~ /^\} else$/) return 0
	if (s ~ /^BEGIN \{$/ || s ~ /^END \{$/) return 0
	if (s ~ /^function [A-Za-z_][A-Za-z0-9_]*\(.*\)[ \t]*\{$/) return 0
	if (s ~ /^\)$/) return 0
	return 1
}
