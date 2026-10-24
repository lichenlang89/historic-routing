#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 把构建产物安装到独立前缀，并校验产物与动态库依赖。
# 默认 sysconfdir/localstatedir/runstatedir 都在前缀之内，不触碰系统 FRR。
set -Eeuo pipefail
HR_SCRIPT=install.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: install.sh --build-dir DIR --prefix DIR [--destdir DIR] [--manifest FILE]

  --build-dir DIR  已 configure 且 make 完成的构建目录
  --prefix DIR     安装前缀（configure 时确定的最终路径）
  --destdir DIR    暂存根（打包用）：实际写入 DIR/PREFIX，生产安装时不要给
EOF
}

BUILD_DIR=""; PREFIX=""; MANIFEST=""; DESTDIR="${DESTDIR:-}"
while [ $# -gt 0 ]; do
	case "$1" in
		--build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
		--prefix)    PREFIX="${2:?}"; shift 2 ;;
		--destdir)   DESTDIR="${2:-}"; shift 2 ;;
		--manifest)  MANIFEST="${2:?}"; shift 2 ;;
		-h|--help)   usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done
[ -n "$BUILD_DIR" ] && [ -n "$PREFIX" ] || { usage; die "必须指定 --build-dir 与 --prefix"; }

[ -f "$BUILD_DIR/Makefile" ] || die "$BUILD_DIR 没有 Makefile（先 configure）"
# 至少有一个协议 daemon 构建产物（协议列表来自 HR_PROTOCOLS，默认 egp）
for _p in $(hr_proto_list); do
	hr_proto_load "$_p"
	[ -x "$BUILD_DIR/$P_DAEMON/$P_DAEMON" ] || die "$BUILD_DIR/$P_DAEMON/$P_DAEMON 不存在（先 make）"
done

log "构建目录: $BUILD_DIR"
log "安装前缀: $PREFIX"
if [ -n "$DESTDIR" ]; then log "暂存根  : $DESTDIR（安装到 $DESTDIR$PREFIX）"; fi
# ROOT = 文件实际落点：给了 DESTDIR 时是 $DESTDIR$PREFIX，否则就是 $PREFIX
ROOT="${DESTDIR}${PREFIX}"
log "执行 make install"
# 注意用 >> 追加：HR_LOG_FILE 是所有步骤共用的日志，用 `>` 会把前面步骤的记录清空
# （S4 实跑踩到：build.log 只剩 make install 的输出）
if [ -n "$DESTDIR" ]; then
	make -C "$BUILD_DIR" install DESTDIR="$DESTDIR" >>"${HR_LOG_FILE:-/dev/null}" 2>&1 \
		|| { hr_tail_log "${HR_LOG_FILE:-/dev/null}" 40 >&2; die "make install 失败"; }
else
	make -C "$BUILD_DIR" install >>"${HR_LOG_FILE:-/dev/null}" 2>&1 \
		|| { hr_tail_log "${HR_LOG_FILE:-/dev/null}" 40 >&2; die "make install 失败"; }
fi

# ---- 产物断言 ----
log "校验安装产物"
miss=0
_bins="sbin/zebra sbin/staticd bin/vtysh"
for _p in $(hr_proto_list); do
	hr_proto_load "$_p"
	_bins="$_bins sbin/$P_DAEMON"
done
for f in $_bins; do
	if [ -x "$ROOT/$f" ]; then
		log "  OK $f"
	else
		warn "  缺失 $f"
		miss=$((miss+1))
	fi
done
# 库的落点随 libdir 变化（RHEL 上是 $PREFIX/lib，部分平台是 lib64 或 lib/frr），
# 不要写死一种布局：直接在前缀里找。
lib=$(find "$ROOT" -maxdepth 3 -name 'libfrr.so*' -print 2>/dev/null | head -1 || true)
[ -n "$lib" ] && log "  OK ${lib#$ROOT/}" || { warn "  缺失 libfrr.so"; miss=$((miss+1)); }

[ "$miss" -eq 0 ] || die "安装产物缺失 $miss 项"

# ---- 动态库可解析 ----
log "校验动态库依赖（ldd）"
if command -v ldd >/dev/null 2>&1; then
	for _p in $(hr_proto_list); do
		hr_proto_load "$_p"
		# 暂存安装时二进制里的 RUNPATH 指向最终前缀（还不存在），用 LD_LIBRARY_PATH 兜住
		if LD_LIBRARY_PATH="$ROOT/lib:$ROOT/lib64:$ROOT/lib/frr${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" 			ldd "$ROOT/sbin/$P_DAEMON" 2>&1 | grep -q 'not found'; then
			LD_LIBRARY_PATH="$ROOT/lib:$ROOT/lib64:$ROOT/lib/frr" ldd "$ROOT/sbin/$P_DAEMON" | grep 'not found' >&2
			die "$P_DAEMON 存在无法解析的共享库"
		fi
		log "  $P_DAEMON 的动态库全部可解析"
	done
else
	warn "系统无 ldd，跳过依赖校验"
fi

# ---- 清单 ----
if [ -n "$MANIFEST" ]; then
	mkdir -p "$(dirname "$MANIFEST")"
	{
		printf '# install manifest @ %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '# prefix=%s\n' "$PREFIX"
		printf '%s_SHA256=%s\n' "ZEBRA" "$(hr_sha256 "$PREFIX/sbin/zebra")"
		printf '%s_SHA256=%s\n' "VTYSH" "$(hr_sha256 "$PREFIX/bin/vtysh")"
		for _p in $(hr_proto_list); do
			hr_proto_load "$_p"
			printf '%s_SHA256=%s\n' "${P_DAEMON^^}" "$(hr_sha256 "$PREFIX/sbin/$P_DAEMON")"
		done
	} > "$MANIFEST"
	log "清单: $MANIFEST"
fi

log "安装完成：$ROOT"
