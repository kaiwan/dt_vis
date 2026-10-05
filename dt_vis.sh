#!/usr/bin/env bash
#
# dt_vis - show the shape of a device tree without drowning in the details.
#
# Renders a depth-limited tree from any of three sources:
#   * DTS/DTSI source text     (parsed directly; no kernel build needed)
#   * a compiled .dtb / FDT    (decompiled with dtc, then parsed)
#   * a live /proc/device-tree (walked directly)
#
# Author: kaiwan
# SPDX-License-Identifier: GPL-2.0-or-later
#
# See Documentation/ for design, architecture, testing and known limitations.

set -o errexit
set -o nounset
set -o pipefail
IFS=$' \t\n'
export LC_ALL=C

readonly PROGNAME=${0##*/}
readonly VERSION='1.0.0'

# Resolve our own directory so lib/*.awk is found whether run from the repo,
# from $PATH, or through a symlink.
_self=${BASH_SOURCE[0]}
while [[ -L $_self ]]; do
	_dir=$(cd -P -- "$(dirname -- "$_self")" && pwd)
	_self=$(readlink -- "$_self")
	[[ $_self == /* ]] || _self=$_dir/$_self
done
SCRIPT_DIR=$(cd -P -- "$(dirname -- "$_self")" && pwd)
readonly SCRIPT_DIR
unset _self _dir

LIBDIR=${DT_VIS_LIBDIR:-$SCRIPT_DIR/lib}
readonly LIBDIR

# awk implementation: any POSIX awk will do (mawk, gawk, busybox awk, onetrue).
AWK=${DT_VIS_AWK:-awk}

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
depth=1
props=''
width=48
ascii=0
color_when=auto
show_labels=1
block=0
stats=0
quiet=0
force_type=auto
infile='-'
follow=0
origin=0
incpaths=''
auto_inc=1

TMPDIR_SELF=''

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
die() { printf '%s: error: %s\n' "$PROGNAME" "$*" >&2; exit 2; }

cleanup() {
	[[ -n $TMPDIR_SELF && -d $TMPDIR_SELF ]] && rm -rf -- "$TMPDIR_SELF"
	return 0
}
trap cleanup EXIT INT TERM

usage() {
	cat <<EOF
Usage: $PROGNAME [OPTION]... [FILE|DIR|-]

Show a device tree as a depth-limited tree, so the structure is visible
without the property noise.

FILE may be DTS/DTSI source, a compiled .dtb, or "-"/omitted for stdin.
DIR is a device-tree filesystem root, e.g. /proc/device-tree or
/sys/firmware/devicetree/base.  The type is detected automatically.

Depth:
  -d, --depth N       show N levels below the root node; 0 = root only,
                      "all" (or -1) = no limit                [default: $depth]
                      Nodes cut off by the limit are marked with the
                      number of hidden children, e.g.  soc@0  ...214

Includes (DTS source input only):
  -i, --follow-includes
                      descend into #include "..." / #include <...> /
                      /include/ "..." so that nodes and labels defined in
                      included sources become part of the tree.  Without it
                      you see the file as written, and fragments targeting a
                      label from an include are listed as unresolved.
                      C headers (dt-bindings) are skipped: they hold macros,
                      not nodes.
  -I DIR, --include-path DIR
                      add DIR to the search path for <angle> includes; may be
                      repeated.  "Quoted" includes always resolve relative to
                      the including file first.
      --no-auto-include
                      do not auto-detect the kernel tree.  By default -i walks
                      up from the input file looking for
                      scripts/dtc/include-prefixes (the path the kernel build
                      itself uses) and adds it, plus the tree's include/.
      --origin        tag each node with the file that declared it, e.g.
                      [sm8750.dtsi +1] -- "+1" = one further file also
                      contributed properties or children to that node

Properties:
  -c, --compatible    show the "compatible" property (same as -p compatible)
  -p, --props LIST    show these comma-separated properties, e.g.
                      -p reg,status,clock-names
  -w, --width N       elide property values longer than N chars; 0 = never
                                                              [default: $width]
  -b, --block         one property per line instead of appended inline

Presentation:
  -a, --ascii         ASCII tree glyphs instead of box-drawing characters
  -C, --color WHEN    colourise: always | never | auto        [default: $color_when]
  -L, --no-labels     do not show DTS labels ("cpu0: cpu@0")
  -s, --stats         print a summary footer (node/property counts, depth)

Other:
  -t, --type TYPE     force input type: dts | dtb | fdt | auto [default: $force_type]
  -q, --quiet         suppress parser warnings
  -h, --help          this help
  -V, --version       version

Examples:
  # what is directly under / in an SoC dtsi?
  $PROGNAME -d 1 arch/arm64/boot/dts/qcom/sm8750.dtsi

  # the CPU topology, with each node's compatible string
  $PROGNAME -d 3 -c sm8750.dtsi

  # the whole board, includes and all, showing where each node comes from
  $PROGNAME -i --origin -d 2 -c sm8750-mtp.dts

  # everything under the running board's root, two levels, with reg+status
  $PROGNAME -d 2 -p reg,status /proc/device-tree
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
need_arg() { [[ $2 -gt 0 ]] || die "option '$1' requires an argument"; }

parse_args() {
	local a
	while (($#)); do
		a=$1
		case $a in
		-d|--depth)	need_arg "$a" $(($# - 1)); depth=$2; shift 2 ;;
		--depth=*)	depth=${a#*=}; shift ;;
		-c|--compatible)
				props="${props:+$props,}compatible"; shift ;;
		-p|--props)	need_arg "$a" $(($# - 1))
				props="${props:+$props,}$2"; shift 2 ;;
		--props=*)	props="${props:+$props,}${a#*=}"; shift ;;
		-w|--width)	need_arg "$a" $(($# - 1)); width=$2; shift 2 ;;
		--width=*)	width=${a#*=}; shift ;;
		-i|--follow-includes)
				follow=1; shift ;;
		-I|--include-path)
				need_arg "$a" $(($# - 1))
				incpaths="${incpaths:+$incpaths:}$2"; shift 2 ;;
		--include-path=*)
				incpaths="${incpaths:+$incpaths:}${a#*=}"; shift ;;
		--no-auto-include)
				auto_inc=0; shift ;;
		--origin)	origin=1; shift ;;
		-b|--block)	block=1; shift ;;
		-a|--ascii)	ascii=1; shift ;;
		-C|--color|--colour)
				need_arg "$a" $(($# - 1)); color_when=$2; shift 2 ;;
		--color=*|--colour=*)
				color_when=${a#*=}; shift ;;
		-L|--no-labels)	show_labels=0; shift ;;
		-s|--stats)	stats=1; shift ;;
		-t|--type)	need_arg "$a" $(($# - 1)); force_type=$2; shift 2 ;;
		--type=*)	force_type=${a#*=}; shift ;;
		-q|--quiet)	quiet=1; shift ;;
		-h|--help)	usage; exit 0 ;;
		-V|--version)	printf '%s %s\n' "$PROGNAME" "$VERSION"; exit 0 ;;
		--)		shift; break ;;
		-)		infile='-'; shift ;;
		-*)		die "unknown option '$a' (try --help)" ;;
		*)		infile=$a; shift ;;
		esac
	done
	(($#)) && infile=$1
	return 0
}

validate_args() {
	case $depth in
	all|ALL|max)	depth=-1 ;;
	-1)		;;
	*[!0-9]*)	die "--depth must be a non-negative integer, -1, or 'all' (got '$depth')" ;;
	esac
	[[ $width == *[!0-9]* ]] && die "--width must be a non-negative integer (got '$width')"
	case $color_when in
	always|never|auto) ;;
	*) die "--color must be always, never or auto (got '$color_when')" ;;
	esac
	case $force_type in
	auto|dts|dtb|fdt) ;;
	*) die "--type must be auto, dts, dtb or fdt (got '$force_type')" ;;
	esac
	return 0
}

want_color() {
	case $color_when in
	always) return 0 ;;
	never)  return 1 ;;
	*)      [[ -t 1 ]] ;;
	esac
}

# ---------------------------------------------------------------------------
# input type detection
# ---------------------------------------------------------------------------

# Walk up from $1 looking for the include roots a kernel tree provides.
# The kernel builds DTS with -I$(srctree)/scripts/dtc/include-prefixes, whose
# entries are symlinks to include/dt-bindings and arch/*/boot/dts -- so
# finding that one directory resolves every <angle> include the tree uses.
detect_kernel_includes() {
	local d
	d=$(cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd) || return 0
	while [[ -n $d && $d != / ]]; do
		if [[ -d $d/scripts/dtc/include-prefixes ]]; then
			printf '%s\n' "$d/scripts/dtc/include-prefixes"
			[[ -d $d/include ]] && printf '%s\n' "$d/include"
			return 0
		fi
		d=$(dirname -- "$d")
	done
	return 0
}

# Prints dts|dtb|fdt for $1 (a regular file).
detect_file_type() {
	local f=$1 magic
	magic=$(od -An -tx1 -N4 -- "$f" 2>/dev/null | tr -d ' \n' || true)
	if [[ $magic == d00dfeed ]]; then printf 'dtb\n'; else printf 'dts\n'; fi
}

# ---------------------------------------------------------------------------
# backend: device-tree filesystem (/proc/device-tree) -> DTS text
# ---------------------------------------------------------------------------

# Is this property one the user asked to see?  Values are only decoded for
# wanted properties -- decoding every property on a real board would mean
# thousands of extra processes for output nobody looks at.
_want_pat=''
fdt_wanted() {
	[[ -n $_want_pat ]] || return 1
	case "|$_want_pat|" in
	*"|$1|"*) return 0 ;;
	esac
	return 1
}

fdt_value() {
	local bytes
	if ! bytes=$(od -An -v -tu1 -- "$1" 2>/dev/null); then
		printf '"<unreadable>"'
		return
	fi
	printf '%s\n' "$bytes" | "$AWK" -f "$LIBDIR/fdtval.awk"
}

fdt_walk() {
	local d=$1 e base
	for e in "$d"/*; do
		[[ -e $e ]] || continue
		base=${e##*/}
		if [[ -d $e ]]; then
			printf '%s {\n' "$base"
			fdt_walk "$e"
			printf '};\n'
		elif [[ -f $e ]]; then
			if [[ ! -s $e ]]; then
				printf '%s;\n' "$base"	# empty == boolean
			elif fdt_wanted "$base"; then
				printf '%s = %s;\n' "$base" "$(fdt_value "$e")"
			else
				printf '%s;\n' "$base"	# name only: value unused
			fi
		fi
	done
}

fdt_to_dts() {
	local root=$1
	_want_pat=${props//,/|}
	printf '/dts-v1/;\n/ {\n'
	fdt_walk "$root"
	printf '};\n'
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

render() {
	local color=0
	want_color && color=1

	"$AWK" \
		-v maxdepth="$depth" \
		-v props="$props" \
		-v width="$width" \
		-v ascii="$ascii" \
		-v color="$color" \
		-v labels="$show_labels" \
		-v block="$block" \
		-v stats="$stats" \
		-v quiet="$quiet" \
		-v srcname="$1" \
		-v follow="$2" \
		-v incpaths="$incpaths" \
		-v basedir="$3" \
		-v origin="$origin" \
		-f "$LIBDIR/dts2tree.awk"
}

main() {
	parse_args "$@"
	validate_args

	[[ -r $LIBDIR/dts2tree.awk ]] || die "cannot find $LIBDIR/dts2tree.awk (set DT_VIS_LIBDIR)"
	command -v "$AWK" >/dev/null 2>&1 || die "awk not found (set DT_VIS_AWK)"

	local type=$force_type src=$infile

	if [[ $src == '-' ]]; then
		# Buffer stdin so the magic number can be sniffed.
		TMPDIR_SELF=$(mktemp -d) || die 'mktemp failed'
		cat >"$TMPDIR_SELF/stdin"
		src=$TMPDIR_SELF/stdin
		infile='(stdin)'
	elif [[ ! -e $src ]]; then
		die "no such file or directory: $src"
	elif [[ ! -r $src ]]; then
		die "cannot read: $src"
	fi

	if [[ $type == auto ]]; then
		if [[ -d $src ]]; then type=fdt; else type=$(detect_file_type "$src"); fi
	fi

	# Include following only applies to DTS source: dtc has already resolved
	# them in a blob, and a device-tree filesystem has no such notion.
	local dts_follow=0 basedir='.' k
	if [[ $type == dts ]]; then
		dts_follow=$follow
		[[ $infile == '(stdin)' ]] || basedir=$(dirname -- "$infile")
		if ((follow && auto_inc)) && [[ $infile != '(stdin)' ]]; then
			k=$(detect_kernel_includes "$infile")
			[[ -n $k ]] && incpaths="${incpaths:+$incpaths:}${k//$'\n'/:}"
		fi
	elif ((follow)); then
		((quiet)) || printf '%s: note: --follow-includes ignored for %s input\n' \
			"$PROGNAME" "$type" >&2
	fi

	case $type in
	fdt)
		[[ -d $src ]] || die "--type fdt needs a directory (got '$src')"
		fdt_to_dts "$src" | render "$infile" 0 .
		;;
	dtb)
		command -v dtc >/dev/null 2>&1 ||
			die "'$src' is a compiled dtb but dtc is not installed (apt install device-tree-compiler)"
		dtc -I dtb -O dts -q -q -q -- "$src" | render "$infile" 0 .
		;;
	dts)
		render "$infile" "$dts_follow" "$basedir" <"$src"
		;;
	esac
}

main "$@"
