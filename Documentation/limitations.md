# Limitations

Known and deliberate. If something here bites you, the `.dtb` back-end is
usually the answer — it goes through `dtc`, so all of the DTS-source
limitations disappear.

## DTS source parsing

**The C preprocessor is not run** — `#include` is the one directive acted
on, and only with `-i`. Everything else is recognised and skipped, with
backslash continuations followed, but nothing is expanded.

* Without `-i`, `#include`d nodes do not appear, and a fragment patching
  `&pmic_glink` where `pmic_glink:` lives in an included file shows up under
  "unresolved fragments". With `-i` it resolves.
* Even with `-i`, an include reached only through a macro
  (`#include MACRO_NAME`) or guarded by an `#if` that would be false is not
  handled: there is no macro table and no configuration to evaluate.
* Both arms of an `#ifdef` are shown. There is no configuration to
  evaluate against, so the tool shows the file as written. With `-i` this
  extends to includes: *both* arms' includes are followed.
* Include *guards* work only by accident. `dt_vis` skips a file it has
  already read, which gives the same result as a real guard for a DAG. A
  file that is legitimately meant to be included twice with different macros
  defined is read once.
* Macros in property values are printed literally
  (`interrupts = <GIC_SPI 353 IRQ_TYPE_LEVEL_HIGH>`). For a *structure*
  view that is arguably the more useful rendering, but it is not the value
  the kernel sees.
* Macros in node *names* are not expanded either. Rare in practice.

**Include nesting is capped at 100 levels** and each open file costs a file
descriptor, so a pathological chain is refused with a warning rather than
exhausting the process's fd limit. Real trees nest about five deep.

**`//` inside a path reference is eaten.** `&{/a//b}` loses everything from
the `//` onward, because comment stripping runs before the scanner. `//` is
not legal in a device tree path, so this only affects already-invalid input.

**Char literals.** `'A'` in a cell array is passed through as text rather
than parsed. Only `"` opens a string for the lexer. Harmless unless a char
literal contains `;`, `{` or `}`, which would need `'\;'` — not valid DTS.

**Multi-line string literals** are tolerated by the lexer (string state
persists across lines) but are not valid DTS.

## FDT (`/proc/device-tree`) back-end

**Property types are guessed, not known.** The kernel stores raw bytes with
no type tag. `lib/fdtval.awk` uses exactly the same heuristic as `dtc`
(printable + NUL-terminated + no empty component ⇒ string; multiple of 4 ⇒
cells; else bytes), so its output matches `dtc -I dtb -O dts`. It is still a
guess: a four-byte cell whose bytes happen to spell `abc\0` renders as a
string. `dtc` has the same ambiguity.

**Children are listed alphabetically**, not in device tree order, because
the walker uses a shell glob. The `.dts` and `.dtb` back-ends preserve
source order. If ordering matters to you (it does for `reg` conflicts and
probe order), use the blob.

**Values are only decoded for requested properties.** Properties outside
`-c`/`-p` are recorded as name-only. This is a deliberate performance
trade-off — see `design-decisions.md` §10 — and is invisible unless you
were expecting `--stats` to distinguish boolean from valued properties,
which it does not.

**No labels.** A device tree filesystem does not carry DTS labels, so `-L`
is a no-op there. Same for a `.dtb` unless it was compiled with `dtc -@`.

## Compiled `.dtb` back-end

**Requires `dtc`.** Without it you get a clear error, not a wrong answer.

**Labels are absent** unless the blob was built with `-@` (symbols).

**Multi-string values render as `dtc` renders them**, i.e.
`"arm,pl011\0arm,primecell"` rather than `"arm,pl011", "arm,primecell"` —
that is `dtc`'s output, passed through unchanged. The FDT back-end, which
decodes the bytes itself, uses the comma form.

## Engine

**No branch coverage.** See `testing.md`. 100% statement coverage does not
mean every path was taken.

**`merge_node()` is recursive.** Its depth is the depth of a *fragment*
subtree. Under mawk (1024-slot evaluation stack) a fragment nested deeper
than roughly 90 levels would abort. No real device tree comes close; the
renderer, which does have to handle arbitrary depth, is iterative.

**Memory is proportional to the tree.** The whole node model is held in awk
arrays. A 20 000-node tree is fine; the practical ceiling is the awk
implementation's array performance, not this code.

**No path filtering / regex search.** `-d` and `-p` are the only ways to
narrow the output; anything more specific is a job for `grep`. A `--match`
option that shows matching nodes plus their ancestors would be a reasonable
addition and is not implemented.

**`/omit-if-no-ref/` nodes are always shown.** The prefix is stripped from
the node header and counted as a directive, but whether `dtc` would actually
drop the node depends on phandle references across the whole (possibly
`#include`d) tree, which a text parser cannot resolve.

**Overlay syntax (`/plugin/`, `fragment@N` + `__overlay__`)** is parsed
structurally — you will see the `fragment@0/__overlay__` nodes as they are
written, not applied to a base tree. Applying an overlay needs `fdtoverlay`;
run that first and point `dt_vis` at the result.
