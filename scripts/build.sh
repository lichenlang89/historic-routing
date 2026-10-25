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

  --protocols LIST   要构建的协议（逗号或空格分隔，默认 egp）
  --jobs N           并行度（默认: nproc）
  --build-root DIR   构建根目录（默认 <repo>/build）
  --prefix DIR       安装前缀（默认 <build-root>/prefix）
  --destdir DIR      暂存安装根（打包用）：文件落 DIR/PREFIX，前缀里的路径仍是 --prefix
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
HR_PROTOCOLS="${HR_PROTOCOLS:-egp}"
REUSE=0; SKIP_CHECKS=0; SKIP_DIST=0; EXTRA_CONF=""; DESTDIR_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--protocols)      HR_PROTOCOLS="${2:?}"; shift 2 ;;
		--jobs)           JOBS="${2:?}"; shift 2 ;;
		--build-root)     BUILD_ROOT="${2:?}"; shift 2 ;;
		--prefix)         PREFIX="${2:?}"; shift 2 ;;
		--destdir)        DESTDIR_ARG="${2:?}"; shift 2 ;;
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
if [ -z "$DESTDIR_ARG" ]; then
	mkdir -p "$PREFIX"
	PREFIX="$(cd "$PREFIX" && pwd)"
else
	# 暂存安装（打包）：不碰真实前缀，文件落 $DESTDIR$PREFIX；
	# --prefix 的值仍是最终安装路径（会编进二进制与 RUNPATH）
	mkdir -p "$DESTDIR_ARG$PREFIX"
	DESTDIR_ARG="$(cd "$DESTDIR_ARG" && pwd)"
fi
ART_ROOT="${DESTDIR_ARG}${PREFIX}"

# 日志从这里开始（必须在 HR_LOG_FILE 确定之后调用）
hr_log_start "$HR_LOG_FILE"

log "构建根目录 : $HR_BUILD_ROOT"
log "源码目录   : $FRR_SRC"
log "构建目录   : $FRR_BUILD"
log "安装前缀   : $PREFIX"
if [ -n "$DESTDIR_ARG" ]; then log "暂存根     : $DESTDIR_ARG（文件落 $ART_ROOT）"; fi
log "并行度     : $JOBS"
PROTOS="$(hr_proto_list)"
[ -n "$PROTOS" ] || die "--protocols 解析结果为空"
export HR_PROTOCOLS="$PROTOS"
log "协议       : $(printf '%s ' $PROTOS)"

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
if [ "$SKIP_CHECKS" = 0 ]; then
	# FRR 的 make check 会跑 tests/runtests.py（pytest）
	if python3 -c 'import pytest' 2>/dev/null; then
		log "  pytest: $(python3 -c 'import pytest; print(pytest.__version__)')"
	else
		die "make check 需要 pytest，请先安装: dnf install -y python3-pytest python3-pytest-xdist（或加 --skip-checks）"
	fi
	python3 -c 'import xdist' 2>/dev/null || warn "  没有 pytest-xdist，make check 会串行执行"
fi

# ---------- 1. 拉源码 ----------
log "========== [1/9] 获取固定基线 FRR"
FETCH_ARGS=(--dir "$FRR_SRC")
# --reuse-source 时不加 --force：提交不一致就报错，而不是悄悄删掉重建
[ "$REUSE" = 1 ] || FETCH_ARGS+=(--force)
HR_SCRIPT=fetch-frr.sh \
	"$HR_REPO_ROOT/scripts/fetch-frr.sh" "${FETCH_ARGS[@]}" \
	|| { hr_tail_log "$HR_LOG_FILE" 30 >&2; die "获取源码失败"; }
hr_read_baseline

# ---------- 2. 打补丁 ----------
log "========== [2/9] 应用 FRR 适配补丁"
PATCH_RECORD="$HR_BUILD_ROOT/logs/patches-applied.txt"
HR_SCRIPT=apply-patches.sh HR_WITH_OPTIONAL="$HR_WITH_OPTIONAL" \
	"$HR_REPO_ROOT/scripts/apply-patches.sh" --frr "$FRR_SRC" --record "$PATCH_RECORD" \
	|| { hr_tail_log "$HR_LOG_FILE" 40 >&2; die "补丁应用失败"; }

