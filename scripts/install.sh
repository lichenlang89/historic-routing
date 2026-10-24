#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 把构建产物安装到独立前缀，并校验产物与动态库依赖。
# 默认 sysconfdir/localstatedir/runstatedir 都在前缀之内，不触碰系统 FRR。
set -Eeuo pipefail
HR_SCRIPT=install.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: install.sh --build-dir DIR --prefix DIR [--manifest FILE]

  --build-dir DIR  已 configure 且 make 完成的构建目录
  --prefix DIR     安装前缀（会被创建；不会写入 /etc /var /run 之外的系统路径）
EOF
}

BUILD_DIR=""; PREFIX=""; MANIFEST=""
while [ $# -gt 0 ]; do
	case "$1" in
		--build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
		--prefix)    PREFIX="${2:?}"; shift 2 ;;
		--manifest)  MANIFEST="${2:?}"; shift 2 ;;
		-h|--help)   usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done
[ -n "$BUILD_DIR" ] && [ -n "$PREFIX" ] || { usage; die "必须指定 --build-dir 与 --prefix"; }

[ -f "$BUILD_DIR/Makefile" ] || die "$BUILD_DIR 没有 Makefile（先 configure）"
[ -x "$BUILD_DIR/egpd/egpd" ] || die "$BUILD_DIR/egpd/egpd 不存在（先 make）"

log "构建目录: $BUILD_DIR"
log "安装前缀: $PREFIX"
log "执行 make install"
# 注意用 >> 追加：HR_LOG_FILE 是所有步骤共用的日志，用 `>` 会把前面步骤的记录清空
# （S4 实跑踩到：build.log 只剩 make install 的输出）
make -C "$BUILD_DIR" install >>"${HR_LOG_FILE:-/dev/null}" 2>&1 \
	|| { hr_tail_log "${HR_LOG_FILE:-/dev/null}" 40 >&2; die "make install 失败"; }

# ---- 产物断言 ----
log "校验安装产物"
miss=0
for f in sbin/egpd sbin/zebra sbin/staticd bin/vtysh; do
	if [ -x "$PREFIX/$f" ]; then
		log "  OK $f"
	else
		warn "  缺失 $f"
		miss=$((miss+1))
	fi
done
# 库的落点随 libdir 变化（RHEL 上是 $PREFIX/lib，部分平台是 lib64 或 lib/frr），
# 不要写死一种布局：直接在前缀里找。
lib=$(find "$PREFIX" -maxdepth 3 -name 'libfrr.so*' -print 2>/dev/null | head -1 || true)
[ -n "$lib" ] && log "  OK ${lib#$PREFIX/}" || { warn "  缺失 libfrr.so"; miss=$((miss+1)); }

[ "$miss" -eq 0 ] || die "安装产物缺失 $miss 项"

# ---- 动态库可解析 ----
log "校验动态库依赖（ldd）"
if command -v ldd >/dev/null 2>&1; then
	if ldd "$PREFIX/sbin/egpd" 2>&1 | grep -q 'not found'; then
		ldd "$PREFIX/sbin/egpd" | grep 'not found' >&2
		die "egpd 存在无法解析的共享库"
	fi
	log "  egpd 的动态库全部可解析"
else
	warn "系统无 ldd，跳过依赖校验"
fi

# ---- 清单 ----
if [ -n "$MANIFEST" ]; then
	mkdir -p "$(dirname "$MANIFEST")"
	{
		printf '# install manifest @ %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '# prefix=%s\n' "$PREFIX"
		printf 'EGPD_SHA256=%s\n' "$(hr_sha256 "$PREFIX/sbin/egpd")"
		printf 'ZEBRA_SHA256=%s\n' "$(hr_sha256 "$PREFIX/sbin/zebra")"
		printf 'VTYSH_SHA256=%s\n' "$(hr_sha256 "$PREFIX/bin/vtysh")"
	} > "$MANIFEST"
	log "清单: $MANIFEST"
fi

log "安装完成：$PREFIX"
