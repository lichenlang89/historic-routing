#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 公共函数库：日志、断言、路径安全、BASELINE 读取。
# 被 scripts/*.sh source，不单独执行。
#
# 日志策略：每条日志同时写 stdout 与日志文件（直接 append）。
# 不用 `exec > >(tee ...)`：shell 的 stdout 接管道时是块缓冲，
# 失败瞬间 tail 日志仍为空（S4 实测踩到过）。

set -Eeuo pipefail

# ---------- 基础 ----------
HR_SCRIPT="${HR_SCRIPT:-$(basename "$0")}"
HR_REPO_ROOT="${HR_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HR_LOG_FILE="${HR_LOG_FILE:-}"

# 仅创建目录与打横幅；真正的写文件由 log()/warn()/die() 完成
# 注意：本函数调用 log()，而 log() 在本文件后面才定义，
# 所以下面的自动调用必须放在文件末尾，不能放在这里。
hr_log_start() {
	local f="${1:-$HR_LOG_FILE}"
	if [ -n "$f" ]; then
		mkdir -p "$(dirname "$f")"
		HR_LOG_FILE="$f"
		log "===== 日志文件: $f ====="
	fi
}

_ts() { date -u +%H:%M:%SZ; }

_emit() {
	local line="$1" dest="$2"
	if [ "$dest" = "err" ]; then
		printf '%s\n' "$line" >&2
	else
		printf '%s\n' "$line"
	fi
	if [ -n "$HR_LOG_FILE" ]; then
		printf '%s\n' "$line" >> "$HR_LOG_FILE"
	fi
}

log()  { _emit "$(printf '[%s] %-22s %s' "$(_ts)" "$HR_SCRIPT" "$*")" out; }
warn() { _emit "$(printf '[%s] %-22s WARN %s' "$(_ts)" "$HR_SCRIPT" "$*")" err; }
die()  { _emit "$(printf '[%s] %-22s FAIL %s' "$(_ts)" "$HR_SCRIPT" "$*")" err; exit 1; }

hr_require_cmd() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
	done
}

# ---------- BASELINE ----------
# 从 patches/frr/BASELINE 读取 KEY=VALUE，仅接受白名单键，避免执行任意内容。
hr_read_baseline() {
	local f="$HR_REPO_ROOT/patches/frr/BASELINE"
	[ -f "$f" ] || die "找不到 $f"

	FRR_REPO=""; FRR_COMMIT=""; FRR_DESCRIBE=""
	SOURCE_REPO=""; SOURCE_VERIFIED_COMMIT=""; SOURCE_VERIFIED_TAG=""

	local key val
	while IFS='=' read -r key val; do
		case "$key" in
			''|\#*) continue ;;
		esac
		case "$key" in
			FRR_REPO)               FRR_REPO="$val" ;;
			FRR_COMMIT)             FRR_COMMIT="$val" ;;
			FRR_DESCRIBE)           FRR_DESCRIBE="$val" ;;
			SOURCE_REPO)            SOURCE_REPO="$val" ;;
			SOURCE_VERIFIED_COMMIT) SOURCE_VERIFIED_COMMIT="$val" ;;
			SOURCE_VERIFIED_TAG)    SOURCE_VERIFIED_TAG="$val" ;;
			*) warn "BASELINE 中忽略未知键: $key" ;;
		esac
	done < "$f"

	[ -n "$FRR_REPO" ]   || die "BASELINE 缺少 FRR_REPO"
	[ -n "$FRR_COMMIT" ] || die "BASELINE 缺少 FRR_COMMIT"
	[[ "$FRR_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "FRR_COMMIT 不是 40 位 SHA: $FRR_COMMIT"
}

hr_patch_list() {
	# 按协议登记顺序列出补丁：每个协议 0001-0004 必需，0005 可选。
	# 顺序 = protocols/<name>/PROTOCOL.meta 里 ROUTE_TYPE 的编号顺序，
	# 不可打乱（lib/route_types.txt 的编号按插入顺序决定）。
	local proto p
	for proto in $(hr_proto_list); do
		hr_proto_load "$proto"
		for p in "$HR_REPO_ROOT/$P_PATCH_DIR"/000[1-4]-*.patch; do
			[ -f "$p" ] || die "协议 $proto 缺少必需补丁: $p/000[1-4]-*.patch"
			printf '%s\n' "$p"
		done
		if [ "${HR_WITH_OPTIONAL:-0}" = "1" ]; then
			for p in "$HR_REPO_ROOT/$P_PATCH_DIR"/0005-*.patch; do
				[ -f "$p" ] || die "--with-optional 指定了可选补丁，但协议 $proto 没有 0005-*"
				printf '%s\n' "$p"
			done
		fi
	done
}

# ---------- 协议登记 ----------
# 每个协议在 protocols/<name>/PROTOCOL.meta 里登记它在 FRR 内部占用的全部资源
# （路由类型、显示码、距离、vtysh 位、daemon 名、补丁目录、源文件…）。
# 这些函数是唯一读取处，脚本里不再硬编码协议常量。
HR_PROTO_KEYS="NAME DAEMON CONFIGURE_ENABLE CONDITIONAL HAVE_MACRO ROUTE_TYPE \
ROUTE_TYPE_NAME DISPLAY_CHAR DISTANCE VTYSH_SYMBOL VTYSH_BIT CLI_NODE \
PATCH_DIR SOURCES EXTRAS TEST_BINARY"

hr_proto_meta_path() { printf '%s/protocols/%s/PROTOCOL.meta' "$HR_REPO_ROOT" "$1"; }

# 读取并校验一个协议登记，结果放在 P_<KEY> 全局变量里
hr_proto_load() {
	local proto="$1" f="${2:-}" key val k
	[ -n "$f" ] || f="$(hr_proto_meta_path "$proto")"
	[ -f "$f" ] || die "协议 '$proto' 未登记：缺少 $f（先在 protocols/$proto/PROTOCOL.meta 登记资源）"
	for k in $HR_PROTO_KEYS; do printf -v "P_$k" '%s' ''; done
	while IFS='=' read -r key val; do
		case "$key" in ''|\#*) continue ;; esac
		case " $HR_PROTO_KEYS " in
			*" $key "*) ;;
			*) die "$f: 未登记的键 '$key'" ;;
		esac
		case "$val" in
			*'$'*|*'`'*|*';'*|*'"'*|*"'"*) die "$f: $key 的值含非法字符" ;;
		esac
		printf -v "P_$key" '%s' "$val"
	done < "$f"
	[ "${P_NAME:-}" = "$proto" ] || die "$f: NAME='${P_NAME:-}' 必须与目录名 '$proto' 一致"
	for k in $HR_PROTO_KEYS; do
		eval "val=\$P_$k"
		[ -n "$val" ] || die "$f: 缺少 $k"
	done
	return 0
}