# ---------- 3. 集成源码 ----------
log "========== [3/9] 集成协议源码"
INTEGRATE_MANIFEST="$HR_BUILD_ROOT/logs/integration-manifest.txt"
HR_SCRIPT=integrate-sources.sh HR_BUILD_ROOT="$HR_BUILD_ROOT" \
	"$HR_REPO_ROOT/scripts/integrate-sources.sh" --frr "$FRR_SRC" --protocols "$PROTOS" \
	--manifest "$INTEGRATE_MANIFEST" \
	|| { hr_tail_log "$HR_LOG_FILE" 40 >&2; die "源码集成失败"; }

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
	--enable-user=root --enable-group=root --enable-vty-group=root
	--disable-doc --disable-protobuf --disable-ospfapi --disable-ospfclient
	--disable-isisd --disable-pimd --disable-pim6d --disable-ldpd
	--disable-nhrpd --disable-babeld --disable-pbrd --disable-fabricd
	--disable-vrrpd --disable-pathd
)
# 每个启用协议的 configure 开关来自它的 PROTOCOL.meta（--enable-<CONFIGURE_ENABLE>）
for _p in $PROTOS; do
	hr_proto_load "$_p"
	CONFIGURE_ARGS+=("--enable-$P_CONFIGURE_ENABLE")
done
if [ -n "$EXTRA_CONF" ]; then
	# 调用方显式覆盖 --runstatedir 时，去掉前缀内的那个默认值，避免同一个参数出现两次
	# （autoconf 取最后一个，行为正确但指纹里会出现两个相互矛盾的路径）。
	case " $EXTRA_CONF " in
		*" --runstatedir="*)
			_f=()
			for _a in "${CONFIGURE_ARGS[@]}"; do
				case "$_a" in --runstatedir=*) continue ;; esac
				_f+=("$_a")
			done
			CONFIGURE_ARGS=("${_f[@]}")
			;;
	esac
	# shellcheck disable=SC2206
	CONFIGURE_ARGS+=($EXTRA_CONF)
fi
printf '%s\n' "${CONFIGURE_ARGS[@]}" > "$HR_BUILD_ROOT/logs/configure-args.txt"
( cd "$FRR_BUILD" && "$FRR_SRC/configure" "${CONFIGURE_ARGS[@]}" ) \
	>"$HR_BUILD_ROOT/logs/configure.log" 2>&1 \
	|| { hr_tail_log "$HR_BUILD_ROOT/logs/configure.log" 40 >&2; die "configure 失败"; }

for _p in $PROTOS; do
	hr_proto_load "$_p"
	grep -q "^#define $P_HAVE_MACRO 1" "$FRR_BUILD/config.h" \
		|| die "config.h 中缺少 $P_HAVE_MACRO（--enable-$P_CONFIGURE_ENABLE 未生效）"
	# automake 把 `if <COND>` 展开成 @<COND>_TRUE@，生成的 Makefile 里看不到条件名，
	# 但能看到展开后的值（rt_enabled 的追加项）——用它证明条件真的生效
	grep -q -- "--enabled $P_DAEMON" "$FRR_BUILD/Makefile" \
		|| die "Makefile 的 rt_enabled 里没有 --enabled $P_DAEMON（AM_CONDITIONAL($P_CONDITIONAL) 未生效）"
	log "  $P_HAVE_MACRO + rt_enabled(--enabled $P_DAEMON): 已生成"
done

