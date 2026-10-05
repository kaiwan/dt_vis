# dt_vis

Credit: Claude Opus

Show the *shape* of a device tree without drowning in properties.

```
$ dt_vis.sh -d 1 -c arch/arm64/boot/dts/qcom/sm8750.dtsi
sm8750.dtsi
/  "qcom,sm8750"
├── cpus  …8
├── firmware  …1
├── memory@a0000000
├── resmem: reserved-memory  …6
├── soc: soc@0  …214  "simple-bus"
├── timer  "arm,armv8-timer"
└── thermal-zones  …17
```

`-d N` limits how deep the tree is printed; nodes cut off by the limit are
tagged with the number of children hidden (`soc: soc@0  …214`). `-c` appends
each node's `compatible`; `-p reg,status,…` appends anything else.

## Following includes

By default you see the file **as written**: `#include`d nodes are absent, and
a `&label { }` fragment whose label lives in an included file is listed under
"unresolved fragments" rather than dropped. `-i` changes that:

```
$ dt_vis.sh -i --origin -d 2 -c sm8750-mtp.dts
sm8750-mtp.dts
/  [sm8750-mtp.dts +1]  "qcom,sm8750-mtp"
├── cpus  [sm8750.dtsi]  …8
├── soc: soc@0  [sm8750.dtsi +1]  …214  "simple-bus"
└── pmics  [pm8550.dtsi]  …4
```

`--origin` tags each node with the file that declared it; `+1` means one
further file also set properties or added children there — which is exactly
the SoC-`.dtsi`-patched-by-board-`.dts` pattern.

Search paths follow the kernel's own convention: quoted includes resolve
relative to the including file, and `<angle>` includes are looked up in
`scripts/dtc/include-prefixes`, auto-detected by walking up from the input
(`--no-auto-include` turns that off; `-I DIR` adds paths by hand). C headers
are skipped — dt-bindings hold macros, not nodes.

## Three inputs, one renderer

| Input | How it is read |
|---|---|
| `.dts` / `.dtsi` **source** | parsed directly as text — no kernel build, no `#include` resolution needed |
| compiled **`.dtb`** / FDT blob | decompiled with `dtc -I dtb -O dts`, then parsed |
| live **`/proc/device-tree`** | directory walk, property values decoded like `dtc` does |

The type is detected automatically: a directory means FDT filesystem, the
`0xd00dfeed` magic means a blob, anything else is source. `-` or no argument
reads stdin (buffered, so `cat board.dtb | dt_vis.sh` works too).

## Install

```sh
git clone <this repo> ~/src/dt_vis
ln -s ~/src/dt_vis/dt_vis.sh ~/bin/dt_vis      # symlinks are resolved
```

Requirements: `bash` 4+, any POSIX `awk` (mawk, gawk, busybox awk, onetrue),
`od`. `dtc` is needed only for `.dtb` input. No build step.

## Common recipes

```sh
# what hangs off / ?
dt_vis.sh -d 1 board.dtsi

# CPU topology with compatibles
dt_vis.sh -d 3 -c board.dtsi

# which peripherals are enabled on the running board?
dt_vis.sh -d all -p status,reg /proc/device-tree

# how big is this thing, really?
dt_vis.sh -d 0 -s board.dtsi

# feed it a blob straight out of a build
dt_vis.sh -d 2 -c arch/arm64/boot/dts/qcom/sm8750-mtp.dtb

# the whole board as the kernel will see it, minus macro expansion
dt_vis.sh -i -d 2 -c arch/arm64/boot/dts/qcom/sm8750-mtp.dts
```

`dt_vis.sh --help` has the full option list.

## Layout

```
dt_vis.sh              front-end: options, input detection, fdt walker
lib/dts2tree.awk       the parser and renderer (POSIX awk)
lib/fdtval.awk         FDT property value type heuristic
tests/                 bats suite + fixtures
tools/coverage.sh      coverage harness (stats + HTML)
Documentation/         design, architecture, usage, testing, limitations,
                       threat model (system model / DFD for STRIDE)
```

## Testing

```sh
tests/run_tests.sh              # static analysis + suite + coverage
tests/run_tests.sh --no-coverage
```

160 tests, run against every awk implementation on the machine.
100% statement coverage of `dt_vis.sh`, `lib/dts2tree.awk` and
`lib/fdtval.awk` — see `Documentation/testing.md` for how that is measured
and what the number does and does not mean.

## Licence

MIT.
