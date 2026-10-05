# Usage

```
dt_vis.sh [OPTION]... [FILE|DIR|-]
```

`FILE` may be DTS/DTSI source, a compiled `.dtb`, or `-` (stdin, the
default). `DIR` is a device-tree filesystem root such as
`/proc/device-tree` or `/sys/firmware/devicetree/base`.

## Options

### Depth

| Option | Meaning |
|---|---|
| `-d N`, `--depth N` | show `N` levels below the root. Default **1**. |
| `-d 0` | the root node only |
| `-d all`, `-d -1` | no limit |

Depth is counted from `/` = 0. So `-d 1` prints `/` and its direct
children; `-d 2` adds grandchildren. Any node whose children are cut off is
tagged with how many were hidden:

```
├── soc: soc@0  …214
```

That number is the count of *direct* live children, after `/delete-node/`
has been applied.

### Includes (DTS source input only)

| Option | Meaning |
|---|---|
| `-i`, `--follow-includes` | descend into `#include "..."`, `#include <...>` and `/include/ "..."` |
| `-I DIR`, `--include-path DIR` | add `DIR` to the search path for `<angle>` includes; repeatable |
| `--no-auto-include` | do not auto-detect the kernel tree |
| `--origin` | tag each node with the file that declared it |

Without `-i` you see the file **as written**. Nodes from included files are
absent, and a `&label { }` fragment whose label is declared in an include ends
up in the "unresolved fragments" section. With `-i` the includes are parsed
and merged, so those fragments land where they belong.

**Resolution order** matches the C preprocessor and `dtc`:

1. `"quoted"` includes: the directory of the *including* file, first.
2. Then every `-I` directory, in the order given.
3. Then, for quoted includes only, the directory of the primary input.

`<angle>` includes skip step 1.

**Auto-detection.** With `-i`, `dt_vis` walks up from the input file looking
for `scripts/dtc/include-prefixes` — the directory the kernel build itself
passes to `dtc`, whose entries symlink to `include/dt-bindings` and
`arch/*/boot/dts`. Finding it resolves every `<angle>` include a kernel tree
uses, with no `-I` needed. The tree's `include/` is added too.
`--no-auto-include` disables this; explicit `-I` paths are always searched
before auto-detected ones.

**What is not followed.** Anything whose name does not end in `.dts` or
`.dtsi`. `<dt-bindings/...>` headers hold `#define`s, not nodes, so following
them would cost I/O and produce nothing — and skipping them by name means no
"cannot find" warning when you have not passed a header search path.
`--stats` counts them separately.

A file included twice is read once (device tree include graphs are DAGs and
re-reading merges to the same result); that also makes an accidental cycle
terminate. Nesting is capped at 100 levels.

**`--origin` output:**

```
├── soc: soc@0  [sm8750.dtsi +1]  "simple-bus"
             │   │                 └ the -c property
             │   └ declared in sm8750.dtsi; 1 other file also
             │     set properties on it or added children to it
             └ label
```

Only the basename is shown. `--origin` works without `-i` too — it then names
the single input file for every node, which is not very interesting.

### Properties

| Option | Meaning |
|---|---|
| `-c`, `--compatible` | show `compatible` (exactly `-p compatible`) |
| `-p LIST`, `--props LIST` | show these comma-separated properties |
| `-w N`, `--width N` | elide values longer than `N` characters; `0` = never. Default **48**. |
| `-b`, `--block` | one property per line instead of appended inline |

`-c` and `-p` accumulate and de-duplicate, so `-c -p compatible,status`
requests two properties, not three.

**Display rule.** With exactly one property requested the value is printed
bare (the name would be noise on every line); with two or more each is
printed as `name=value`:

```
$ dt_vis.sh -d 1 -c board.dts
└── soc  "simple-bus"

$ dt_vis.sh -d 1 -p compatible,status board.dts
└── soc  compatible="simple-bus"  status="okay"
```

`-b` always prints the name:

```
└── soc
    + compatible = "simple-bus"
```

A boolean (valueless) property renders as `(bool)`.

### Presentation

