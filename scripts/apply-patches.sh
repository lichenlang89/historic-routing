#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 按顺序应用 patches/frr/0001-0004（可选 0005）到干净基线。
# 每个补丁都在"前一个已成功应用"的状态下做 --check 再 apply；任何失败立即退出。
set -Eeuo pipefail
HR_SCRIPT=apply-patches.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: apply-patches.sh --frr DIR [--with-optional] [--record FILE]

  --frr DIR          FRR 源码树（必须处于 BASELINE 提交且工作树干净）
  --with-optional    额外应用 0005（redistribute egp，默认不启用）
  --record FILE      把应用结果写成文本记录
EOF
}

FRR=""; RECORD=""
HR_WITH_OPTIONAL=0
while [ $# -gt 0 ]; do
	case "$1" in
		--frr)           FRR="${2:?}"; shift 2 ;;
		--with-optional) HR_WITH_OPTIONAL=1; shift ;;
		--record)        RECORD="${2:?}"; shift 2 ;;
		-h|--help)       usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done
[ -n "$FRR" ] || { usage; die "必须指定 --frr"; }

hr_require_cmd git
hr_read_baseline

[ -d "$FRR/.git" ] || die "$FRR 不是 git 工作树"
cur="$(git -C "$FRR" rev-parse HEAD)"
[ "$cur" = "$FRR_COMMIT" ] || die "FRR 树提交 $cur 与基线 $FRR_COMMIT 不一致"
[ -z "$(git -C "$FRR" status --porcelain)" ] || die "FRR 树工作区不干净，拒绝打补丁"

mapfile -t PATCHES < <(hr_patch_list)
[ "${#PATCHES[@]}" -ge 4 ] || die "可用补丁少于 4 个"

log "FRR 树: $FRR"
log "基线: $cur"
log "补丁数: ${#PATCHES[@]}（可选补丁 $([ "$HR_WITH_OPTIONAL" = 1 ] && echo 启用 || echo 未启用)）"

record() { if [ -n "$RECORD" ]; then printf '%s\n' "$*" >> "$RECORD"; fi; }
if [ -n "$RECORD" ]; then
	: > "$RECORD"
	record "# apply-patches @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	record "# FRR=$FRR commit=$cur"
fi
CHECK_OUT="$(mktemp)"

i=0
for p in "${PATCHES[@]}"; do
	i=$((i+1))
	name="$(basename "$p")"
	[ -f "$p" ] || die "补丁不存在: $p"
	sum="$(hr_sha256 "$p")"
	log "[$i/${#PATCHES[@]}] $name  sha256=${sum:0:16}"

	# 独立捕获 check 输出，失败时完整打印
	if ! git -C "$FRR" apply --check --verbose "$p" >"$CHECK_OUT" 2>&1; then
		log "-------- git apply --check 输出（$name）--------"
		cat "$CHECK_OUT" >&2 || true
		die "git apply --check 失败: $name"
	fi
	if ! git -C "$FRR" apply --verbose "$p" >>"$CHECK_OUT" 2>&1; then
		cat "$CHECK_OUT" >&2 || true
		die "git apply 失败: $name"
	fi
	record "APPLIED $name sha256=$sum"
done

# ---- 事后断言 ----
log "校验补丁效果"
# 期望被改动的文件集合直接由补丁本身推导（不写死数量：
# 0001-0004 是 12 个文件，加上可选 0005 才是 13 个）
EXPECTED="$(mktemp)"
ACTUAL="$(mktemp)"
for p in "${PATCHES[@]}"; do
	git -C "$FRR" apply --numstat "$p" | awk '{print $3}'
done | sort -u > "$EXPECTED"
git -C "$FRR" diff --name-only | sort -u > "$ACTUAL"
expected_n=$(wc -l < "$EXPECTED")
actual_n=$(wc -l < "$ACTUAL")
log "期望改动文件数: $expected_n，实际: $actual_n"
if ! diff -u "$EXPECTED" "$ACTUAL"; then
	rm -f "$EXPECTED" "$ACTUAL"
	die "被改动的文件集合与补丁不一致"
fi
changed="$actual_n"

# 补丁里不应出现任何协议的 daemon 源码目录（源码走 integrate-sources.sh）
for proto in $(hr_proto_list); do
	hr_proto_load "$proto"
	if git -C "$FRR" status --porcelain | grep -q "^?? $P_DAEMON/"; then
		die "补丁里出现了 $P_DAEMON/ 源码（不应发生）"
	fi
done