# 本次要构建/校验的协议列表（空格或逗号分隔，默认 egp）
hr_proto_list() {
	local raw="${HR_PROTOCOLS:-egp}" proto
	for proto in ${raw//,/ }; do
		[ -n "$proto" ] || continue
		[ -d "$HR_REPO_ROOT/protocols/$proto" ] \
			|| die "协议 '$proto' 不存在：没有 protocols/$proto/ 目录"
		printf '%s\n' "$proto"
	done
}

# ---------- 路径安全 ----------
# 只允许删除 BUILD_ROOT 之下、名称精确匹配的一级子目录。
hr_safe_rm_rf() {
	local path="$1" expected="$2"
	[ -n "${HR_BUILD_ROOT:-}" ] || die "HR_BUILD_ROOT 未设置，拒绝 rm -rf"
	[ -n "$path" ] || die "hr_safe_rm_rf: 空路径"
	[ "$path" != "/" ] || die "hr_safe_rm_rf: 拒绝删除 /"
	case "$path" in
		*..*) die "hr_safe_rm_rf: 路径含 '..': $path" ;;
		/*) ;;
		*) die "hr_safe_rm_rf: 需要绝对路径: $path" ;;
	esac
	case "$path" in
		"$HR_BUILD_ROOT"/*) ;;
		*) die "hr_safe_rm_rf: $path 不在 BUILD_ROOT($HR_BUILD_ROOT) 之内" ;;
	esac
	[ "$(basename "$path")" = "$expected" ] || die "hr_safe_rm_rf: 末级目录应为 '$expected'，实际 '$(basename "$path")'"
	[ -L "$path" ] && die "hr_safe_rm_rf: 目标是符号链接: $path"
	if [ -e "$path" ]; then
		log "删除目录: $path"
		rm -rf -- "$path"
	fi
}

hr_sha256() { sha256sum "$1" | cut -d' ' -f1; }

hr_tail_log() {
	local f="$1" n="${2:-40}"
	[ -f "$f" ] || return 0
	{
		echo "----- $f (末 $n 行) -----"
		tail -n "$n" "$f"
		echo "--------------------------------"
	} >&2
}

# 必须在 log()/warn()/die() 定义之后：hr_log_start 内部会调用 log()
if [ -n "$HR_LOG_FILE" ]; then
	hr_log_start
fi
