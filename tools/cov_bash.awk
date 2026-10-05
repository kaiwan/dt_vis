#!/usr/bin/awk -f
#
# cov_bash.awk -- classify every line of a bash script as covered /
# uncovered / non-executable, given the line numbers bash's xtrace reported.
#
# Usage: awk -v hits=<file> -f cov_bash.awk <script.sh>
#        <file> holds "<lineno> <count>" pairs, one per line.
#
# Output: TSV  lineno <TAB> state <TAB> hits <TAB> text
#         E = executable & covered, U = executable & not covered,
#         N = not executable
#
# Bash has no native coverage instrumentation, so the *denominator* -- which
# lines could ever be traced -- is a heuristic.  It excludes:
#   * blank lines, comments and the shebang
#   * here-document bodies
#   * function headers
#   * the structural keywords bash never traces (fi/done/esac/else/then/do/
#     ;;/{/}) and bare `case` pattern labels
#   * continuation lines: a backslash-continued command is one unit, and
#     bash reports it against exactly one of its lines (empirically not
#     always the first), so hits are summed over the group and attributed
#     to the group's first line.
# See Documentation/testing.md.

BEGIN {
	while ((getline ln < hits) > 0) {
		split(ln, a, " ")
		H[a[1] + 0] += a[2] + 0
	}
	close(hits)
}

{ src[NR] = $0 }

END {
	n = NR
	group_lines(n)
	mark_heredocs(n)
	mark_case_depth(n)

	for (i = 1; i <= n; i++) {
		state = "N"
		if (executable(i))
			state = (GH[i] > 0 ? "E" : "U")
		printf "%d\t%s\t%d\t%s\n", i, state, GH[i] + 0, src[i]
	}
}

# GRP[i] = first line of the backslash-continued group containing i.
# GH[i]  = total hits for that group (only meaningful on the head line).
function group_lines(last,   k, head) {
	head = 0
	for (k = 1; k <= last; k++) {
		if (head == 0) head = k
		GRP[k] = head
		GH[head] += (k in H) ? H[k] : 0
		if (substr(src[k], length(src[k]), 1) != "\\") head = 0
	}
}

function mark_heredocs(last,   k, d, tt) {
	for (k = 1; k <= last; k++) {
		if (indoc) {
			tt = trim(src[k])
			HD[k] = 1
			if (tt == delim) indoc = 0
			continue
		}
		if (match(src[k], /<<-?[ \t]*'?[A-Za-z_][A-Za-z0-9_]*'?/)) {
			d = substr(src[k], RSTART, RLENGTH)
			sub(/^<<-?[ \t]*/, "", d)
			gsub(/'/, "", d)
			delim = d; indoc = 1
		}
	}
}

function mark_case_depth(last,   k, tt) {
	for (k = 1; k <= last; k++) {
		tt = trim(src[k])
		CD[k] = depth
		if (tt ~ /(^|[ \t;])case[ \t].*[ \t]in$/) depth++
		else if (tt ~ /^esac/ && depth > 0) depth--
	}
}

function executable(k,   tt) {
	if (HD[k]) return 0			# here-document body
	if (GRP[k] != k) return 0		# continuation tail
	tt = trim(src[k])
	if (tt == "") return 0
	if (tt ~ /^#/) return 0
	if (tt ~ /^(fi|done|esac|else|then|do|\}|\{|;;)$/) return 0
	if (tt ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{?$/) return 0
	# bare `case` pattern label, with or without an immediate ";;"
	if (CD[k] > 0 && tt ~ /^[^ \t()]*\)[ \t]*(;;)?$/) return 0
	return 1
}

function trim(s) {
	sub(/^[ \t]+/, "", s)
	sub(/[ \t]+$/, "", s)
	return s
}
