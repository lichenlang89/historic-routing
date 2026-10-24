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
rm -f "$EXPECTED" "$ACTUAL"

if git -C "$FRR" status --porcelain | grep -q '^?? egpd/'; then
	die "补丁里出现了 egpd/ 源码（不应发生）"
fi

grep -q '^ZEBRA_ROUTE_EGP,' "$FRR/lib/route_types.txt" || die "route_types.txt 未注册 EGP"
grep -q 'TESTS += egpd/test_packet' "$FRR/tests/subdir.am" || die "tests/subdir.am 不是 TESTS +="
grep -q '^AC_ARG_ENABLE(\[egpd\]' "$FRR/configure.ac" || die "configure.ac 缺少 --enable-egpd"
grep -q 'VTYSH_EGPD' "$FRR/vtysh/vtysh.h" || die "vtysh.h 缺少 VTYSH_EGPD"
grep -q 'ZEBRA_ROUTE_EGP' "$FRR/zebra/zebra_rib.c" || die "zebra_rib.c 缺少 EGP 距离项"

if [ "$HR_WITH_OPTIONAL" = 1 ]; then
	grep -q 'strmatch(s, "egp")' "$FRR/lib/log.c" || die "可选补丁 0005 未生效"
	log "可选补丁 0005 已启用（redistribute egp）"
fi

record "MODIFIED_FILES=$changed"
rm -f "$CHECK_OUT"
log "补丁应用完成：$changed 个文件被修改"
