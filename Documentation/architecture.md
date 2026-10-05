# Architecture

## The shape of the thing

```
                 ┌───────────────────────────────────────────┐
   .dts/.dtsi ──►│                                           │
                 │                                           │
   .dtb ───► dtc │            DTS text stream                │──► lib/dts2tree.awk
   (-I dtb -O dts)                                           │        │
                 │                                           │        │
   /proc/  ─► fdt_walk() ────────────────────────────────────┘        │
   device-tree      │                                                 │
                    └─► lib/fdtval.awk  (property value decoding)     │
                                                                      ▼
                                                          node model ──► tree
```

Everything converges on one intermediate representation: **DTS text**. The
three back-ends differ only in how they produce it. That is the single
design decision the whole program hangs off — one parser, one renderer, one
set of semantics, three adapters. Adding a fourth source (a `dtbo` overlay,
a `dtc -O yaml` dump, whatever) means writing an adapter, not touching the
engine.

The analogy is a compiler front-end: `dtc`, the FDT walker and the raw
source are three lexers feeding a common AST, and the renderer is the only
back-end.

## Front-end: `dt_vis.sh`

Responsibilities, in order:

1. **Option parsing.** Hand-rolled `while`/`case` (not `getopts`) because
   long options with `=` are wanted and `getopts` does not do them.
2. **Input type detection.** Directory ⇒ `fdt`. Otherwise sniff the first
   four bytes: `d0 0d fe ed` ⇒ `dtb`, else `dts`. `--type` overrides.
   stdin is buffered to a temp file first so the magic number is seekable —
   without that, `cat board.dtb | dt_vis.sh` could not work.
3. **FDT walker.** A recursive `for e in "$d"/*` that emits DTS text:
   directories become `name { … };`, files become `name = value;`.
4. **Invoking the engine** with the option set as `-v` assignments.

The walker only decodes property *values* for properties the user actually
asked to see (`-c` / `-p`). Everything else is emitted as a bare
`name;`. On a real board that is the difference between a handful of
`od` processes and several thousand — the tree structure is what costs
nothing, and the values are what cost a fork each.

## Engine: `lib/dts2tree.awk`

Three layers, cleanly separated, in the classic order:

### 1. Lexical — `strip_comments()` + `scan()`

`strip_comments()` walks the line character by character with two pieces of
state that persist *across* lines: `in_comment` (inside `/* */`) and
`l_in_str` (inside a string literal). That is what makes

```dts
weird-string = "brace { and ; and /* not a comment */ inside";
```

parse correctly. A line-oriented `sed 's|/\*.*\*/||'` cannot do this; a
character scanner with two flags can, in about twenty lines.

C preprocessor lines are dropped *before* comment stripping, with
backslash-continuation tracked so a multi-line `#define` is skipped whole.
The regex deliberately lists the actual directive keywords rather than
matching `^#`, because `#address-cells` is a property, not a directive —
that one character of ambiguity is the single nastiest gotcha in DTS
lexing.

`scan()` then splits the cleaned stream into three events, quote-aware so
`;`, `{` and `}` inside strings are inert:

| character | event |
|---|---|
| `{` | `on_open(text-before-it)` — a node header |
| `}` | `on_close()` |
| `;` | `on_stmt(text-before-it)` — a property or a `/directive/` |

`&{/path/to/node}` is the one wrinkle: its braces are not a node body, so
the scanner switches to a pass-through mode when it sees `{` immediately
after `&`.

#### Includes

With `follow=1`, a `#include` line (or an `/include/ "..."` statement) pushes
the resolved path onto an explicit **file stack**; `drain_includes()` then
reads from the top of that stack until it is empty. Nothing recurses:
`process_line` → `do_include` → `push_include` returns immediately, and the
drain loop picks the new file up on its next iteration. Recursion depth is
therefore constant however deep the include chain goes — the same mawk
1024-slot constraint that forced the renderer to be iterative.

Each slot carries its own lexer state (comment flag, string flag, statement
buffer), so an unterminated comment cannot leak out of an include. The
*node* stack is deliberately shared, because `/include/` is legal inside a
node body and must keep building that node.