# ---- 逐协议断言：登记表里的每个资源都真的落到了 FRR 树里 ----
# 这里不硬编码协议常量，全部来自 protocols/<p>/PROTOCOL.meta，所以加协议不用改脚本。
for proto in $(hr_proto_list); do
	hr_proto_load "$proto"
	log "校验协议 $proto 的集成点（$P_ROUTE_TYPE / '$P_DISPLAY_CHAR' / $P_VTYSH_SYMBOL=$P_VTYSH_BIT / ${P_DAEMON}）"

	grep -qE "^$P_ROUTE_TYPE,[[:space:]]*$P_ROUTE_TYPE_NAME,[[:space:]]*$P_DAEMON,[[:space:]]*'$P_DISPLAY_CHAR'," \
		"$FRR/lib/route_types.txt" \
		|| die "route_types.txt 里 $P_ROUTE_TYPE 的行与登记不符（名字/daemon/显示码）"

	grep -qE "^[[:space:]]*\[$P_ROUTE_TYPE\] = \{$P_ROUTE_TYPE, $P_DISTANCE," "$FRR/zebra/zebra_rib.c" \
		|| die "zebra_rib.c 里 $P_ROUTE_TYPE 的距离不是 $P_DISTANCE"

	grep -q "#define $P_VTYSH_SYMBOL $P_VTYSH_BIT" "$FRR/vtysh/vtysh.h" \
		|| die "vtysh.h 缺少 #define $P_VTYSH_SYMBOL $P_VTYSH_BIT"
	# VTYSH_ALL 是用反斜杠续行的多行宏：截取到第一行不以 \ 结尾为止
	awk '/^#define VTYSH_ALL/{f=1} f{print} f&&!/\\$/{exit}' "$FRR/vtysh/vtysh.h" \
		| grep -q "$P_VTYSH_SYMBOL" || die "VTYSH_ALL 掩码里没有 $P_VTYSH_SYMBOL"
	grep -q "{.name = \"$P_DAEMON\", .flag = $P_VTYSH_SYMBOL}" "$FRR/vtysh/vtysh.c" \
		|| die "vtysh.c 的 client 表里没有 $P_DAEMON"

	grep -q "AC_ARG_ENABLE(\[$P_CONFIGURE_ENABLE\]" "$FRR/configure.ac" \
		|| die "configure.ac 缺少 --enable-$P_CONFIGURE_ENABLE"
	grep -q "AC_DEFINE(\[$P_HAVE_MACRO\]" "$FRR/configure.ac" \
		|| die "configure.ac 缺少 $P_HAVE_MACRO"
	grep -q "AM_CONDITIONAL(\[$P_CONDITIONAL\]" "$FRR/configure.ac" \
		|| die "configure.ac 缺少 AM_CONDITIONAL($P_CONDITIONAL)"

	grep -q "^include $P_DAEMON/subdir.am" "$FRR/Makefile.am" \
		|| die "Makefile.am 缺少 include $P_DAEMON/subdir.am"
	grep -q "TESTS += $P_TEST_BINARY" "$FRR/tests/subdir.am" \
		|| die "tests/subdir.am 缺少 TESTS += $P_TEST_BINARY"
	grep -q "^$P_DAEMON=no" "$FRR/tools/etc/frr/daemons" \
		|| die "daemons 文件缺少 $P_DAEMON=no"
	grep -q " $P_DAEMON " "$FRR/tools/frrcommon.sh.in" \
		|| die "frrcommon.sh.in 的 DAEMONS 列表里没有 $P_DAEMON"
	grep -qE "^if $P_CONDITIONAL$" "$FRR/lib/subdir.am" \
		|| die "lib/subdir.am 缺少 rt_enabled 的 if $P_CONDITIONAL 块"
done

# automake 要求 TESTS 的 '=' 与 '+=' 处于兼容条件上下文，且 '=' 必须在
# pceplib 的赋值之前（否则覆盖它）。详见 patches/frr/README.md。
grep -q '^TESTS =$' "$FRR/Makefile.am" || die "Makefile.am 缺少 TESTS 的空定义（automake 会拒绝 +=）"
awk '/^TESTS =$/{t=NR} /^include pceplib\/subdir.am/{p=NR} END{exit !(t && p && t<p)}' "$FRR/Makefile.am" || die "Makefile.am 里 TESTS 的空定义必须出现在 include pceplib/subdir.am 之前"

if [ "$HR_WITH_OPTIONAL" = 1 ]; then
	for proto in $(hr_proto_list); do
		hr_proto_load "$proto"
		grep -q "strmatch(s, \"$P_ROUTE_TYPE_NAME\")" "$FRR/lib/log.c" \
			|| die "可选补丁 0005（redistribute $P_ROUTE_TYPE_NAME）未生效"
	done
	log "可选补丁 0005 已启用（redistribute）"
fi

record "MODIFIED_FILES=$changed"
rm -f "$CHECK_OUT" "$EXPECTED" "$ACTUAL"
log "补丁应用完成：$changed 个文件被修改"
