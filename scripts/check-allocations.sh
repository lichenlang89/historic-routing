#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 多协议架构检查：防止两个历史协议抢同一份 FRR 资源。
#
# 检查内容：
#   1. 每个 protocols/<p>/PROTOCOL.meta 完整且合法（键齐全、值无危险字符）
#   2. 跨协议唯一：daemon 名、configure 开关、automake 条件、HAVE 宏、
#      路由类型符号/名字、显示码、vtysh 符号/位、CLI 节点、补丁目录
#   3. vtysh 位在保留区间内且是 2 的幂
#   4. 每个协议的 0001-0004 补丁真的实现了登记表里声明的东西（登记与补丁不许漂移）
#   5. 源码/automake/测试文件齐全
#   6. 可选：与固定基线比对，确认路由类型符号、显示码、vtysh 位没有被上游占用
#
# 用法: check-allocations.sh [--frr DIR]
#   给了 --frr（必须是 BASELINE 提交的 git 树）才做第 6 项，否则跳过并说明。
#
# 退出码: 0 全部通过；1 有冲突或字段不一致；2 用法错误。
set -Eeuo pipefail
HR_SCRIPT=check-allocations.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# vtysh 位图的保留区间（历史协议专用）：0x400000 .. 0x3FFFFFF
VTYSH_BIT_MIN=$((0x400000))
VTYSH_BIT_MAX=$((0x4000000))

FRR=""
while [ $# -gt 0 ]; do
	case "$1" in
		--frr) FRR="${2:?}"; shift 2 ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

hr_read_baseline

