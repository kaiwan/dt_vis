#!/usr/bin/awk -f
#
# fdtval.awk -- render one flattened-device-tree property value as DTS text.
#
# Input:  the output of `od -An -v -tu1 <propfile>` (decimal bytes).
# Output: a DTS value token -- "str", "str2"  |  <0x... 0x...>  |  [xx xx ...]
#
# The kernel exposes properties in /proc/device-tree (and
# /sys/firmware/devicetree/base) as raw binary files with no type
# information, so the type has to be guessed the same way `fdtdump` and
# `dtc` do: printable + NUL-terminated => string list, multiple of 4 bytes
# => cells, otherwise => byte string.  This is a heuristic, not a decode;
# see Documentation/limitations.md.

{ for (bi = 1; bi <= NF; bi++) b[++n] = $bi + 0 }

END {
	if (n == 0) { printf "\"\""; exit }

	if (is_printable_string()) { emit_strings(); exit }
	if (n % 4 == 0) { emit_cells(); exit }
	emit_bytes()
}

# Same rule dtc(1) uses (util.c:util_is_printable_string): the buffer must be
# NUL-terminated, every character printable, and no zero-length component.
# The "no empty string" clause is what stops <0x40000000 0x20000000>
# (bytes 40 00 00 00 20 00 00 00) being mistaken for the string "@".
function is_printable_string(   s) {
	if (b[n] != 0) return 0
	s = 1
	while (s <= n) {
		if (b[s] == 0) return 0			# empty component
		while (s <= n && b[s] != 0 && b[s] >= 32 && b[s] <= 126) s++
		if (s > n || b[s] != 0) return 0	# hit a non-printable byte
		s++
	}
	return 1
}

function emit_strings(   i, out, cur, first) {
	out = ""; cur = ""; first = 1
	for (i = 1; i <= n; i++) {
		if (b[i] == 0) {
			out = out (first ? "" : ", ") "\"" cur "\""
			first = 0; cur = ""
		} else
			cur = cur esc(sprintf("%c", b[i]))
	}
	# No trailing flush is needed: is_printable_string() has already
	# guaranteed b[n] == 0, so the loop above always closes the last string.
	printf "%s", out
}

function esc(c) {
	if (c == "\\") return "\\\\"
	if (c == "\"") return "\\\""
	return c
}

function emit_cells(   i, w, out) {
	out = "<"
	for (i = 1; i <= n; i += 4) {
		w = b[i] * 16777216 + b[i+1] * 65536 + b[i+2] * 256 + b[i+3]
		out = out (i == 1 ? "" : " ") sprintf("0x%x", w)
	}
	printf "%s>", out
}

function emit_bytes(   i, out) {
	out = "["
	for (i = 1; i <= n; i++)
		out = out (i == 1 ? "" : " ") sprintf("%02x", b[i])
	printf "%s]", out
}