| Option | Meaning |
|---|---|
| `-a`, `--ascii` | `\|--` instead of `├──`, for terminals or pipes that mangle UTF-8 |
| `-C WHEN`, `--color WHEN` | `always`, `never` or `auto`. Default **auto** = colour only when stdout is a tty. |
| `-L`, `--no-labels` | hide DTS labels, i.e. `cpu@0` rather than `cpu0: cpu@0` |
| `-s`, `--stats` | append a summary footer |

### Other

| Option | Meaning |
|---|---|
| `-t TYPE`, `--type TYPE` | force `dts`, `dtb`, `fdt` or `auto`. Default **auto**. |
| `-q`, `--quiet` | suppress parser warnings on stderr |
| `-h`, `--help` / `-V`, `--version` | |

All long options also accept the `--opt=value` form.

## Environment

| Variable | Effect |
|---|---|
| `DT_VIS_AWK` | awk implementation to use. Default `awk`. |
| `DT_VIS_LIBDIR` | where to find `dts2tree.awk` / `fdtval.awk`. Default: `lib/` beside the script (symlinks resolved). |

`-i` is meaningful only for DTS source. For a `.dtb`, `dtc` has already
resolved the includes; a device-tree filesystem has no such notion. In both
cases `-i` is ignored with a note on stderr (silenced by `-q`).

## Exit status

| Status | Meaning |
|---|---|
| 0 | tree produced (possibly with parser warnings) |
| 2 | usage error, unreadable input, missing `dtc` for a `.dtb` |
| other | propagated from a failing `dtc` |

Malformed DTS is **not** an error — fragments are routinely incomplete.
Anomalies are warned about on stderr and counted by `--stats`.

## Reading the output

```
sm8750.dtsi                          ← the input's name
/  "qcom,sm8750"                     ← root, with the requested property
├── cpus  …8                         ← 8 children hidden by the depth limit
├── resmem: reserved-memory          ← "resmem:" is the DTS label
└── soc: soc@0  …214  "simple-bus"

unresolved fragments (label/path not defined in this input):
└── &pmic_glink  (0 child nodes)     ← the label lives in an #include

-- 23 nodes, max depth 4, 73 properties, 3 directive(s), 1 deleted node(s),
   1 unresolved fragment(s)
```

The **unresolved fragments** section is not an error. A `.dtsi` routinely
patches nodes defined in files it includes; without `-i` those labels are
invisible, so the fragments are shown separately rather than dropped. Three
ways to make them go away, in increasing order of fidelity: pass `-i` so the
includes are parsed; feed the compiled `.dtb`, which `dtc` has already
flattened; or accept that a `.dtsi` on its own genuinely is an incomplete
tree.

## Recipes

```sh
# orientation: what is under / ?
dt_vis.sh -d 1 sm8750.dtsi

# the SoC bus, one level, with compatibles -- the usual "which driver?" question
dt_vis.sh -d 1 -c sm8750.dtsi | grep -A99 'soc@0'

# CPU topology
dt_vis.sh -d 3 -c sm8750.dtsi

# what is actually enabled on the running board?
dt_vis.sh -d all -p status /proc/device-tree | grep -v 'disabled'

# addresses and enablement together
dt_vis.sh -d 2 -p reg,status -w 0 /proc/device-tree

# resolve the fragments: parse the includes too
dt_vis.sh -i -d 1 -c sm8750-mtp.dts

# where is each node actually declared?
dt_vis.sh -i --origin -d 2 sm8750-mtp.dts

# out-of-tree dtsi that includes kernel headers
dt_vis.sh -i -I ~/src/linux/scripts/dtc/include-prefixes -d 1 my-board.dts

# compare a source file against what it compiles to
dt_vis.sh -d all -L board.dts   > /tmp/src.txt
dt_vis.sh -d all -L board.dtb   > /tmp/blob.txt
diff -u /tmp/src.txt /tmp/blob.txt

# size and depth of a tree, nothing else
dt_vis.sh -d 0 -s sm8750.dtsi

# from a pipe
dtc -I dtb -O dts -q board.dtb | dt_vis.sh -d 2 -c
cat board.dtb | dt_vis.sh -d 1

# on a board where awk is busybox
DT_VIS_AWK=busybox\ awk dt_vis.sh -d 2 /proc/device-tree
```