# ---------- 5b. 路由类型与测试注册断言 ----------
log "========== [5b/9] 路由类型 / TESTS 注册校验"
RT="$FRR_BUILD/lib/route_types.h"
[ -f "$RT" ] || { log "  route_types.h 尚未生成（make 时生成），稍后再校验"; }
# automake 会把 TESTS 里的程序名改写成 am__EXEEXT_N 变量，所以不能只 grep 字面量：
# 先找每个协议的测试目标对应的变量名，再确认它确实出现在 TESTS 的赋值里。
TESTS_LINE="$(grep -m1 '^TESTS = ' "$FRR_BUILD/Makefile" || true)"
log "  Makefile: ${TESTS_LINE:-<没有 TESTS 赋值行>}"
for _p in $PROTOS; do
	hr_proto_load "$_p"
	_tvar="$(sed -n "s|^\\(am__EXEEXT_[0-9]*\\) = $P_TEST_BINARY.*|\\1|p" "$FRR_BUILD/Makefile" | head -1)"
	log "  $P_TEST_BINARY 的 automake 变量: ${_tvar:-<无（可能未改写）>}"
	if [ -n "$_tvar" ]; then
		case "$TESTS_LINE" in
			*"$_tvar"*) log "  $P_TEST_BINARY 已注册进 TESTS（经 $_tvar）" ;;
			*) die "$P_TEST_BINARY 未被注册进 TESTS（$_tvar 不在 '$TESTS_LINE' 里）" ;;
		esac
	else
		case "$TESTS_LINE" in
			*"$P_TEST_BINARY"*) log "  $P_TEST_BINARY 已直接出现在 TESTS 里" ;;
			*) die "生成的 Makefile 里 TESTS 未包含 $P_TEST_BINARY（协议 $P_NAME 的 0004 补丁未生效？）" ;;
		esac
	fi
done
# A/B 对照只做一次，用第一个协议的测试目标做样本
FIRST_TEST="$(hr_proto_load "$(hr_proto_list | head -1)"; printf '%s' "$P_TEST_BINARY")"
# A/B 对照：用真实片段与真实 include 顺序演示 '=' 与 '+=' 的差别
TESTS_AB="$HR_BUILD_ROOT/logs/tests-registration-ab.txt"
{
	echo "# TESTS 累加语义 A/B（GNU make，复刻 Makefile.am 的 include 顺序：pceplib 在 tests 之前）"
	echo "== pceplib/test/subdir.am 里的赋值（上游原样）"
	grep -n '^TESTS' "$FRR_SRC/pceplib/test/subdir.am"
	echo "== tests/subdir.am 里本项目新增的注册"
	grep -n "$FIRST_TEST" "$FRR_SRC/tests/subdir.am"
	AB=$(mktemp -d)
	printf 'check_SCRIPTS = pcep_msg_tests pcep_pcc_api_tests\nTESTS = $(check_SCRIPTS)\n' > "$AB/a.mk"
	printf 'check_PROGRAMS += %s\nTESTS += %s\n' "$FIRST_TEST" "$FIRST_TEST" > "$AB/new.mk"
	printf 'check_PROGRAMS += %s\nTESTS = %s\n' "$FIRST_TEST" "$FIRST_TEST" > "$AB/old.mk"
	printf 'include a.mk\ninclude new.mk\nall:\n	@echo "NEW=$(TESTS)"\n' > "$AB/Makefile.new"
	printf 'include a.mk\ninclude old.mk\nall:\n	@echo "OLD=$(TESTS)"\n' > "$AB/Makefile.old"
	echo "== 旧写法（原 fork 的 TESTS =）"; make -s -C "$AB" -f Makefile.old
	echo "== 新写法（本补丁的 TESTS +=）"; make -s -C "$AB" -f Makefile.new
	rm -rf "$AB"
} > "$TESTS_AB" 2>&1
cat "$TESTS_AB"
grep -q "OLD=$FIRST_TEST\$" "$TESTS_AB" || die "A/B 对照未复现旧写法的覆盖行为"
grep -q "NEW=.*pcep.*$FIRST_TEST" "$TESTS_AB" || die "A/B 对照未证明 += 保留既有测试"

# ---------- 6. make ----------
log "========== [6/9] 编译"
( cd "$FRR_BUILD" && make -j"$JOBS" ) >"$HR_BUILD_ROOT/logs/make.log" 2>&1 \
	|| { hr_tail_log "$HR_BUILD_ROOT/logs/make.log" 60 >&2; die "make 失败"; }
for _p in $PROTOS; do
	hr_proto_load "$_p"
	[ -x "$FRR_BUILD/$P_DAEMON/$P_DAEMON" ] || die "缺少构建产物: $P_DAEMON/$P_DAEMON"
	log "  OK $P_DAEMON/$P_DAEMON"
done
for b in zebra/zebra vtysh/vtysh; do
	[ -x "$FRR_BUILD/$b" ] || die "缺少构建产物: $b"
	log "  OK $b"
