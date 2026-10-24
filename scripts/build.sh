#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 统一入口：从干净目录出发，拉取固定基线 FRR → 打补丁 → 集成协议源码 →
# bootstrap/configure/make → 单元测试 → make check → make dist → 安装 → 指纹。
set -Eeuo pipefail
HR_SCRIPT=build.sh
HR_BUILD_ROOT="${HR_BUILD_ROOT:-}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: build.sh [选项]

  --jobs N           并行度（默认: nproc）
  --build-root DIR   构建根目录（默认 <repo>/build）
  --prefix DIR       安装前缀（默认 <build-root>/prefix）
  --with-optional    启用可选补丁 0005（redistribute egp）
  --reuse-source     复用 <build-root>/frr-src（已存在且提交正确时）
  --skip-checks      跳过 make check（不推荐，会记录在指纹里）
  --skip-dist        跳过 make dist
  --configure-args "额外的 configure 参数"
  -h, --help         显示帮助

固定部分（不可通过参数覆盖）:
  - FRR 提交来自 patches/frr/BASELINE 的 FRR_COMMIT
  - 补丁 0001-0004 必用，0005 需显式 --with-optional
  - sysconfdir/localstatedir/runstatedir 一律在前缀之内，不写系统路径
EOF
}

JOBS="$( (command -v nproc >/dev/null && nproc) || echo 2)"
BUILD_ROOT="$HR_REPO_ROOT/build"
PREFIX=""
HR_WITH_OPTIONAL=0
REUSE=0; SKIP_CHECKS=0; SKIP_DIST=0; EXTRA_CONF=""
while [ $# -gt 0 ]; do
	case "$1" in
		--jobs)           JOBS="${2:?}"; shift 2 ;;
		--build-root)     BUILD_ROOT="${2:?}"; shift 2 ;;
		--prefix)         PREFIX="${2:?}"; shift 2 ;;
		--with-optional)  HR_WITH_OPTIONAL=1; shift ;;
		--reuse-source)   REUSE=1; shift ;;
		--skip-checks)    SKIP_CHECKS=1; shift ;;
		--skip-dist)      SKIP_DIST=1; shift ;;
		--configure-args) EXTRA_CONF="${2:?}"; shift 2 ;;
		-h|--help)        usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done

mkdir -p "$BUILD_ROOT"
HR_BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
export HR_BUILD_ROOT
mkdir -p "$HR_BUILD_ROOT/logs"
export HR_LOG_FILE="$HR_BUILD_ROOT/logs/build.log"

FRR_SRC="$HR_BUILD_ROOT/frr-src"
FRR_BUILD="$HR_BUILD_ROOT/frr-build"
[ -n "$PREFIX" ] || PREFIX="$HR_BUILD_ROOT/prefix"
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

log "构建根目录 : $HR_BUILD_ROOT"
log "源码目录   : $FRR_SRC"
log "构建目录   : $FRR_BUILD"
log "安装前缀   : $PREFIX"
log "并行度     : $JOBS"

# ---------- 0. 前置检查 ----------
log "========== [0/9] 前置检查"
hr_require_cmd git make gcc perl python3 autoconf automake libtool bison flex pkg-config
for f in "$HR_REPO_ROOT/patches/frr/BASELINE" "$HR_REPO_ROOT/protocols/egp/src/egpd.c"; do
	[ -e "$f" ] || die "仓库文件缺失: $f"
done
command -v sha256sum >/dev/null || die "缺少 sha256sum"
for pkg in libyang json-c; do
	pkg-config --exists "$pkg" && log "  pkg-config: $pkg $(pkg-config --modversion "$pkg")" \
		|| warn "  pkg-config 找不到 $pkg（configure 可能会失败）"
done
log "  gcc: $(gcc --version | head -1)"

# ---------- 1. 拉源码 ----------
log "========== [1/9] 获取固定基线 FRR"
FETCH_ARGS=(--dir "$FRR_SRC")
# --reuse-source 时不加 --force：提交不一致就报错，而不是悄悄删掉重建
[ "$REUSE" = 1 ] || FETCH_ARGS+=(--force)
HR_SCRIPT=fetch-frr.sh HR_LOG_FILE="$HR_LOG_FILE.step" \
	"$HR_REPO_ROOT/scripts/fetch-frr.sh" "${FETCH_ARGS[@]}" \
	|| { hr_tail_log "$HR_LOG_FILE.step" 30 >&2; die "获取源码失败"; }
hr_read_baseline