ERRORS=0
ok()   { printf '[PASS] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
note() { printf '[INFO] %s\n' "$*"; }
skip() { printf '[SKIP] %s\n' "$*"; }

# 协议目录列表（不依赖 HR_PROTOCOLS：这里要检查全部已登记协议）
mapfile -t PROTOS < <(cd "$HR_REPO_ROOT/protocols" && for d in */; do
	[ -f "$d/PROTOCOL.meta" ] && printf '%s\n' "${d%/}"
done | sort)

[ "${#PROTOS[@]}" -gt 0 ] || { bad "protocols/ 下没有任何 PROTOCOL.meta"; printf '\n汇总: %d 个错误\n' "$ERRORS"; exit 1; }
note "已登记协议: ${PROTOS[*]}"

declare -A SEEN
claim() {  # claim <字段> <值> <协议>
	local field="$1"
	local value="$2"
	local proto="$3"
	local key="$field:$value"
	if [ -n "${SEEN[$key]:-}" ]; then
		bad "$field 冲突：'$value' 同时被 ${SEEN[$key]} 与 $proto 占用"
	else
		SEEN[$key]="$proto"
	fi
}

for proto in "${PROTOS[@]}"; do
	meta="$(hr_proto_meta_path "$proto")"
	# 逐个协议校验（hr_proto_load 内部会 die；这里用子 shell 捕获，改成错误计数）
	if ! ( hr_proto_load "$proto" ) >/dev/null 2>"$HR_REPO_ROOT/.alloc.err"; then
		bad "$meta 不合法：$(tr '\n' ' ' <"$HR_REPO_ROOT/.alloc.err")"
		rm -f "$HR_REPO_ROOT/.alloc.err"
		continue
	fi
	rm -f "$HR_REPO_ROOT/.alloc.err"
	hr_proto_load "$proto"

	# 资源占用登记
	claim daemon           "$P_DAEMON"           "$proto"
	claim configure        "$P_CONFIGURE_ENABLE" "$proto"
	claim conditional      "$P_CONDITIONAL"      "$proto"
	claim have-macro       "$P_HAVE_MACRO"       "$proto"
	claim route-type       "$P_ROUTE_TYPE"       "$proto"
	claim route-type-name  "$P_ROUTE_TYPE_NAME"  "$proto"
	claim display-char     "$P_DISPLAY_CHAR"     "$proto"
	claim vtysh-symbol     "$P_VTYSH_SYMBOL"     "$proto"
	claim vtysh-bit        "$P_VTYSH_BIT"        "$proto"
	claim cli-node         "$P_CLI_NODE"         "$proto"
	claim patch-dir        "$P_PATCH_DIR"        "$proto"
	claim test-binary      "$P_TEST_BINARY"      "$proto"

	# 取值格式
	[[ "$P_DISPLAY_CHAR" =~ ^[A-Z]$ ]] || bad "$proto: DISPLAY_CHAR='$P_DISPLAY_CHAR' 必须是单个大写字母"
	[[ "$P_VTYSH_BIT" =~ ^0x[0-9a-f]+$ ]] || bad "$proto: VTYSH_BIT='$P_VTYSH_BIT' 必须是 0x 开头的十六进制"
	bit=$((P_VTYSH_BIT))
	[ $((bit & (bit - 1))) -eq 0 ] || bad "$proto: VTYSH_BIT=$P_VTYSH_BIT 不是 2 的幂"
	[ "$bit" -ge "$VTYSH_BIT_MIN" ] || bad "$proto: VTYSH_BIT=$P_VTYSH_BIT 小于保留区间下界 $VTYSH_BIT_MIN"
	[ "$bit" -le "$VTYSH_BIT_MAX" ] || bad "$proto: VTYSH_BIT=$P_VTYSH_BIT 超过保留区间上界 $VTYSH_BIT_MAX"
	[[ "$P_DISTANCE" =~ ^[0-9]+$ ]] && [ "$P_DISTANCE" -ge 1 ] && [ "$P_DISTANCE" -le 255 ] \
		|| bad "$proto: DISTANCE='$P_DISTANCE' 必须在 1..255"

	# 补丁与登记一致（防的是"改了补丁忘了改登记"以及相反）
	pdir="$HR_REPO_ROOT/$P_PATCH_DIR"
	if [ ! -d "$pdir" ]; then
		bad "$proto: 补丁目录不存在 $P_PATCH_DIR"
		continue
	fi
	for n in 1 2 3 4; do
		ls "$pdir"/000$n-*.patch >/dev/null 2>&1 || bad "$proto: $P_PATCH_DIR 缺少 000$n-*.patch"
	done
	p1=$(ls "$pdir"/0001-*.patch 2>/dev/null | head -1 || true)
	p2=$(ls "$pdir"/0002-*.patch 2>/dev/null | head -1 || true)
	p3=$(ls "$pdir"/0003-*.patch 2>/dev/null | head -1 || true)
	p4=$(ls "$pdir"/0004-*.patch 2>/dev/null | head -1 || true)

	if [ -n "$p1" ]; then
		grep -qE "^\+$P_ROUTE_TYPE,[[:space:]]*$P_ROUTE_TYPE_NAME,[[:space:]]*$P_DAEMON,[[:space:]]*'$P_DISPLAY_CHAR'," "$p1" \
			|| bad "$proto: 0001 补丁里的 route_types 行与登记不符（$P_ROUTE_TYPE/$P_ROUTE_TYPE_NAME/'$P_DISPLAY_CHAR'）"
		grep -qE "^\+[[:space:]]*$P_CLI_NODE," "$p1" || bad "$proto: 0001 补丁里没有 CLI 节点 $P_CLI_NODE"
		grep -qE "^\+[[:space:]]*if $P_CONDITIONAL$" "$p1" || bad "$proto: 0001 补丁里没有 lib/subdir.am 的 if $P_CONDITIONAL 块"
	fi
	if [ -n "$p2" ]; then
		grep -qE "^\+[[:space:]]*\[$P_ROUTE_TYPE\] = \{$P_ROUTE_TYPE, $P_DISTANCE," "$p2" \
			|| bad "$proto: 0002 补丁里的管理距离与登记的 $P_DISTANCE 不符"
	fi
	if [ -n "$p3" ]; then
		grep -q "^+#define $P_VTYSH_SYMBOL $P_VTYSH_BIT" "$p3" \
			|| bad "$proto: 0003 补丁里没有 #define $P_VTYSH_SYMBOL $P_VTYSH_BIT"
		grep -qF "{.name = \"$P_DAEMON\", .flag = $P_VTYSH_SYMBOL}" "$p3" \
			|| bad "$proto: 0003 补丁里没有 vtysh client 表项 $P_DAEMON"
	fi
	if [ -n "$p4" ]; then
		grep -q "^+AC_ARG_ENABLE(\[$P_CONFIGURE_ENABLE\]" "$p4" || bad "$proto: 0004 补丁里没有 --enable-$P_CONFIGURE_ENABLE"
		if grep -q "^+#define $P_HAVE_MACRO" "$p4"; then
			bad "$proto: 0004 不应在补丁里写死 #define $P_HAVE_MACRO（应由 AC_DEFINE 生成）"
		fi
		grep -q "^+$P_DAEMON=no" "$p4" || bad "$proto: 0004 补丁里没有 $P_DAEMON=no"
		grep -qF " $P_DAEMON " "$p4" || bad "$proto: 0004 补丁没有把 $P_DAEMON 加进 DAEMONS 列表"
		grep -qF "include $P_DAEMON/subdir.am" "$p4" || bad "$proto: 0004 补丁里没有 include $P_DAEMON/subdir.am"
		grep -qF "TESTS += $P_TEST_BINARY" "$p4" || bad "$proto: 0004 补丁里没有 TESTS += $P_TEST_BINARY"
	fi

	# 源码与 automake 片段
	src="$HR_REPO_ROOT/protocols/$proto"
	for f in $P_SOURCES; do
		[ -f "$src/src/$f" ] || bad "$proto: 登记的源文件 src/$f 不存在"
	done
	[ -f "$src/tests/test_packet.c" ] || bad "$proto: 缺少 tests/test_packet.c"
	[ -f "$src/build/$P_DAEMON.subdir.am" ] || bad "$proto: 缺少 build/$P_DAEMON.subdir.am"
	[ -f "$src/README.md" ] || bad "$proto: 缺少 README.md"
done

# ---- 补丁之间的文件级重叠（信息性，不是错误） ----
# 两个协议改同一个 FRR 文件是正常的（lib/route_types.txt 等），靠"按登记顺序应用"保证；
# 这里只把重叠列出来，让人一眼看到共享集成点。
if [ "${#PROTOS[@]}" -gt 1 ]; then
	tmp="$(mktemp -d)"
	for proto in "${PROTOS[@]}"; do
		hr_proto_load "$proto"
		for p in "$HR_REPO_ROOT/$P_PATCH_DIR"/000[1-4]-*.patch; do
			awk '/^diff --git a\//{print $3}' "$p" | sed 's|^a/||'
		done | sort -u > "$tmp/$proto"
	done
	shared="$(cat "$tmp"/* | sort | uniq -d | tr '\n' ' ')"
	if [ -n "$shared" ]; then
		note "多协议共享的集成点（按登记顺序应用）: $shared"
	fi
	rm -rf "$tmp"
fi

# ---- 与固定基线比对：上游是否已经占用了我们想用的资源 ----
if [ -n "$FRR" ]; then
	if [ ! -d "$FRR/.git" ]; then
		bad "--frr $FRR 不是 git 工作树，无法比对基线"
	else
		base_rt="$(git -C "$FRR" show "$FRR_COMMIT:lib/route_types.txt" 2>/dev/null || true)"
		base_vtysh="$(git -C "$FRR" show "$FRR_COMMIT:vtysh/vtysh.h" 2>/dev/null || true)"
		if [ -z "$base_rt" ] || [ -z "$base_vtysh" ]; then
			bad "无法从 $FRR 读取基线文件（$FRR_COMMIT）"
		else
			used_chars="$(printf '%s\n' "$base_rt" | awk -F, 'NF>3 {gsub(/[^A-Za-z-]/,"",$4); if ($4!="-" && $4!="") printf "%s", $4}')"
			for proto in "${PROTOS[@]}"; do
				hr_proto_load "$proto"
				if printf '%s' "$used_chars" | grep -q "$P_DISPLAY_CHAR"; then
					bad "$proto: 显示码 '$P_DISPLAY_CHAR' 已被基线 route_types.txt 占用"
				fi
				printf '%s\n' "$base_rt" | grep -qE "^$P_ROUTE_TYPE," \
					&& bad "$proto: 基线 route_types.txt 里已经有 $P_ROUTE_TYPE"
				printf '%s\n' "$base_vtysh" | grep -qE "^#define $P_VTYSH_SYMBOL " \
					&& bad "$proto: 基线 vtysh.h 里已经有 $P_VTYSH_SYMBOL"
				# 位值是否被 baseline 里别的符号占用
				printf '%s\n' "$base_vtysh" | grep -qiE "^#define VTYSH_[A-Z0-9_]+ +$P_VTYSH_BIT$" \
					&& bad "$proto: vtysh 位 $P_VTYSH_BIT 已被基线里的其他符号占用"
			done
			ok "与基线 $FRR_COMMIT 比对：显示码/路由类型/vtysh 位均未被上游占用"
		fi
	fi
else
	skip "未提供 --frr：跳过与固定基线的占用比对（只有拿到 BASELINE 源码树时才能做）"
fi

printf '\n'
if [ "$ERRORS" -eq 0 ]; then
	printf '汇总: 架构检查通过（%d 个协议，0 个冲突）\n' "${#PROTOS[@]}"
	exit 0
fi
printf '汇总: %d 个问题\n' "$ERRORS"
exit 1