One subtlety worth stating: the includer's state is snapshotted in
`drain_includes()`, not in `push_include()`. `/include/ "x";` is pushed from
inside `on_stmt()`, while the scanner still holds that very statement in
`buf` — snapshotting there would restore the consumed directive text
afterwards and glue it onto the next node header. (It did, once.)

### 2. Syntactic — `on_open` / `on_close` / `on_stmt`

A node stack (`stk[]`, `sp`) tracks where we are. `on_open` peels off any
number of `label:` prefixes, then finds-or-creates the node under the
current parent. **Find**-or-create is what makes multiple `/ { }` blocks
merge instead of duplicating: identity is `(parent, name)`, held in
`cidx[]`.

`on_stmt` splits on the first `=`; no `=` means a boolean property.
`/delete-node/` and `/delete-property/` are handled, everything else
(`/dts-v1/`, `/include/`, `/memreserve/`) is counted and ignored.

### 3. Model and resolution

Parallel arrays keyed by integer node id — POSIX awk has no structs, so:

```
nname[id]      node name, unit address included
nparent[id]    parent id (0 for the virtual container)
nchild[id,k]   k'th child id      nnc[id]   child count
nprop[id,name] property value     npn[id,j] j'th property name
nlabels[id]    comma-joined labels
ndel[id]       deleted by /delete-node/
cidx[p,name]   (parent,name) -> id
labelmap[lbl]  label -> id
```

Node 0 is a virtual container: `/` is `cidx[0,"/"]` and every `&label { }`
or `&{/path} { }` block becomes another child of 0. Fragments are therefore
parsed as ordinary subtrees hanging off nothing, and resolved in `END`:

* `&label` → `labelmap[label]`, then `merge_node(fragment, target)`
* `&{/path}` → `lookup_path()`, then the same merge
* neither → reported under "unresolved fragments"

`merge_node()` copies properties (later text wins, which matches DTS
semantics) and recurses into children with find-or-create, so a fragment's
children land exactly where they belong. It also re-points `labelmap`
entries at the merged node, which is what lets a fragment reference a label
that was itself defined inside another fragment.

Resolving in `END` rather than inline means forward references work: a
`&foo { }` block may appear before `foo:` is defined.

### 4. Rendering

Depth-first pre-order with an **explicit stack**, not recursion. This is not
stylistic: mawk has a fixed 1024-slot evaluation stack and a recursive
renderer dies with `program limit exceeded` at roughly 90 levels of nesting,
part-way through the output. A visualiser that silently truncates itself is
worse than one that refuses. `mark_deleted()` and `count_live()` are
iterative for the same reason. `merge_node()` is still recursive — its depth
is the depth of a *fragment*, which is one or two levels in practice.

Children are pushed in reverse so they pop in source order.

## `lib/fdtval.awk`

The kernel exposes properties in `/proc/device-tree` as raw bytes with no
type information, so the type has to be guessed. This is the same guess
`dtc` makes, and it is reproduced exactly (`util_is_printable_string`):

1. NUL-terminated, every byte printable, **no zero-length component** ⇒
   string list
2. length a multiple of 4 ⇒ cells, `<0x… 0x…>`
3. otherwise ⇒ byte string, `[de ad be ef]`

The "no empty component" clause is the whole trick. `reg = <0x40000000
0x20000000>` is the bytes `40 00 00 00 20 00 00 00` — `@`, NUL, NUL, NUL,
space, NUL, NUL, NUL. Printable, NUL-terminated: a naive check calls it the
string `"@"`. The empty-component rule rejects it and it decodes as cells,
matching `dtc` byte for byte.

## Portability

The engine is POSIX awk only — no `gensub`, no `asort`, no `length(array)`,
no regex `RS`, no `delete array` — so it runs under mawk, gawk, busybox awk
and the one-true-awk. `tests/run_tests.sh` runs the whole suite once per awk
implementation it finds on the machine. That matters because the intended
home for this tool is a board's rootfs, where `awk` is busybox.