# ---------- 2. 打补丁 ----------
log "========== [2/9] 应用 FRR 适配补丁"
PATCH_RECORD="$HR_BUILD_ROOT/logs/patches-applied.txt"
HR_SCRIPT=apply-patches.sh HR_LOG_FILE="$HR_LOG_FILE.step" HR_WITH_OPTIONAL="$HR_WITH_OPTIONAL" \
	"$HR_REPO_ROOT/scripts/apply-patches.sh" --frr "$FRR_SRC" --record "$PATCH_RECORD" \
	|| { hr_tail_log "$HR_LOG_FILE.step" 40 >&2; die "补丁应用失败"; }

# ---------- 3. 集成源码 ----------
log "========== [3/9] 集成协议源码"
INTEGRATE_MANIFEST="$HR_BUILD_ROOT/logs/integration-manifest.txt"
HR_SCRIPT=integrate-sources.sh HR_LOG_FILE="$HR_LOG_FILE.step" HR_BUILD_ROOT="$HR_BUILD_ROOT" \
	"$HR_REPO_ROOT/scripts/integrate-sources.sh" --frr "$FRR_SRC" --protocols "egp" \
	--manifest "$INTEGRATE_MANIFEST" \
	|| { hr_tail_log "$HR_LOG_FILE.step" 40 >&2; die "源码集成失败"; }

# ---------- 4. bootstrap ----------
log "========== [4/9] 生成构建系统（bootstrap）"
( cd "$FRR_SRC" && ./bootstrap.sh ) >"$HR_BUILD_ROOT/logs/bootstrap.log" 2>&1 \
	|| { hr_tail_log "$HR_BUILD_ROOT/logs/bootstrap.log" 40 >&2; die "bootstrap 失败"; }
[ -x "$FRR_SRC/configure" ] || die "bootstrap 后没有 configure"

# ---------- 5. configure ----------
log "========== [5/9] configure"
mkdir -p "$FRR_BUILD"
CONFIGURE_ARGS=(
	--prefix="$PREFIX"
	--sysconfdir="$PREFIX/etc"
	--localstatedir="$PREFIX/var"
	--runstatedir="$PREFIX/run"
	--enable-egpd
	--enable-user=root --enable-group=root --enable-vty-group=root
	--disable-doc --disable-protobuf --disable-ospfapi --disable-ospfclient
	--disable-isisd --disable-pimd --disable-pim6d --disable-ldpd
	--disable-nhrpd --disable-babeld --disable-pbrd --disable-fabricd
	--disable-vrrpd --disable-pathd
)
if [ -n "$EXTRA_CONF" ]; then
	# shellcheck disable=SC2206
	CONFIGURE_ARGS+=($EXTRA_CONF)
fi
printf '%s\n' "${CONFIGURE_ARGS[@]}" > "$HR_BUILD_ROOT/logs/configure-args.txt"
( cd "$FRR_BUILD" && "$FRR_SRC/configure" "${CONFIGURE_ARGS[@]}" ) \
	>"$HR_BUILD_ROOT/logs/configure.log" 2>&1 \
	|| { hr_tail_log "$HR_BUILD_ROOT/logs/configure.log" 40 >&2; die "configure 失败"; }

grep -q '^#define HAVE_EGPD 1' "$FRR_BUILD/config.h" || die "config.h 中缺少 HAVE_EGPD"
log "  HAVE_EGPD: 已生成"
grep -E '^EGPD_TRUE|^egpd' "$FRR_BUILD/Makefile" | head -3 || true

# ---------- 5b. 路由类型与测试注册断言 ----------
log "========== [5b/9] 路由类型 / TESTS 注册校验"
RT="$FRR_BUILD/lib/route_types.h"
[ -f "$RT" ] || { log "  route_types.h 尚未生成（make 时生成），稍后再校验"; }
TESTS_LINES="$(grep -nE '^TESTS[[:space:]]*(\+=|=)' "$FRR_BUILD/Makefile" || true)"
log "  生成 Makefile 里的 TESTS 赋值："
printf '%s
' "$TESTS_LINES" | sed 's/^/    /'
case "$TESTS_LINES" in
	*'TESTS += egpd/test_packet'*) log "  TESTS 以累加方式包含 egpd/test_packet" ;;
	*) die "生成的 Makefile 里 TESTS 未包含 egpd/test_packet（补丁 0004 未生效？）" ;;
