#!/usr/bin/awk -f
#
# dts2tree.awk -- Device Tree Source (DTS/DTSI) -> depth-limited tree renderer
#
# Part of dt_vis.  See Documentation/architecture.md for the full design.
#
# Reads DTS text on stdin, builds an in-memory node model, then renders a
# depth-limited tree.  Multiple `/ { }` blocks are merged; `&label { }` and
# `&{/path} { }` fragments are resolved against labels/paths defined in the
# same input and merged into the main tree.  Unresolvable fragments are
# reported separately rather than silently dropped.
#
# With `follow=1` the reader descends into `#include "..."`, `#include <...>`
# and `/include/ "..."` (device-tree sources only -- C headers are skipped,
# since they hold macros, not nodes), which is what makes fragments targeting
# labels declared in an included file resolve.
#
# Deliberately POSIX-awk only: runs under mawk, gawk, busybox awk and
# the original one-true-awk.  No gensub/asort/length(array)/RS-regex.
#
# Variables (set with -v):
#   maxdepth   depth limit; 0 = root only, N = N levels below root,
#              -1 = unlimited                                  (default 1)
#   props      comma-separated property names to display        (default "")
#   width      max chars of a property value before eliding; 0 = unlimited
#                                                              (default 48)
#   ascii      1 = ASCII tree glyphs instead of box drawing     (default 0)
#   color      1 = ANSI colour                                  (default 0)
#   labels     1 = show DTS labels ("cpu0: cpu@0")              (default 1)
#   block      1 = one property per line instead of inline      (default 0)
#   stats      1 = print a summary footer                       (default 0)
#   srcname    name shown in the header line                    (default "")
#   follow     1 = descend into #include / /include/            (default 0)
#   incpaths   colon-separated search path for <angle> includes (default "")
#   basedir    fallback directory for "quoted" includes         (default ".")
#   origin     1 = tag each node with the file that declared it (default 0)
#   maxinc     maximum include nesting depth                   (default 100)
#
# Exit status is set by the caller; this program only writes to stdout,
# and diagnostics to stderr.

BEGIN {
	if (maxdepth == "")	maxdepth = 1
	if (width == "")	width = 48
	if (labels == "")	labels = 1
	if (basedir == "")	basedir = "."
	if (maxinc == "")	maxinc = 100
	FS = "\n"

	# ---- tree glyphs -------------------------------------------------
	if (ascii) {
		G_TEE = "|-- "; G_ELL = "`-- "; G_BAR = "|   "; G_GAP = "    "
	} else {
		G_TEE = "\342\224\234\342\224\200\342\224\200 "	# |--
		G_ELL = "\342\224\224\342\224\200\342\224\200 "	# `--
		G_BAR = "\342\224\202   "			# |
		G_GAP = "    "
	}
	ELLIPSIS = ascii ? "..." : "\342\200\246"

	# ---- colours -----------------------------------------------------
	if (color) {
		C_RST = "\033[0m";  C_NODE = "\033[1;36m"; C_LBL  = "\033[35m"
		C_CMP = "\033[32m"; C_PROP = "\033[33m";   C_DIM  = "\033[2m"
		C_HDR = "\033[1m";  C_WARN = "\033[31m"
	}

	# ---- wanted property list ----------------------------------------
	nwant = 0
	if (props != "") {
		ntmp = split(props, WantTmp, ",")
		for (wi = 1; wi <= ntmp; wi++) {
			wname = trim(WantTmp[wi])
			if (wname == "" || (wname in WantSet)) continue	# dedupe -c -p compatible
			WantSet[wname] = 1
			nwant++; Want[nwant] = wname
		}
	}

	# ---- parser state -------------------------------------------------
	NN = 0			# node counter
	sp = 0			# node stack pointer
	in_comment = 0		# inside /* */
	s_in_str = 0		# scanner: inside "..."
	in_pathref = 0		# scanner: inside &{ ... }
	cpp_cont = 0		# previous cpp line ended with backslash
	buf = ""
	fn = 0			# include-file stack depth
	n_directives = 0; n_deleted = 0; n_delprop = 0; n_props = 0
	n_badclose = 0; n_badopen = 0
	n_incfiles = 0; n_incskipped = 0; n_incmissing = 0; n_incdup = 0
	nnc[0] = 0		# the virtual container that holds / and fragments
	split("", DelLabel)	# portable "declare this as an empty array"

	curfile = (srcname != "" ? srcname : "(stdin)")
	curline = 0
	# The primary input counts as already-included, so a cycle that leads
	# back to it does not read it a second time.
	if (follow && curfile != "(stdin)") Included[normpath(curfile)] = 1
	ROOT = get_child(0, "/")
}

