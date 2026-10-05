# Design decisions

Each entry: what was decided, what the alternatives were, and why.

---

## 1. Parse DTS source as text rather than shelling out to `dtc`

**Decision.** `.dts`/`.dtsi` input is parsed directly by a character
scanner in awk.

**Alternative.** `cpp -nostdinc -I include -I arch/arm64/boot/dts … | dtc -I
dts -O dts` and parse the fully-flattened result.

**Why.** The `dtc` route is *more correct* — it resolves `#include`,
expands macros, applies overrides, and produces the tree the kernel will
actually see. It is also useless for the stated job. You reach for this tool
while reading `sm8750.dtsi` in an editor, wanting to know what is under `/`.
At that moment you may not have the kernel tree configured, the include
paths right, or the file in a compilable state at all. A text parser works
on any snippet, any fragment, any half-edited file.

**Consequence.** What you see is the file *as written*, not the final tree.
`#include`d nodes are absent, `#if` branches are both present, macros are
opaque. That is a real limitation and it is documented in
`limitations.md`. Users who want the flattened truth have the `.dtb`
back-end, which *does* go through `dtc`.

---

## 2. One intermediate representation: DTS text

**Decision.** All three back-ends emit DTS text; only `lib/dts2tree.awk`
understands the device tree model.

**Alternative.** A back-end-specific model builder for each source, sharing
only the renderer.

**Why.** The renderer is small; the *semantics* (node identity, fragment
merging, deletion, depth cutoff, property selection) are the expensive part,
and duplicating them three ways is how the three back-ends drift apart. It
also makes the FDT walker trivially testable: it is a pure
directory-to-text function, diffable against `dtc`'s own output.

**Cost.** The FDT walker re-encodes binary property values into DTS syntax
which the parser then re-parses — a round trip that a direct model builder
would skip. Measured against a 3000-node `/proc/device-tree` this is
noise next to the `od` forks, and those are already avoided for
properties nobody asked to see.

---

## 3. Merge `&label { }` fragments instead of listing them separately

**Decision.** Fragments are resolved against labels/paths defined in the
same input and merged into the tree. Unresolvable ones are printed in a
separate "unresolved fragments" section.

**Alternative (considered and rejected).** Print every top-level block
separately, closest to the file's literal structure.

**Why.** Half of a modern SoC `.dtsi` is fragments — `&soc { … }`,
`&i2c0 { status = "okay"; }`. Showing them as free-floating blocks
reproduces exactly the confusion the tool exists to remove. Merging shows
where the nodes actually end up.

**Why the unresolved section still exists.** A fragment may reference a
label defined in an `#include`d file we cannot see (`&pmic_glink` is a real
example from `sm8750.dtsi`). Silently dropping those would be a lie about
the file's contents. They are shown, flagged, and counted.

---

## 4. Resolve fragments in `END`, not inline

**Decision.** Fragments are parsed as subtrees of a virtual node 0 and
merged after the whole input has been read.

**Why.** Forward references. `&foo { }` may precede `foo: bar { }`. An
inline resolver would have to defer anyway; deferring everything is simpler
and has no special cases. It also makes chained fragments work — a fragment
targeting a label defined *inside another fragment* resolves correctly
because `merge_node()` re-points `labelmap` as it goes.

---

## 5. Include following is opt-in, and merges everything

**Decision.** `-i` follows `#include`/`/include/` and merges the result into
one tree. Off by default. `--origin` tags each node with the file that
declared it.

**Alternatives.** (a) On by default. (b) "Resolve-only": parse includes just
to build a label→path map, then place the primary file's fragments correctly
without showing the includes' other content.

**Why opt-in.** The default answer to "what is in this file" should be *this
file*. Following includes needs the surrounding tree to exist on disk and in
the expected layout; making that the default means the output silently
depends on where you ran the command from, which is a bad property for
something you diff. It also keeps the zero-dependency, works-on-a-fragment
behaviour that makes the tool usable on a snippet pasted into `/tmp`.

**Why full merge rather than resolve-only.** Resolve-only produces a tree
that no real device tree matches: the fragment's target node appears, but its
siblings and the properties it was patching do not. That is a more confusing
artefact than either honest answer. If the reader wants the file's own
contribution highlighted, `--origin` gives it without inventing a tree.