esac
# A/B 对照：用真实片段与真实 include 顺序演示 '=' 与 '+=' 的差别
TESTS_AB="$HR_BUILD_ROOT/logs/tests-registration-ab.txt"
{
	echo "# TESTS 累加语义 A/B（GNU make，复刻 Makefile.am 的 include 顺序：pceplib 在 tests 之前）"
	echo "== pceplib/test/subdir.am 里的赋值（上游原样）"
	grep -n '^TESTS' "$FRR_SRC/pceplib/test/subdir.am"
	echo "== tests/subdir.am 里本项目新增的注册"
	grep -n 'egpd/test_packet' "$FRR_SRC/tests/subdir.am"
	AB=$(mktemp -d)
	printf 'check_SCRIPTS = pcep_msg_tests pcep_pcc_api_tests\nTESTS = $(check_SCRIPTS)\n' > "$AB/a.mk"
	printf 'check_PROGRAMS += egpd/test_packet\nTESTS += egpd/test_packet\n' > "$AB/new.mk"
	printf 'check_PROGRAMS += egpd/test_packet\nTESTS = egpd/test_packet\n' > "$AB/old.mk"
	printf 'include a.mk\ninclude new.mk\nall:\n\t@echo "NEW=$(TESTS)"\n' > "$AB/Makefile.new"
	printf 'include a.mk\ninclude old.mk\nall:\n\t@echo "OLD=$(TESTS)"\n' > "$AB/Makefile.old"
	echo "== 旧写法（原 fork 的 TESTS =）"; make -s -C "$AB" -f Makefile.old
	echo "== 新写法（本补丁的 TESTS +=）"; make -s -C "$AB" -f Makefile.new
	rm -rf "$AB"
} > "$TESTS_AB" 2>&1
cat "$TESTS_AB"
grep -q 'OLD=egpd/test_packet$' "$TESTS_AB" || die "A/B 对照未复现旧写法的覆盖行为"
grep -q 'NEW=.*pcep.*egpd/test_packet' "$TESTS_AB" || die "A/B 对照未证明 += 保留既有测试"

# ---------- 6. make ----------
log "========== [6/9] 编译"
( cd "$FRR_BUILD" && make -j"$JOBS" ) >"$HR_BUILD_ROOT/logs/make.log" 2>&1 \
	|| { hr_tail_log "$HR_BUILD_ROOT/logs/make.log" 60 >&2; die "make 失败"; }
for b in egpd/egpd zebra/zebra vtysh/vtysh; do
	[ -x "$FRR_BUILD/$b" ] || die "缺少构建产物: $b"
	log "  OK $b"
done

# 路由类型编号（make 后 route_types.h 才存在）
grep -qE '^#define ZEBRA_ROUTE_EGP[[:space:]]+32$' "$RT" || { grep -n ZEBRA_ROUTE_EGP "$RT" >&2; die "ZEBRA_ROUTE_EGP 编号不是 32"; }
grep -qE '^#define ZEBRA_ROUTE_MAX[[:space:]]+34$' "$RT" || die "ZEBRA_ROUTE_MAX 不是 34"
log "  ZEBRA_ROUTE_EGP=32, ZEBRA_ROUTE_MAX=34（与固定基线一致）"

# ---------- 7. 单元测试 ----------
log "========== [7/9] 单元测试 egpd/test_packet"
( cd "$FRR_BUILD" && make egpd/test_packet ) >>"$HR_BUILD_ROOT/logs/make.log" 2>&1 \
	|| { hr_tail_log "$HR_BUILD_ROOT/logs/make.log" 40 >&2; die "构建 test_packet 失败"; }
UNIT_OUT="$HR_BUILD_ROOT/logs/unit-test.log"
( cd "$FRR_BUILD" && ./egpd/test_packet ) >"$UNIT_OUT" 2>&1 \
	|| { cat "$UNIT_OUT" >&2; die "单元测试失败"; }
cat "$UNIT_OUT"
grep -q 'tests passed' "$UNIT_OUT" || die "单元测试输出不含 'tests passed'"

# ---------- 8. make check / make dist ----------
CHECK_SUMMARY="skipped"
if [ "$SKIP_CHECKS" = 0 ]; then
	log "========== [8/9] make check"
	( cd "$FRR_BUILD" && make -j"$JOBS" check ) >"$HR_BUILD_ROOT/logs/make-check.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		hr_tail_log "$HR_BUILD_ROOT/logs/make-check.log" 60 >&2
		[ -f "$FRR_BUILD/test-suite.log" ] && hr_tail_log "$FRR_BUILD/test-suite.log" 40 >&2
		die "make check 失败（rc=$rc）"
	fi
	CHECK_RUN=$(grep -cE '^(PASS|FAIL|SKIP):' "$HR_BUILD_ROOT/logs/make-check.log" || true)
	CHECK_SUMMARY="passed (recorded test lines: ${CHECK_RUN:-0})"
	log "  make check 通过，记录的测试行数: ${CHECK_RUN:-0}"
	grep -E '^(PASS|FAIL|SKIP):' "$HR_BUILD_ROOT/logs/make-check.log" | sed 's/^/    /' || true
	[ -f "$FRR_BUILD/test-suite.log" ] && cp -f "$FRR_BUILD/test-suite.log" "$HR_BUILD_ROOT/logs/test-suite.log"