done

# 路由类型编号：由 lib/route_types.txt 的插入顺序决定，必须与登记顺序一致
# （第一个协议 32，之后依登记顺序递增；ALL 紧随其后，MAX = ALL + 1）
_expected_id=32
for _p in $PROTOS; do
	hr_proto_load "$_p"
	_actual_id="$(awk '/^#define '"$P_ROUTE_TYPE"'[[:space:]]/{print $3}' "$RT")"
	[ "$_actual_id" = "$_expected_id" ] || {
		grep -n "$P_ROUTE_TYPE" "$RT" >&2 || true
		die "$P_ROUTE_TYPE 的编号是 ${_actual_id:-未找到}，按登记顺序应为 $_expected_id（补丁应用顺序或登记顺序被打乱）"
	}
	log "  $P_ROUTE_TYPE=$_actual_id（登记顺序第 $(( _expected_id - 31 )) 个）"
	_expected_id=$((_expected_id + 1))
done
_all_id="$(awk '/^#define ZEBRA_ROUTE_ALL[[:space:]]/{print $3}' "$RT")"
_max_id="$(awk '/^#define ZEBRA_ROUTE_MAX[[:space:]]/{print $3}' "$RT")"
[ "$_all_id" = "$_expected_id" ] || die "ZEBRA_ROUTE_ALL 编号是 ${_all_id:-未找到}，应为 $_expected_id"
[ "$_max_id" = "$((_expected_id + 1))" ] || die "ZEBRA_ROUTE_MAX 编号是 ${_max_id:-未找到}，应为 $((_expected_id + 1))"
log "  ZEBRA_ROUTE_ALL=$_all_id, ZEBRA_ROUTE_MAX=$_max_id"

# ---------- 7. 单元测试 ----------
UNIT_OUT="$HR_BUILD_ROOT/logs/unit-test.log"
: > "$UNIT_OUT"
for _p in $PROTOS; do
	hr_proto_load "$_p"
	log "========== [7/9] 单元测试 $P_TEST_BINARY（协议 $P_NAME）"
	( cd "$FRR_BUILD" && make "$P_TEST_BINARY" ) >>"$HR_BUILD_ROOT/logs/make.log" 2>&1 \
		|| { hr_tail_log "$HR_BUILD_ROOT/logs/make.log" 40 >&2; die "构建 $P_TEST_BINARY 失败"; }
	{ echo "########## $P_TEST_BINARY"; ( cd "$FRR_BUILD" && "./$P_TEST_BINARY" ); } >>"$UNIT_OUT" 2>&1 \
		|| { cat "$UNIT_OUT" >&2; die "单元测试失败: $P_TEST_BINARY"; }
	grep -q 'tests passed' "$UNIT_OUT" || die "$P_TEST_BINARY 的输出不含 'tests passed'"
	log "  $P_TEST_BINARY: $(grep -o '[0-9]* tests passed' "$UNIT_OUT" | tail -1)"
done
cat "$UNIT_OUT"