# ======================================================================
# Line intake
# ======================================================================
{
	process_line($0, curfile_top(), NR)
	drain_includes()
}

function curfile_top() { return (srcname != "" ? srcname : "(stdin)") }

# Strip cpp directives, strip comments, feed the scanner.  Called for every
# line of every file, so `curfile`/`curline` always say where we are -- which
# is what makes diagnostics and --origin meaningful once includes are followed.
function process_line(line, file, lineno) {
	curfile = file
	curline = lineno

	if (cpp_cont) {
		cpp_cont = ends_with_backslash(line)
		return
	}
	# #include is the one directive we may act on rather than drop
	if (line ~ /^[ \t]*#[ \t]*include[ \t]*["<]/) {
		cpp_cont = ends_with_backslash(line)
		if (follow) cpp_include(line)
		return
	}
	# everything else the preprocessor owns is structure, not device tree
	if (line ~ /^[ \t]*#[ \t]*(include|define|undef|if|ifdef|ifndef|else|elif|endif|pragma|error|warning|line|import)([ \t(].*)?$/) {
		cpp_cont = ends_with_backslash(line)
		return
	}

	scan(strip_comments(line) " ")
}

# ======================================================================
# Include handling
# ======================================================================

function cpp_include(line,   spec) {
	if (match(line, /"[^"]+"/))
		do_include(substr(line, RSTART + 1, RLENGTH - 2), 0)
	else if (match(line, /<[^>]+>/))
		do_include(substr(line, RSTART + 1, RLENGTH - 2), 1)
}

function do_include(spec, angle,   p) {
	# Only device-tree sources can contribute nodes.  dt-bindings headers
	# are pure #define, so skipping them by extension avoids both the I/O
	# and a storm of "cannot find <dt-bindings/...>" warnings when no
	# header search path was given.
	if (spec !~ /\.dtsi?$/) { n_incskipped++; return }

	p = resolve_include(spec, angle)
	if (p == "") {
		n_incmissing++
		Missing[spec] = 1
		warn("cannot find include \"" spec "\"")
		return
	}
	# A device tree include graph is a DAG and re-including a file merges
	# to the same result, so skipping repeats is both safe and what stops
	# an accidental cycle from spinning forever.
	if (p in Included) { n_incdup++; return }
	Included[p] = 1
	n_incfiles++
	push_include(p)
}

function resolve_include(spec, angle,   p, k, m, dirs) {
	if (!angle) {			# "..." resolves next to the includer
		p = normpath(dirname_of(curfile) "/" spec)
		if (exists(p)) return p
	}
	m = split(incpaths, dirs, ":")
	for (k = 1; k <= m; k++) {
		if (dirs[k] == "") continue
		p = normpath(dirs[k] "/" spec)
		if (exists(p)) return p
	}
	if (!angle) {
		p = normpath(basedir "/" spec)
		if (exists(p)) return p
	}
	return ""
}

# Included files are read with an explicit stack rather than by recursing,
# for the same reason render() is iterative: mawk's evaluation stack is a
# fixed 1024 slots, and nesting the reader inside itself exhausts it long
# before any sane include-depth limit is reached.  Here the recursion depth
# is constant no matter how deep the include chain goes.
#
# Slot 0 is the primary stream (stdin); slots 1..fn are open included files.
# awk keeps a read position per filename, so leaving a file open across the
# nested read and coming back to it is exactly what `getline < path` does.
#
# The lexer state (comment/string/statement buffer) is saved per slot so an
# unterminated comment or a half-built statement cannot leak across a file
# boundary.  The *node* stack is deliberately shared, because /include/ is
# legal inside a node body and must continue building that node.

function push_include(path) {
	if (fn >= maxinc) {
		warn("include nesting deeper than " maxinc "; not following " path)
		return
	}
	fn++
	f_path[fn] = path
	f_lineno[fn] = 0
	f_started[fn] = 0
}

# Note where the includer's state is saved: *here*, at the moment we actually
# switch files, not in push_include().  `/include/ "x";` is pushed from inside
# on_stmt(), i.e. while the scanner is still holding that very statement in
# `buf` -- snapshotting there would restore the consumed directive text
# afterwards and glue it onto the next node header.
function drain_includes(   ln) {
	while (fn > 0) {
		if (!f_started[fn]) {
			save_state(fn - 1)
			in_comment = 0; l_in_str = 0; buf = ""; cpp_cont = 0
			f_started[fn] = 1
		}
		if ((getline ln < f_path[fn]) > 0) {
			f_lineno[fn]++
			process_line(ln, f_path[fn], f_lineno[fn])
			continue
		}
		close(f_path[fn])
		if (in_comment) {
			curfile = f_path[fn]; curline = f_lineno[fn]
			warn("unterminated comment at end of file")
		}
		fn--
		restore_state(fn)
	}
}

function save_state(i) {
	f_com[i] = in_comment; f_str[i] = l_in_str
	f_buf[i] = buf; f_cpp[i] = cpp_cont
	f_file[i] = curfile; f_line[i] = curline
}

function restore_state(i) {
	in_comment = f_com[i]; l_in_str = f_str[i]
	buf = f_buf[i]; cpp_cont = f_cpp[i]
	curfile = f_file[i]; curline = f_line[i]
}

function exists(p,   r, junk) {
	if (p in ExistCache) return ExistCache[p]
	r = (getline junk < p)
	close(p)
	ExistCache[p] = (r >= 0)
	return ExistCache[p]
}

function normpath(p,   parts, n, out, i, k, st) {
	# The leading gsub collapses runs of slashes, so the only empty component
	# split() can yield is the leading one of an absolute path -- which must
	# be kept, since it is what makes the result absolute again.
	gsub(/\/+/, "/", p)
	n = split(p, parts, "/")
	k = 0
	for (i = 1; i <= n; i++) {
		if (parts[i] == ".") continue
		if (parts[i] == ".." && k > 0 && st[k] != ".." && st[k] != "") {
			k--
			continue
		}
		k++; st[k] = parts[i]
	}
	out = ""
	for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") st[i]
	return out
}

# Note: for "/x.dtsi" this returns "" rather than "/", which is deliberate --
# the only caller pastes a "/" and the spec on the end and runs the result
# through normpath(), so "" + "/" + "y.dtsi" gives the right "/y.dtsi".
function dirname_of(p,   i) {
	i = length(p)
	while (i > 0 && substr(p, i, 1) != "/") i--
	if (i == 0) return "."
	return substr(p, 1, i - 1)
}

function basename_of(p,   i) {
	i = length(p)
	while (i > 0 && substr(p, i, 1) != "/") i--
	return substr(p, i + 1)
}

END {
	if (sp != 0)
		warn("unbalanced braces: " sp " node(s) left open at EOF")

	resolve_fragments()

	hdr = srcname != "" ? srcname : "device tree"
	printf "%s%s%s\n", C_HDR, hdr, C_RST

	render(ROOT)

	report_unresolved()

	if (stats)
		print_stats()
}

# ======================================================================
# Lexical layer
# ======================================================================

function ends_with_backslash(s) {
	return (substr(s, length(s), 1) == "\\")
}

# Remove /* */ and // comments while respecting string literals.
# `in_comment` persists across lines so block comments may span lines.
function strip_comments(s,   out, i, n, c, c2) {
	out = ""; n = length(s); i = 1
	while (i <= n) {
		c = substr(s, i, 1)
		if (in_comment) {
			if (c == "*" && substr(s, i + 1, 1) == "/") {
				in_comment = 0; i += 2
			} else
				i++
			continue
		}
		if (l_in_str) {
			out = out c
			if (c == "\\") { out = out substr(s, i+1, 1); i += 2; continue }
			if (c == "\"") l_in_str = 0
			i++
			continue
		}
		if (c == "\"") { l_in_str = 1; out = out c; i++; continue }
		c2 = substr(s, i + 1, 1)
		if (c == "/" && c2 == "*") { in_comment = 1; i += 2; continue }
		if (c == "/" && c2 == "/") break		# to end of line
		out = out c; i++
	}
	return out
}

# Character scanner: splits the cleaned stream into node-open / node-close /
# statement events.  Quote-aware so that ';' '{' '}' inside string literals
# are inert.  &{ /path } references are passed through as literal text.
function scan(s,   i, n, c, t) {
	n = length(s); i = 1
	while (i <= n) {
		c = substr(s, i, 1)

		if (s_in_str) {
			buf = buf c
			if (c == "\\") { buf = buf substr(s, i+1, 1); i += 2; continue }
			if (c == "\"") s_in_str = 0
			i++
			continue
		}
		if (in_pathref) {
			buf = buf c
			if (c == "}") in_pathref = 0
			i++
			continue
		}
		if (c == "\"") { s_in_str = 1; buf = buf c; i++; continue }

		if (c == "{") {
			t = trim(buf)
			# "&{" starts a path reference, not a node body
			if (substr(t, length(t), 1) == "&") {
				in_pathref = 1; buf = buf c; i++; continue
			}
			on_open(t); buf = ""; i++; continue
		}
		if (c == "}") { on_close(); buf = ""; i++; continue }
		if (c == ";") { on_stmt(trim(buf)); buf = ""; i++; continue }

		buf = buf c; i++
	}
}

# ======================================================================
# Syntactic layer
# ======================================================================

function on_open(decl,   labs, name, id, p, l) {
	# A node header may be prefixed by a directive:
	#     /omit-if-no-ref/ pinmux: pin@0 { ... };
	# Strip any such prefixes before looking for labels.  (Whether the node
	# survives depends on phandle references we do not track, so it is
	# always shown -- see Documentation/limitations.md.)
	while (match(decl, /^\/[a-z][a-z0-9-]*\/[ \t]*/)) {
		n_directives++
		decl = trim(substr(decl, RLENGTH + 1))
	}

	labs = ""
	# strip any number of leading "label:" prefixes
	while (match(decl, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
		l = substr(decl, 1, RLENGTH)
		sub(/[ \t]*:$/, "", l)
		labs = labs (labs == "" ? "" : ",") l
		decl = trim(substr(decl, RLENGTH + 1))
	}
	name = decl

	if (name == "") { n_badopen++; warn("anonymous node body ignored"); push(0); return }

	if (sp == 0) {
		# top-level block: "/", "&label" or "&{/path}"
		if (name == "/")			id = ROOT
		else if (substr(name, 1, 1) == "&")	id = get_child(0, name)
		else {
			n_badopen++
			warn("top-level node '" name "' is not / or &ref; treating as root child")
			id = get_child(ROOT, name)
		}
	} else {
		p = stk[sp]
		if (p == 0) { push(0); return }		# inside an ignored subtree
		id = get_child(p, name)
	}

	add_labels(id, labs)
	push(id)
}

function on_close() {
	if (sp == 0) { n_badclose++; warn("stray '}' ignored"); return }
	sp--
}

function on_stmt(t,   eq, name, val, id) {
	if (t == "") return				# e.g. the ';' after '}'
	id = (sp > 0) ? stk[sp] : 0

	if (substr(t, 1, 1) == "/") {			# a /directive/
		n_directives++
		if (t ~ /^\/delete-node\/[ \t]/) {
			do_delete_node(id, trim(substr(t, 14)))
		} else if (t ~ /^\/delete-property\/[ \t]/) {
			do_delete_prop(id, trim(substr(t, 18)))
		} else if (follow && t ~ /^\/include\/[ \t]/) {
			# dtc's own include; legal inside a node body, so the
			# node stack is deliberately left alone across it
			if (match(t, /"[^"]+"/))
				do_include(substr(t, RSTART + 1, RLENGTH - 2), 0)
		}
		return					# /dts-v1/, /memreserve/, ... ignored
	}
	if (id == 0) return

	eq = index(t, "=")
	if (eq == 0) { name = t; val = "" }
	else { name = trim(substr(t, 1, eq - 1)); val = trim(substr(t, eq + 1)) }
	if (name == "") return

	gsub(/[ \t]+/, " ", val)
	set_prop(id, name, val)
	n_props++
}

function do_delete_node(parent, name,   cid) {
	if (parent == 0) parent = ROOT
	if (substr(name, 1, 1) == "&") {
		DelLabel[substr(name, 2)] = 1		# resolved in END
		n_deleted++
		return
	}
	# If the node is not (yet) a child here, create a tombstone: inside a
	# &label fragment the victim lives in the target subtree, and
	# merge_node() propagates the deleted flag when the fragment lands.
	cid = get_child(parent, name)
	mark_deleted(cid)
	n_deleted++
}

function do_delete_prop(id, name) {
	if (id == 0) return
	n_delprop++
	if ((id, name) in nprop) delete nprop[id, name]
	DelProp[id, name] = 1
	nnd[id]++; ndpn[id, nnd[id]] = name
}

function push(id) { sp++; stk[sp] = id }

# ======================================================================
# Node model
# ======================================================================

function get_child(p, nm,   id) {
	if ((p, nm) in cidx) { touch(cidx[p, nm]); return cidx[p, nm] }
	NN++
	id = NN
	nname[id] = nm; nparent[id] = p
	nnc[id] = 0; nnp[id] = 0; nnd[id] = 0
	nlabels[id] = ""; ndel[id] = 0
	cidx[p, nm] = id
	nnc[p]++; nchild[p, nnc[p]] = id
	if (origin) { norigin[id] = curfile; nfiles[id] = 0; touch(id) }
	return id
}

# Record that a file contributes to this node.  Only tracked when --origin
# is on: it is a per-node set, and nobody wants to pay for it when the answer
# is not going to be printed.
function touch(id) { touch_file(id, curfile) }

function touch_file(id, f) {
	if (!origin || f == "") return
	if ((id, f) in nfile) return
	nfile[id, f] = 1
	nfiles[id]++
	nfl[id, nfiles[id]] = f
}

function add_labels(id, labs,   k, m, L) {
	if (labs == "") return
	# Invariant: `labs` is a comma-joined list of non-empty labels (built
	# that way in on_open(), and filtered in merge_node()), so split()
	# never yields an empty component here.
	m = split(labs, L, ",")
	for (k = 1; k <= m; k++) {
		if (!((id, L[k]) in HasLabel)) {
			HasLabel[id, L[k]] = 1
			nlabels[id] = nlabels[id] (nlabels[id] == "" ? "" : ",") L[k]
		}
		labelmap[L[k]] = id
	}
}

function set_prop(id, name, val) {
	if (!((id, name) in nprop)) { nnp[id]++; npn[id, nnp[id]] = name }
	nprop[id, name] = val
	touch(id)
}

# Iterative for the same reason render() is: see the comment there.
function mark_deleted(id,   n, cur, k) {
	n = 1; MDstk[1] = id
	while (n > 0) {
		cur = MDstk[n]; n--
		ndel[cur] = 1
		for (k = 1; k <= nnc[cur]; k++) { n++; MDstk[n] = nchild[cur, k] }
	}
}

# ======================================================================
# Fragment resolution (&label { } and &{/path} { })
# ======================================================================

function resolve_fragments(   j, id, nm, tgt, k) {
	# nchild[0,1] is ROOT; 2..nnc[0] are the top-level fragments
	for (j = 2; j <= nnc[0]; j++) {
		id = nchild[0, j]
		nm = nname[id]
		tgt = 0
		if (substr(nm, 1, 2) == "&{") {
			tgt = lookup_path(substr(nm, 3, length(nm) - 3))
		} else {
			k = substr(nm, 2)
			if (k in labelmap && labelmap[k] != id) tgt = labelmap[k]
		}
		if (tgt) {
			merge_node(id, tgt)
			Resolved[id] = tgt
		} else {
			n_unres++
			Unres[n_unres] = id
		}
	}
	# /delete-node/ &label; applied after labels are all known
	for (k in DelLabel)
		if (k in labelmap) mark_deleted(labelmap[k])
}

# Walk an absolute path, creating nothing: returns node id or 0.
function lookup_path(p,   parts, m, k, cur) {
	sub(/^\//, "", p)
	if (p == "") return ROOT
	m = split(p, parts, "/")
	cur = ROOT
	for (k = 1; k <= m; k++) {
		if (parts[k] == "") continue
		if (!((cur, parts[k]) in cidx)) return 0
		cur = cidx[cur, parts[k]]
	}
	return cur
}

# Merge subtree `src` into `dst`.  Later text wins, so src overrides dst.
function merge_node(src, dst,   j, pn, cid, tid, m, L, k) {
	for (j = 1; j <= nfiles[src]; j++)	# carry provenance across the merge
		touch_file(dst, nfl[src, j])

	m = split(nlabels[src], L, ",")
	for (k = 1; k <= m; k++)
		if (L[k] != "") { add_labels(dst, L[k]) }

	for (j = 1; j <= nnd[src]; j++) {		# deleted properties
		pn = ndpn[src, j]
		if ((dst, pn) in nprop) delete nprop[dst, pn]
		DelProp[dst, pn] = 1
	}
	for (j = 1; j <= nnp[src]; j++) {
		pn = npn[src, j]
		if ((src, pn) in nprop)			# skip ones src deleted
			set_prop(dst, pn, nprop[src, pn])
	}
	for (j = 1; j <= nnc[src]; j++) {
		cid = nchild[src, j]
		tid = get_child(dst, nname[cid])
		if (ndel[cid]) { mark_deleted(tid); continue }
		merge_node(cid, tid)
	}
}

# ======================================================================
# Rendering
# ======================================================================

# Depth-first pre-order walk with an explicit stack.
#
# This is deliberately iterative.  mawk has a fixed 1024-slot evaluation
# stack, so a recursive renderer dies part-way through the output ("program
# limit exceeded") on trees deeper than roughly 90 nodes.  Real device trees
# are nowhere near that deep, but a visualiser that silently truncates its
# own output is worse than useless, and an explicit stack costs nothing.
function render(root,   sp2, id, dep, pfx, last, isr, j, c, nk, kids, cut, cp) {
	sp2 = 1
	Rid[1] = root; Rdep[1] = 0; Rpfx[1] = ""; Rlast[1] = 1; Risr[1] = 1

	while (sp2 > 0) {
		id = Rid[sp2]; dep = Rdep[sp2]; pfx = Rpfx[sp2]
		last = Rlast[sp2]; isr = Risr[sp2]
		sp2--
		# Invariant: only live children are ever pushed (see below) and
		# ROOT cannot be deleted, so no ndel[] check is needed here.

		nk = 0
		for (j = 1; j <= nnc[id]; j++) {
			c = nchild[id, j]
			if (!ndel[c]) { nk++; kids[nk] = c }
		}
		cut = (maxdepth >= 0 && dep >= maxdepth && nk > 0)
		cp  = isr ? "" : pfx (last ? G_GAP : G_BAR)

		if (isr) {
			printf "%s%s%s", C_NODE, nname[id], C_RST
		} else {
			printf "%s%s%s%s", pfx, C_DIM, (last ? G_ELL : G_TEE), C_RST
			if (labels && nlabels[id] != "")
				printf "%s%s: %s", C_LBL, nlabels[id], C_RST
			printf "%s%s%s", C_NODE, nname[id], C_RST
		}
		if (cut)
			printf "  %s%s%d%s", C_DIM, ELLIPSIS, nk, C_RST
		emit_origin(id)
		emit_props(id, cp)
		printf "\n"

		if (nk == 0 || cut) continue
		for (j = nk; j >= 1; j--) {	# reverse push => source order out
			sp2++
			Rid[sp2] = kids[j]; Rdep[sp2] = dep + 1
			Rpfx[sp2] = cp; Rlast[sp2] = (j == nk); Risr[sp2] = 0
		}
	}
}

# "[file.dtsi]" = where the node was first declared.  "+N" = N further files
# also declared children of it or set properties on it, which is the usual
# shape of an SoC .dtsi patched by a board .dts.
function emit_origin(id,   extra) {
	if (!origin || !(id in norigin)) return
	extra = nfiles[id] - 1
	printf "  %s[%s%s]%s", C_DIM, basename_of(norigin[id]),
	    (extra > 0 ? " +" extra : ""), C_RST
}

# Inline mode prints bare values when a single property was requested (the
# name is then obvious) and "name=value" when several were.  Block mode
# always prints the name.
function emit_props(id, contprefix,   k, w, v, out, nm) {
	if (nwant == 0) return
	out = ""
	for (k = 1; k <= nwant; k++) {
		w = Want[k]
		if (!((id, w) in nprop)) continue
		v = elide(nprop[id, w])
		if (block) {
			printf "\n%s%s+ %s%s%s = %s", contprefix, C_DIM, C_RST,
			    pcolor(w), w, C_RST pv(w, v)
		} else {
			nm = (nwant > 1) ? pcolor(w) w "=" C_RST : ""
			out = out "  " nm pcolor(w) pv(w, v)
		}
	}
	if (!block && out != "") printf "%s", out
}

function pcolor(w) { return (w == "compatible") ? C_CMP : C_PROP }

function pv(w, v) {
	if (v == "") return "(bool)" C_RST
	return v C_RST
}

function elide(v) {
	if (width > 0 && length(v) > width)
		return substr(v, 1, width) ELLIPSIS
	return v
}

function report_unresolved(   j, id) {
	if (n_unres == 0) return
	printf "\n%s%s%s\n", C_WARN, "unresolved fragments (label/path not defined in this input):", C_RST
	for (j = 1; j <= n_unres; j++) {
		id = Unres[j]
		printf "%s%s%s", C_DIM, G_ELL, C_RST
		printf "%s%s%s", C_NODE, nname[id], C_RST
		emit_props(id, G_GAP)
		printf "  %s(%d child node%s)%s\n", C_DIM, nnc[id],
		    (nnc[id] == 1 ? "" : "s"), C_RST
	}
}

function print_stats() {
	count_live(ROOT)
	printf "\n%s-- %d nodes, max depth %d, %d properties, %d directive(s), %d deleted node(s), %d unresolved fragment(s)%s\n",
	    C_DIM, S_live, S_maxd, n_props, n_directives, n_deleted, n_unres + 0, C_RST
	if (follow)
		printf "%s-- includes: %d file(s) read, %d repeat(s) skipped, %d header(s) skipped, %d not found%s\n",
		    C_DIM, n_incfiles, n_incdup, n_incskipped, n_incmissing, C_RST
	if (n_badopen || n_badclose)
		printf "%s-- parse anomalies: %d bad node header(s), %d stray brace(s)%s\n",
		    C_WARN, n_badopen, n_badclose, C_RST
}

function count_live(root,   n, cur, d, j) {
	n = 1; CLid[1] = root; CLd[1] = 0
	S_live = 0; S_maxd = 0
	while (n > 0) {
		cur = CLid[n]; d = CLd[n]; n--
		if (ndel[cur]) continue
		S_live++
		if (d > S_maxd) S_maxd = d
		for (j = 1; j <= nnc[cur]; j++) {
			n++; CLid[n] = nchild[cur, j]; CLd[n] = d + 1
		}
	}
}

# ======================================================================
# Helpers
# ======================================================================

function trim(s) {
	sub(/^[ \t\r\n]+/, "", s)
	sub(/[ \t\r\n]+$/, "", s)
	return s
}

function warn(m) {
	if (!quiet)
		printf "dt_vis: %s:%d: warning: %s\n",
		    basename_of(curfile), curline, m > "/dev/stderr"
}
