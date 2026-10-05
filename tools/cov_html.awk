#!/usr/bin/awk -f
#
# cov_html.awk -- render a coverage TSV (from cov_bash.awk / cov_awk.awk)
# as a self-contained annotated HTML listing.
#
# Usage: awk -v title=... -v srcfile=... -f cov_html.awk cov.tsv > out.html
# Writes "<covered> <executable>" to stderr so the caller can total up.

BEGIN { FS = "\t"; cov = 0; exe = 0 }

{
	L[NR] = $1; S[NR] = $2; C[NR] = $3; T[NR] = $4
	if ($2 == "E") { cov++; exe++ }
	else if ($2 == "U") exe++
}

END {
	pct = exe ? (100.0 * cov / exe) : 100.0
	printf "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
	printf "<title>coverage: %s</title>\n", esc(title)
	print  "<style>"
	print  ":root{--bg:#0f1115;--fg:#d8dee9;--mut:#5c6470;--ok:#1e3b25;--okf:#8fd694;--bad:#4a1d21;--badf:#ff9a9a}"
	print  "body{background:var(--bg);color:var(--fg);font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;margin:0;padding:1.5rem}"
	print  "h1{font-size:1.05rem;margin:0 0 .25rem;font-family:system-ui,sans-serif}"
	print  ".sum{color:var(--mut);font-family:system-ui,sans-serif;margin-bottom:1rem}"
	print  ".sum b{color:var(--fg)}"
	print  "table{border-collapse:collapse;width:100%}"
	print  "td{padding:0 .5rem;white-space:pre;vertical-align:top}"
	print  "td.n{color:var(--mut);text-align:right;user-select:none;width:4ch}"
	print  "td.h{color:var(--mut);text-align:right;user-select:none;width:7ch}"
	print  "tr.E{background:var(--ok)} tr.E td.h{color:var(--okf)}"
	print  "tr.U{background:var(--bad)} tr.U td.h{color:var(--badf)}"
	print  "tr.N td.s{color:var(--mut)}"
	print  "</style></head><body>"
	printf "<h1>%s</h1>\n", esc(title)
	printf "<div class=\"sum\"><b>%.1f%%</b> statement coverage &mdash; <b>%d</b> of <b>%d</b> executable lines covered, <b>%d</b> uncovered</div>\n",
	    pct, cov, exe, exe - cov
	print  "<table>"
	for (i = 1; i <= NR; i++) {
		printf "<tr class=\"%s\"><td class=\"n\">%d</td><td class=\"h\">%s</td><td class=\"s\">%s</td></tr>\n",
		    S[i], L[i], (S[i] == "N" ? "" : C[i] "&times;"), esc(T[i])
	}
	print  "</table></body></html>"

	printf "%d %d\n", cov, exe > "/dev/stderr"
	close("/dev/stderr")
}

function esc(s) {
	gsub(/&/, "\\&amp;", s)
	gsub(/</, "\\&lt;", s)
	gsub(/>/, "\\&gt;", s)
	return s
}
