#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 把 protocols/<proto>/ 的源码与 automake 片段复制进 FRR 树的 <proto>d/ 目录。
#
# 为什么是复制而不是 submodule/符号链接：
#   - automake 需要文件真实存在于源码树内；
#   - 构建树是一次性副本，复制后不会污染仓库；
#   - 加文件不需要改补丁。
# 代价：目标目录必须先清空，否则删掉的文件会残留造成假通过（本脚本强制清空）。
set -Eeuo pipefail
HR_SCRIPT=integrate-sources.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: integrate-sources.sh --frr DIR [--protocols "egp ggp"] [--manifest FILE]

  --frr DIR        FRR 源码树（应位于 BUILD_ROOT 之内）
  --protocols LIST 协议目录名，空格分隔，默认 "egp"
  --manifest FILE  写出集成清单（文件 + sha256）

约定: 协议目录 protocols/<p>/ 对应 FRR 内的 daemon 目录 <p>d/
      src/*.c|h      -> <FRR>/<p>d/
      build/*.subdir.am -> <FRR>/<p>d/subdir.am
      tests/test_packet.c -> <FRR>/<p>d/test_packet.c
      README.md, lab.sh, test_lab.py -> <FRR>/<p>d/  （仅为满足未改动的 EXTRA_DIST）
EOF
}

FRR=""; PROTOCOLS=""; MANIFEST=""
while [ $# -gt 0 ]; do
	case "$1" in
		--frr)       FRR="${2:?}"; shift 2 ;;
		--protocols) PROTOCOLS="${2:?}"; shift 2 ;;
		--manifest)  MANIFEST="${2:?}"; shift 2 ;;
		-h|--help)   usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done
[ -n "$FRR" ] || { usage; die "必须指定 --frr"; }
# 未显式指定时按 HR_PROTOCOLS（默认 egp）走；协议常量全部来自 PROTOCOL.meta
[ -n "$PROTOCOLS" ] || PROTOCOLS="$(hr_proto_list)"

hr_read_baseline
[ -n "${HR_BUILD_ROOT:-}" ] || die "HR_BUILD_ROOT 未设置（拒绝在未经校验的路径上操作文件）"
FRR="$(cd "$FRR" && pwd)"
case "$FRR" in
	"$HR_BUILD_ROOT"/*) ;;
	*) die "FRR 树 $FRR 不在 BUILD_ROOT($HR_BUILD_ROOT) 之内" ;;
esac
[ -d "$FRR/.git" ] || die "$FRR 不是 git 工作树"

record() { if [ -n "$MANIFEST" ]; then printf '%s\n' "$*" >> "$MANIFEST"; fi; }
if [ -n "$MANIFEST" ]; then
	mkdir -p "$(dirname "$MANIFEST")"
	: > "$MANIFEST"
	record "# integrate-sources @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	record "# FRR=$FRR"
fi

for proto in ${PROTOCOLS//,/ }; do
	src="$HR_REPO_ROOT/protocols/$proto"
	[ -d "$src" ] || die "找不到协议目录: $src"
	hr_proto_load "$proto"

	daemon_dir="$P_DAEMON"
	target="$FRR/$daemon_dir"
	[ -f "$src/build/${daemon_dir}.subdir.am" ] || die "缺少 $src/build/${daemon_dir}.subdir.am"

	log "=== 协议 $proto -> $target"
	hr_safe_rm_rf "$target" "$daemon_dir"
	mkdir -p "$target"

	copy_verify() {
		local from="$1" to="$2"
		[ -f "$from" ] || die "待复制文件不存在: $from"
		cp -f -- "$from" "$to" || die "复制失败: $from -> $to"
		local a b
		a="$(hr_sha256 "$from")"
		b="$(hr_sha256 "$to")"
		[ "$a" = "$b" ] || die "复制后 SHA256 不一致: $to ($a != $b)"
		log "  + $(basename "$to")  sha256=${a:0:16}"
		record "COPY $from -> $to sha256=$a"
	}

	# 只复制登记表里声明的源文件（顺序稳定，也能发现"加了文件忘了登记"）
	for f in $P_SOURCES; do
		[ -f "$src/src/$f" ] || die "登记了 $f 但 $src/src/$f 不存在"
		copy_verify "$src/src/$f" "$target/$f"
	done
	copy_verify "$src/tests/test_packet.c" "$target/test_packet.c"
	copy_verify "$src/build/${daemon_dir}.subdir.am" "$target/subdir.am"

	# EXTRA_DIST 修复：subdir.am 里写了 EXTRA_DIST += egpd/lab.sh egpd/README.md
	# egpd/test_lab.py，但这三个文件现在在仓库的其它目录。为保持 subdir.am
	# 逐字节不变（S3 的约束），构建时把它们也放进 FRR 树的 egpd/，让 make dist 能找到。
	for extra in $P_EXTRAS; do
		if [ -f "$src/$extra" ]; then
			copy_verify "$src/$extra" "$target/$extra"
		elif [ -f "$HR_REPO_ROOT/lab/$proto/$extra" ]; then
			copy_verify "$HR_REPO_ROOT/lab/$proto/$extra" "$target/$extra"
		else
			die "EXTRA_DIST 需要 $extra，但在 protocols/$proto/ 与 lab/$proto/ 都没有"
		fi
	done

	# 清空后必须恰好是预期文件集合，多一个少一个都算失败（集合来自登记表）
	expect=$(printf '%s\n' $P_SOURCES test_packet.c subdir.am $P_EXTRAS | sort)
	actual=$( (cd "$target" && ls -1) | sort)
	if [ "$expect" != "$actual" ]; then
		echo "期望:"; echo "$expect"; echo "实际:"; echo "$actual" >&2
		die "$target 的文件集合与预期不符"
	fi
	expect_n=$(printf '%s\n' "$expect" | wc -l)
	log "  文件集合校验通过（$expect_n 个）"
	record "TARGET $target files=$expect_n"

	# Protocol manuals are maintained beside the implementation. The build
	# patch registers their destinations in Sphinx and automake EXTRA_DIST.
	if [ -d "$src/doc" ]; then
		copy_verify "$src/doc/user.rst" "$FRR/doc/user/$proto.rst"
		copy_verify "$src/doc/man.rst" "$FRR/doc/manpages/frr-$daemon_dir.rst"
	fi
done

log "源码集成完成"