# ---------- 8. make check / make dist ----------
# 分两级：
#   8a make check-TESTS —— 硬门禁。这是 automake 的 TESTS 列表，跑的就是
#      patches/frr/0004 注册的那个测试，能直接证明"注册生效且真的执行了"。
#   8b make check —— 完整目标，额外包含 FRR 上游的 pytest 套件（tests/runtests.py），
#      其中 isisd/pimd 等用例需要对应 daemon 编译；本项目的 configure 集合是
#      按已验证配置禁用了这些 daemon，因此这些用例必然失败。这类失败按
#      "--disable-<daemon>" 归类，只有"无法归因"的失败才判定为构建失败。
CHECK_SUMMARY="skipped"
CHECK_RC="not-run"
CHECK_FAILED_DIRS=""
if [ "$SKIP_CHECKS" = 0 ]; then
	log "========== [8/9] make check（8a: TESTS 门禁 / 8b: 完整套件）"

	log "  [8a] make check-TESTS"
	rc=0
	( cd "$FRR_BUILD" && make check-TESTS ) >"$HR_BUILD_ROOT/logs/make-check-tests.log" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		hr_tail_log "$HR_BUILD_ROOT/logs/make-check-tests.log" 40 >&2
		die "make check-TESTS 失败（rc=$rc）"
	fi
	for _p in $PROTOS; do
		hr_proto_load "$_p"
		grep -qE "^PASS: $P_TEST_BINARY$" "$HR_BUILD_ROOT/logs/make-check-tests.log" \
			|| die "make check-TESTS 没有运行 $P_TEST_BINARY（协议 $P_NAME）"
	done
	TESTS_TOTAL="$(grep -m1 '^# TOTAL:' "$HR_BUILD_ROOT/logs/make-check-tests.log" | awk '{print $3}')"
	TESTS_PASS="$(grep -m1 '^# PASS:' "$HR_BUILD_ROOT/logs/make-check-tests.log" | awk '{print $3}')"
	TESTS_FAIL="$(grep -m1 '^# FAIL:' "$HR_BUILD_ROOT/logs/make-check-tests.log" | awk '{print $3}')"
	log "  [8a] $(grep -cE '^PASS: ' "$HR_BUILD_ROOT/logs/make-check-tests.log") 个单元测试 PASS（TOTAL=$TESTS_TOTAL PASS=$TESTS_PASS FAIL=$TESTS_FAIL）"
	grep -E '^(PASS|FAIL|SKIP|ERROR):' "$HR_BUILD_ROOT/logs/make-check-tests.log" | sed 's/^/    /' || true
	[ "${TESTS_FAIL:-0}" = "0" ] || die "make check-TESTS 有失败（FAIL=$TESTS_FAIL）"

	log "  [8b] make check（含上游 pytest 套件）"
	rc=0
	( cd "$FRR_BUILD" && make -j"$JOBS" check ) >"$HR_BUILD_ROOT/logs/make-check.log" 2>&1 || rc=$?
	UPSTREAM_SUMMARY="$(grep -E '^(=+) [0-9]+ (failed|passed)' "$HR_BUILD_ROOT/logs/make-check.log" | tail -1 | sed 's/^=* //;s/ =*$//')"
	if [ "$rc" -eq 0 ]; then
		CHECK_RC=0
		CHECK_SUMMARY="check-TESTS: 1/1 passed; make check: passed"
		log "  [8b] make check 通过（$UPSTREAM_SUMMARY）"
	else
		hr_tail_log "$HR_BUILD_ROOT/logs/make-check.log" 40 >&2
		# 从 configure 参数推导被禁用的模块
		disabled="$(printf '%s\n' "${CONFIGURE_ARGS[@]}" | sed -n 's/^--disable-\(.*\)$/\1/p' | tr '\n' ' ')"
		failed_dirs="$(grep -E '^FAILED ' "$HR_BUILD_ROOT/logs/make-check.log" \
			| sed 's#.*/tests/\([^/]*\)/.*#\1#' | sort -u | tr '\n' ' ')"
		unclassified=""
		for d in $failed_dirs; do
			case " $disabled " in
				*" $d "*) ;;
				*) unclassified="$unclassified $d" ;;
			esac
		done
		log "  被禁用的模块: ${disabled}"
		log "  失败的测试目录: ${failed_dirs:-<未解析到>}"
		if [ -n "$unclassified" ]; then
			die "make check 有无法归因到被禁用模块的失败:$unclassified（见 logs/make-check.log）"
		fi
		CHECK_RC="$rc"
		CHECK_FAILED_DIRS="$failed_dirs"
		CHECK_SUMMARY="check-TESTS: 1/1 passed; make check rc=$rc: 仅在已 --disable 的模块 ($failed_dirs) 失败，$UPSTREAM_SUMMARY"
		log "  [8b] 所有失败都属于已 --disable 的模块（$failed_dirs），判定为已知限制"
	fi
	if [ -f "$FRR_BUILD/test-suite.log" ]; then cp -f "$FRR_BUILD/test-suite.log" "$HR_BUILD_ROOT/logs/test-suite.log"; fi
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
			# 注意：不能写 `tar tzf "$T" | grep -q ...`：set -o pipefail 下
			# grep -q 先退出会让 tar 收到 SIGPIPE（141），整条管道被判失败，
			# 于是"包里有文件"也被报成缺少（S4 实测踩到）。先把清单落文件。
			DIST_LIST="$HR_BUILD_ROOT/logs/make-dist-contents.txt"
			tar tzf "$TARBALL" > "$DIST_LIST" || die "无法读取 $TARBALL 的清单"
			for f in egpd/egpd.c egpd/subdir.am egpd/test_packet.c egpd/README.md egpd/lab.sh egpd/test_lab.py; do
				grep -q "/$f$" "$DIST_LIST" || { warn "  dist 里缺少 $f"; dist_ok=0; }
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
destdir_args=()
[ -n "$DESTDIR_ARG" ] && destdir_args=(--destdir "$DESTDIR_ARG")
HR_SCRIPT=install.sh "$HR_REPO_ROOT/scripts/install.sh" \
	--build-dir "$FRR_BUILD" --prefix "$PREFIX" "${destdir_args[@]}" \
	--manifest "$INSTALL_MANIFEST" \
	|| { hr_tail_log "$HR_LOG_FILE" 40 >&2; die "安装失败"; }