else
	warn "跳过 make check（--skip-checks）"
fi

DIST_RESULT="skipped"
if [ "$SKIP_DIST" = 0 ]; then
	log "  执行 make dist"
	if ( cd "$FRR_BUILD" && make -j"$JOBS" dist ) >"$HR_BUILD_ROOT/logs/make-dist.log" 2>&1; then
		TARBALL=$(ls -1t "$FRR_BUILD"/*.tar.gz 2>/dev/null | head -1 || true)
		if [ -n "$TARBALL" ]; then
			dist_ok=1
			for f in egpd/egpd.c egpd/subdir.am egpd/test_packet.c egpd/README.md egpd/lab.sh egpd/test_lab.py; do
				tar tzf "$TARBALL" | grep -q "/$f$" || { warn "  dist 里缺少 $f"; dist_ok=0; }
			done
			[ "$dist_ok" = 1 ] || die "make dist 生成的包缺少 egpd 文件"
			DIST_RESULT="ok: $(basename "$TARBALL") ($(du -h "$TARBALL" | cut -f1)), egpd/ 全部文件在内"
			log "  $DIST_RESULT"
		else
			die "make dist 成功但没有找到 tarball"
		fi
	else
		hr_tail_log "$HR_BUILD_ROOT/logs/make-dist.log" 60 >&2
		die "make dist 失败"
	fi
fi

# ---------- 9. 安装 + 指纹 ----------
log "========== [9/9] 安装与指纹"
INSTALL_MANIFEST="$HR_BUILD_ROOT/logs/install-manifest.txt"
HR_SCRIPT=install.sh HR_LOG_FILE="$HR_LOG_FILE.step" "$HR_REPO_ROOT/scripts/install.sh" \
	--build-dir "$FRR_BUILD" --prefix "$PREFIX" --manifest "$INSTALL_MANIFEST" \
	|| { hr_tail_log "$HR_LOG_FILE.step" 40 >&2; die "安装失败"; }

FP="$HR_BUILD_ROOT/fingerprint.txt"
{
	echo "# historic-routing build fingerprint"
	echo "GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "REPO_COMMIT=$(git -C "$HR_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo 'no-git')"
	echo "FRR_REPO=$FRR_REPO"
	echo "FRR_COMMIT=$FRR_COMMIT"
	echo "FRR_DESCRIBE=$FRR_DESCRIBE"
	echo "FRR_SRC_TREE_DIRTY=$(git -C "$FRR_SRC" status --porcelain | wc -l)"
	echo "FRR_PATCHED_DIFF_SHA256=$(git -C "$FRR_SRC" diff | sha256sum | cut -d' ' -f1)"
	echo "OPTIONAL_PATCH_0005=$([ "$HR_WITH_OPTIONAL" = 1 ] && echo enabled || echo disabled)"
	while read -r line; do
		case "$line" in APPLIED*) echo "PATCH_${line#APPLIED }" ;; esac
	done < "$PATCH_RECORD"
	grep '^COPY ' "$INTEGRATE_MANIFEST" | sed 's/^COPY .*\/\([^/]*\) -> .* sha256=/PROTO_SRC_\1_SHA256=/'
	echo "CC=$(gcc -dumpfullversion 2>/dev/null || gcc --version | head -1)"
	echo "CC_VERSION=$(gcc --version | head -1)"
	echo "MAKE_JOBS=$JOBS"
	echo "CONFIGURE_ARGS=$(printf '%s ' "${CONFIGURE_ARGS[@]}")"
	echo "INSTALL_PREFIX=$PREFIX"
	echo "MAKE_RESULT=ok"
	echo "EGPD_TEST_PACKET=passed"
	echo "MAKE_CHECK=$CHECK_SUMMARY"
	echo "MAKE_DIST=$DIST_RESULT"
	echo "EGPD_BINARY_SHA256=$(hr_sha256 "$PREFIX/sbin/egpd")"
	echo "ZEBRA_BINARY_SHA256=$(hr_sha256 "$PREFIX/sbin/zebra")"
	echo "VTYSH_BINARY_SHA256=$(hr_sha256 "$PREFIX/bin/vtysh")"
	echo "ZEBRA_ROUTE_EGP=$(grep -oE 'ZEBRA_ROUTE_EGP[[:space:]]+[0-9]+' "$RT" | awk '{print $2}')"
	echo "ZEBRA_ROUTE_MAX=$(grep -oE 'ZEBRA_ROUTE_MAX[[:space:]]+[0-9]+' "$RT" | awk '{print $2}')"
} > "$FP"
log "指纹: $FP"

log "================ 构建成功 ================"
cat "$FP"