**Why the search path auto-detects.** `scripts/dtc/include-prefixes` is the
one directory the kernel build passes to `dtc`, and its entries symlink to
`include/dt-bindings` and `arch/*/boot/dts`. Walking up to find it turns
`-i` into something that just works inside a kernel tree, which is where this
tool is used. `--no-auto-include` exists so the behaviour can be made
explicit and reproducible when that matters.

**Why headers are skipped by extension.** `<dt-bindings/...>` are pure
`#define`; following them costs I/O and yields no nodes. Skipping on the
*spec* rather than after resolution also means no "cannot find" warning when
no header search path was passed — which would otherwise be the common case
and would train users to ignore warnings.

---

## 6. Bash + awk, not Python

**Decision.** POSIX awk engine, bash front-end.

**Alternative.** Python 3, which would make the parser more readable and
coverage tooling trivial (`coverage.py`).

**Why.** Chosen by the user, and defensible: the natural home for this tool
is a board's rootfs and a kernel developer's `~/bin`, where `awk` is present
and Python may not be. Zero dependencies, zero install step.

**Cost, paid honestly.** Awk has no structs, so the node model is nine
parallel arrays keyed by integer id. Awk has no local variables, so locals
are declared as extra function parameters. And coverage needed a purpose-built
harness (see `testing.md`). The code is commented accordingly.

---

## 7. Iterative tree walk, not recursion

**Decision.** `render()`, `mark_deleted()` and `count_live()` use explicit
stacks.

**Decision (cont.).** The include reader uses an explicit file stack too.

**Why.** mawk's evaluation stack is a fixed 1024 slots. A recursive
renderer dies at ~90 levels of nesting with `mawk: program limit exceeded`
— *after* emitting most of the tree, so the user gets a plausible-looking
but truncated answer. That failure mode is unacceptable in a tool whose only
job is to show you the whole shape. gawk handles the recursion fine, which
is exactly why the bug would have shipped: it only appears on the awk that
Debian/Ubuntu install by default. The include reader hit the identical wall
at around 40 levels of nesting once `-i` existed, and was rewritten the same
way — the recursion depth is now constant no matter how deep the chain.

**Where recursion remains.** `merge_node()`, whose depth is the depth of a
fragment subtree — one or two levels in every real device tree. Documented
in `limitations.md`.

---

## 8. Depth cutoff shows a child count inline

**Decision.** `soc: soc@0  …214` rather than a separate `… 214 more nodes
below` line.

**Why.** The count is the most useful single number when you are deciding
where to look next, and putting it on the node's own line keeps the output
one-line-per-node, which is what makes it greppable and scannable. A
separate line per cut-off node roughly doubles the output of `-d 1` on a
large SoC.

---

## 9. Inline property values, with names only when ambiguous

**Decision.** `-c` prints bare values (`├── timer  "arm,armv8-timer"`);
two or more requested properties print `name=value`
(`reg=<0x0 0x17100000 …>  status="okay"`). `-b` forces one per line.

**Why.** The overwhelmingly common case is `-c`, where the property name
would be pure noise on every line. As soon as there is more than one, the
names carry information. The rule is mechanical and stated in `--help`.

---

## 10. `dt_vis.sh` writes diagnostics to stderr, tree to stdout

**Decision.** Parser warnings ("stray `}`", "unbalanced braces") go to
stderr; `-q` silences them. Exit status is 0 for any parseable input, 2 for
usage/IO errors.

**Why.** `dt_vis.sh -d 1 x.dtsi | grep i2c` must work, and a warning about
a stray brace must not end up in the pipe. Malformed input is not a failure
— DTS fragments are routinely incomplete — so it does not change the exit
status, only the warning stream and the `--stats` anomaly counters.

---

## 11. Property values are only decoded when requested (FDT back-end)

**Decision.** `fdt_walk()` emits `name;` for properties outside `-c`/`-p`,
and only forks `od` for the ones asked for.

**Why.** Structure is free; values cost a process each. A Qualcomm board's
`/proc/device-tree` has on the order of 10⁴ property files. Decoding all of
them to print none of them would take seconds and produce nothing.

**Consequence.** `--stats` counts every property but `-p` can only show
requested ones — which is exactly what `-p` means, so there is no surprise.