FP="$HR_BUILD_ROOT/fingerprint.txt"
{
	echo "# historic-routing build fingerprint"
	echo "GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	_src_commit="$(git -C "$HR_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
	[ -n "$_src_commit" ] || _src_commit="${HR_SOURCE_COMMIT:-unknown}"
	echo "REPO_COMMIT=$_src_commit"
	echo "REPO_COMMIT_SOURCE=$( [ -n "$HR_SOURCE_COMMIT" ] && echo env || echo git )"
	echo "FRR_REPO=$FRR_REPO"
	if [ -n "${HR_FRR_MIRROR_TARBALL:-}" ]; then
		echo "FRR_REPO_EFFECTIVE=mirror:$(basename "$HR_FRR_MIRROR_TARBALL")"
		echo "FRR_MIRROR_SHA256=$(sha256sum "$HR_FRR_MIRROR_TARBALL" | cut -d' ' -f1)"
	elif [ -n "${HR_FRR_REPO:-}" ]; then echo "FRR_REPO_EFFECTIVE=$HR_FRR_REPO"
	else echo "FRR_REPO_EFFECTIVE=$FRR_REPO"; fi
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
	echo "MAKE_CHECK_RC=$CHECK_RC"
	echo "MAKE_CHECK_FAILED_DIRS=$CHECK_FAILED_DIRS"
	echo "MAKE_CHECK_SUMMARY=$CHECK_SUMMARY"
	echo "MAKE_DIST=$DIST_RESULT"
	for _p in $PROTOS; do
		hr_proto_load "$_p"
		echo "PROTOCOL_${P_NAME^^}_BINARY_SHA256=$(hr_sha256 "$ART_ROOT/sbin/$P_DAEMON")"
	done
	echo "ZEBRA_BINARY_SHA256=$(hr_sha256 "$ART_ROOT/sbin/zebra")"
	echo "VTYSH_BINARY_SHA256=$(hr_sha256 "$ART_ROOT/bin/vtysh")"
	echo "PROTOCOLS=$(printf '%s ' $PROTOS)"
	for _p in $PROTOS; do
		hr_proto_load "$_p"
		echo "PROTOCOL_${P_NAME^^}_ROUTE_TYPE_ID=$(awk '/^#define '"$P_ROUTE_TYPE"'[[:space:]]/{print $3}' "$RT")"
		echo "PROTOCOL_${P_NAME^^}_DISPLAY_CHAR=$P_DISPLAY_CHAR"
		echo "PROTOCOL_${P_NAME^^}_DISTANCE=$P_DISTANCE"
		echo "PROTOCOL_${P_NAME^^}_VTYSH_BIT=$P_VTYSH_BIT"
		echo "PROTOCOL_${P_NAME^^}_DAEMON=$P_DAEMON"
	done
	echo "ZEBRA_ROUTE_ALL_ID=$(awk '/^#define ZEBRA_ROUTE_ALL[[:space:]]/{print $3}' "$RT")"
	echo "ZEBRA_ROUTE_MAX=$(awk '/^#define ZEBRA_ROUTE_MAX[[:space:]]/{print $3}' "$RT")"
} > "$FP"
log "指纹: $FP"

log "================ 构建成功 ================"
cat "$FP"
