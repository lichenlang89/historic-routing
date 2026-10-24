#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 统一验证入口（S6）：把"构建可重复 / 测试可信 / 实验安全"变成一条命令。
#
#   A 仓库完整性   固定 FRR 提交、补丁 SHA256、补丁顺序可应用、协议源码哈希、敏感信息
#   B 构建与产物   构建（能复用就复用）、产物与依赖、路由类型、单测、make check、make dist
#   C 实验环境     podman/镜像、最小权限 A/B、up、重复 up、集成测试、异常中断、清理、幂等
#
# 状态：
#   PASS        实际执行并通过
#   FAIL        实际执行并失败
#   KNOWN-FAIL  已记录、且有直接日志证据支持的已知失败
#   SKIP        未执行或无法执行，必须写明原因
#
# 退出码：0 = 全 PASS/KNOWN-FAIL；1 = 有 FAIL；2 = 用法/环境错误；3 = 有 SKIP（验证不完整）
set -Eeuo pipefail
HR_SCRIPT=verify.sh
HR_BUILD_ROOT="${HR_BUILD_ROOT:-}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MODE=all
JOBS="$( (command -v nproc >/dev/null && nproc) || echo 2)"
BUILD_ROOT="$HR_REPO_ROOT/build"
PREFIX=""
FORCE_BUILD=0
SKIP_FULL_CHECK=0
SKIP_DIST=0
KEEP_LAB=0
CAP_AUDIT=1
JSON_OUT=""
PROTOCOLS="${HR_PROTOCOLS:-egp}"

usage() {
	cat <<'EOF'
用法: verify.sh [模式] [选项]

模式（默认 --all）:
  --build-only       只做 A/B（仓库完整性 + 构建与产物）
  --lab-only         只做 A/C（仓库完整性 + 实验环境；要求已有安装前缀）
  --all              全做

选项:
  --build-root DIR   构建根目录（默认 <repo>/build）
  --prefix DIR       安装前缀（默认 <build-root>/prefix）
  --protocols LIST   要构建/校验的协议（逗号分隔，默认 egp）
  --jobs N           并行度（默认 nproc）
  --force-build      忽略已有指纹，强制重新构建
  --skip-full-check  跳过完整 make check（记 SKIP 并说明原因）
  --skip-dist        跳过 make dist（记 SKIP）
  --keep-lab         实验测试后不 down（调试用）
  --no-cap-audit     跳过 C0b 最小权限 A/B
  --json FILE        额外输出机器可读结果
  -h, --help         显示帮助

退出码: 0=PASS/KNOWN-FAIL, 1=有 FAIL, 2=用法/环境错误, 3=有 SKIP（验证不完整）
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--build-only)      MODE=build; shift ;;
		--lab-only)        MODE=lab;   shift ;;
		--all)             MODE=all;   shift ;;
		--build-root)      BUILD_ROOT="${2:?}"; shift 2 ;;
		--prefix)          PREFIX="${2:?}"; shift 2 ;;
		--protocols)       PROTOCOLS="${2:?}"; shift 2 ;;
		--jobs)            JOBS="${2:?}"; shift 2 ;;
		--force-build)     FORCE_BUILD=1; shift ;;
		--skip-full-check) SKIP_FULL_CHECK=1; shift ;;
		--skip-dist)       SKIP_DIST=1; shift ;;
		--keep-lab)        KEEP_LAB=1; shift ;;
		--no-cap-audit)    CAP_AUDIT=0; shift ;;
		--json)            JSON_OUT="${2:?}"; shift 2 ;;
		-h|--help)         usage; exit 0 ;;
		*) usage >&2; echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

mkdir -p "$BUILD_ROOT"
HR_BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
export HR_BUILD_ROOT
mkdir -p "$HR_BUILD_ROOT/logs"
HR_LOG_FILE="$HR_BUILD_ROOT/logs/verify.log"
export HR_LOG_FILE
: > "$HR_LOG_FILE"
hr_log_start "$HR_LOG_FILE"

[ -n "$PREFIX" ] || PREFIX="$HR_BUILD_ROOT/prefix"
FRR_BUILD="$HR_BUILD_ROOT/frr-build"
FRR_SRC="$HR_BUILD_ROOT/frr-src"
FP="$HR_BUILD_ROOT/fingerprint.txt"

log "模式       : $MODE"
log "构建根目录 : $HR_BUILD_ROOT"
log "安装前缀   : $PREFIX"
log "并行度     : $JOBS"
# --protocols 的值必须先落到 HR_PROTOCOLS（hr_proto_list 读的是它），否则参数会被静默忽略
HR_PROTOCOLS="$PROTOCOLS"
PROTOS="$(hr_proto_list)"
[ -n "$PROTOS" ] || { echo "--protocols 解析结果为空" >&2; exit 2; }
export HR_PROTOCOLS="$PROTOS"
log "协议       : $(printf '%s ' $PROTOS)"

# ---------------- 结果收集 ----------------
ROWS=()
row_add() { ROWS+=("$(printf '%s\t%s\t%s' "$1" "$2" "$(printf '%s' "$3" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')")"); }
show() { printf '[%-10s] %-34s %s\n' "$1" "$2" "$3"; }
rec_pass()  { row_add PASS "$1" "$2";       show PASS "$1" "$2"; }
rec_fail()  { row_add FAIL "$1" "$2";       show FAIL "$1" "$2"; }
rec_skip()  { row_add SKIP "$1" "$2";       show SKIP "$1" "$2"; }
rec_known() { row_add KNOWN-FAIL "$1" "$2"; show KNOWN-FAIL "$1" "$2"; }

row_status() { printf '%s' "$1" | cut -f1; }
row_name()   { printf '%s' "$1" | cut -f2; }
row_detail() { printf '%s' "$1" | cut -f3; }

count_st() {
	local want="$1" n=0 r
	for r in "${ROWS[@]}"; do
		if [ "$(row_status "$r")" = "$want" ]; then n=$((n + 1)); fi
	done
	printf '%s' "$n"
}

fp_get() {
	[ -f "$FP" ] || { printf ''; return 0; }
	sed -n "s/^$1=//p" "$FP" | head -1 || true
}

# ---------------- A. 仓库完整性 ----------------
phase_repo() {
	log "========== [A] 仓库完整性"
	hr_read_baseline
	rec_pass "A1 BASELINE" "FRR_COMMIT=${FRR_COMMIT:0:12}… ($FRR_DESCRIBE)"

	if [ -f "$HR_REPO_ROOT/patches/frr/SHA256SUMS" ]; then
		local out n
		if out="$( cd "$HR_REPO_ROOT" && sha256sum -c patches/frr/SHA256SUMS 2>&1 )"; then
			n="$(grep -c '^[[:xdigit:]]\{64\}' "$HR_REPO_ROOT/patches/frr/SHA256SUMS" || true)"
			rec_pass "A2 补丁 SHA256" "$n 个补丁文件全部匹配 patches/frr/SHA256SUMS"
		else
			rec_fail "A2 补丁 SHA256" "$out"
		fi
	else
		rec_skip "A2 补丁 SHA256" "仓库缺少 patches/frr/SHA256SUMS"
	fi

	if [ -f "$HR_REPO_ROOT/protocols/egp/evidence/SOURCES.sha256" ]; then
		local out n
		if out="$( cd "$HR_REPO_ROOT" && sha256sum -c protocols/egp/evidence/SOURCES.sha256 2>&1 )"; then
			n="$(grep -c '^[0-9a-f]\{64\}  protocols/' "$HR_REPO_ROOT/protocols/egp/evidence/SOURCES.sha256" || true)"
			rec_pass "A3 协议源码 SHA256" "$n 个文件与迁移基线一致"
		else
			rec_fail "A3 协议源码 SHA256" "$out"
		fi
	else
		rec_skip "A3 协议源码 SHA256" "缺少 protocols/egp/evidence/SOURCES.sha256"
	fi

	# A4 放在源码树就绪之后（见主流程 verify_a4）：干净目录首次运行时还没有 frr-src

	verify_allocations
	verify_secret_scan
}

# A6：多协议资源分配检查（路由类型/显示码/vtysh 位/daemon 名不许重复，且与补丁一致）
verify_allocations() {
	local out="$HR_BUILD_ROOT/logs/allocations.log" rc=0
	if [ -d "$FRR_SRC/.git" ]; then
		"$HR_REPO_ROOT/scripts/check-allocations.sh" --frr "$FRR_SRC" >"$out" 2>&1 || rc=$?
	else
		"$HR_REPO_ROOT/scripts/check-allocations.sh" >"$out" 2>&1 || rc=$?
	fi
	if [ "$rc" = 0 ]; then
		rec_pass "A6 多协议资源分配" "$(grep -m1 '^汇总:' "$out" | sed 's/^汇总: //' || echo 通过)"
	else
		rec_fail "A6 多协议资源分配" "$(grep -E '^\[FAIL\]' "$out" | head -3 | tr '\n' ' ')"
	fi
	return 0
}

verify_patch_replay() {
	local wt p n=0 changed
	wt="$(mktemp -d "$HR_BUILD_ROOT/.verify-wt.XXXXXX")"
	if ! git -C "$FRR_SRC" worktree add --detach "$wt/tree" "$FRR_COMMIT" >>"$HR_LOG_FILE" 2>&1; then
		rm -rf -- "$wt"
		rec_fail "A4 补丁顺序应用" "git worktree add 失败（无法在 ${FRR_COMMIT:0:12} 上建临时工作树）"
		return 0
	fi
	while IFS= read -r p; do
		n=$((n + 1))
		if ! git -C "$wt/tree" apply --check "$p" >>"$HR_LOG_FILE" 2>&1 \
			|| ! git -C "$wt/tree" apply "$p" >>"$HR_LOG_FILE" 2>&1; then
			rec_fail "A4 补丁顺序应用" "第 $n 个补丁失败: $(basename "$p")"
			git -C "$FRR_SRC" worktree remove --force "$wt/tree" >>"$HR_LOG_FILE" 2>&1 || rm -rf -- "$wt/tree"
			rm -rf -- "$wt"
			return 0
		fi
	done < <(hr_patch_list)
	changed="$(git -C "$wt/tree" diff --numstat | wc -l)"
	rec_pass "A4 补丁顺序应用" "$n 个补丁在 ${FRR_COMMIT:0:12} 上顺序 apply 成功，改动 $changed 个文件"
	git -C "$FRR_SRC" worktree remove --force "$wt/tree" >>"$HR_LOG_FILE" 2>&1 || rm -rf -- "$wt/tree"
	rm -rf -- "$wt"
	return 0
}

verify_a4() {
	if [ -d "$FRR_SRC/.git" ]; then
		verify_patch_replay
	else
		rec_skip "A4 补丁顺序应用" "尚无 $FRR_SRC：无法在基线上重放补丁（先让构建拉取源码，再重跑本脚本）"
	fi
	return 0
}

verify_secret_scan() {
	local pat hits
	# 只匹配"高置信度"凭据形态。不含 sshpass/toor 之类裸词：它们会命中扫描器自身
	# 和发布清单里的说明文字，造成自我命中。
	pat='-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|password[[:space:]]*=[[:space:]]*[^[:space:]]'
	hits="$( cd "$HR_REPO_ROOT" && grep -rInE "$pat" \
		--include='*.sh' --include='*.py' --include='*.md' --include='*.c' --include='*.h' \
		--include='*.am' --include='*.patch' --include='*.example' --include='*.yml' \
		--exclude='verify.sh' . 2>/dev/null || true )"
	if [ -z "$hits" ]; then
		rec_pass "A5 敏感信息扫描" "无私钥块/令牌/口令赋值命中（.sh .py .md .c .h .am .patch .example .yml）"
	else
		rec_fail "A5 敏感信息扫描" "$(head -5 <<<"$hits")"
	fi
	return 0
}

# ---------------- B. 构建与产物 ----------------
fp_matches_current() {
	[ -f "$FP" ] || return 1
	[ "$(fp_get FRR_COMMIT)" = "$FRR_COMMIT" ] || return 1
	local p base f src proto
	while IFS= read -r p; do
		base="$(basename "$p")"
		[ "$(fp_get "PATCH_${base} sha256")" = "$(hr_sha256 "$p")" ] || { log "  指纹不匹配: $base"; return 1; }
	done < <(hr_patch_list)
	for proto in $PROTOS; do
		hr_proto_load "$proto"
		for f in $P_SOURCES; do
			src="$HR_REPO_ROOT/protocols/$proto/src/$f"
			[ "$(fp_get "PROTO_SRC_${f}_SHA256")" = "$(hr_sha256 "$src")" ] || { log "  指纹不匹配: $f"; return 1; }
		done
		for f in test_packet.c "$P_DAEMON.subdir.am"; do
			src="$HR_REPO_ROOT/protocols/$proto/tests/$f"
			[ -f "$src" ] || src="$HR_REPO_ROOT/protocols/$proto/build/$f"
			[ "$(fp_get "PROTO_SRC_${f}_SHA256")" = "$(hr_sha256 "$src")" ] || { log "  指纹不匹配: $f"; return 1; }
		done
	done
	return 0
}

phase_build() {
	log "========== [B] 构建与产物"

	local need=1
	if [ "$FORCE_BUILD" = 0 ] && fp_matches_current; then need=0; fi
	if [ "$need" = 1 ]; then
		log "执行 scripts/build.sh（真实构建）"
		local rc=0 args
		args=(--jobs "$JOBS" --build-root "$HR_BUILD_ROOT" --prefix "$PREFIX")
		[ "$SKIP_DIST" = 1 ] && args+=(--skip-dist)
		"$HR_REPO_ROOT/scripts/build.sh" "${args[@]}" >>"$HR_LOG_FILE" 2>&1 || rc=$?
		if [ "$rc" = 0 ] && [ -f "$FP" ]; then
			rec_pass "B1 构建" "build.sh 全流程成功（fetch→patch→integrate→configure→make→单测→check→dist→install→指纹）"
		else
			rec_fail "B1 构建" "build.sh rc=$rc，见 $HR_LOG_FILE"
			return 0
		fi
	else
		rec_pass "B1 构建" "复用已有构建：指纹与当前 BASELINE/补丁/核心源码一致（未重复编译）"
	fi

	local b missing="" bad="" wants=""
	for proto in $PROTOS; do
		hr_proto_load "$proto"
		wants="$wants sbin/$P_DAEMON:PROTOCOL_${P_NAME^^}_BINARY_SHA256"
	done
	wants="sbin/zebra:ZEBRA_BINARY_SHA256 bin/vtysh:VTYSH_BINARY_SHA256 $wants"
	for w in $wants; do
		[ -x "$PREFIX/${w%%:*}" ] || missing="$missing ${w%%:*}"
	done
	if ! find "$PREFIX" -maxdepth 3 -name 'libfrr.so.0' -print -quit 2>/dev/null | grep -q .; then
		missing="$missing libfrr.so.0"
	fi
	if [ -n "$missing" ]; then
		rec_fail "B2 产物与依赖" "前缀缺少:$missing"
		return 0
	fi
	for w in $wants; do
		if LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/frr" ldd "$PREFIX/${w%%:*}" 2>/dev/null | grep -q 'not found'; then
			bad="$bad ${w%%:*}"
		fi
	done
	if [ -z "$bad" ]; then
		rec_pass "B2 产物与依赖" "$(printf '%s ' $PROTOS)daemon + zebra + vtysh + libfrr 均在，ldd 全部可解析"
	else
		rec_fail "B2 产物与依赖" "依赖缺失:$bad"
	fi

	local w key path want got mismatch=""
	for w in $wants; do
		path="${w%%:*}"; key="${w##*:}"
		want="$(fp_get "$key")"
		got="$(hr_sha256 "$PREFIX/$path")"
		if [ -z "$want" ] || [ "$want" != "$got" ]; then mismatch="$mismatch $path"; fi
	done
	if [ -z "$mismatch" ]; then
		rec_pass "B3 产物与指纹一致" "每个二进制 SHA256 都与 fingerprint.txt 相符（$(printf '%s ' $PROTOS)daemon/zebra/vtysh）"
	else
		rec_fail "B3 产物与指纹一致" "指纹不符:$mismatch"
	fi

	local rt="$FRR_BUILD/lib/route_types.h" id exp=32 all_id max_id
	if [ -f "$rt" ]; then
		local okk=1 detail=""
		for proto in $PROTOS; do
			hr_proto_load "$proto"
			id="$(awk '/^#define '"$P_ROUTE_TYPE"'[[:space:]]/{print $3}' "$rt")"
			detail="$detail $P_ROUTE_TYPE=$id"
			[ "$id" = "$exp" ] || okk=0
			exp=$((exp + 1))
		done
		all_id="$(awk '/^#define ZEBRA_ROUTE_ALL[[:space:]]/{print $3}' "$rt")"
		max_id="$(awk '/^#define ZEBRA_ROUTE_MAX[[:space:]]/{print $3}' "$rt")"
		[ "$all_id" = "$exp" ] || okk=0
		[ "$max_id" = "$((exp + 1))" ] || okk=0
		if [ "$okk" = 1 ]; then
			rec_pass "B4 路由类型" "$(printf '%s' "$detail" | sed 's/^ //'), ZEBRA_ROUTE_ALL=$all_id, MAX=$max_id（登记顺序编号）"
		else
			rec_fail "B4 路由类型" "编号与登记顺序不符：$(printf '%s' "$detail" | sed 's/^ //'), ALL=$all_id, MAX=$max_id"
		fi
	else
		rec_skip "B4 路由类型" "没有 $rt（构建树不在本机）"
	fi

	if [ -d "$FRR_BUILD" ]; then
		verify_unit_test
		verify_check_tests
		verify_full_check
	else
		rec_skip "B5 EGP 单元测试" "没有构建树 $FRR_BUILD"
		rec_skip "B6 make check-TESTS" "没有构建树 $FRR_BUILD"
		rec_skip "B7 完整 make check" "没有构建树 $FRR_BUILD"
	fi

	verify_dist
	return 0
}

verify_unit_test() {
	local out="$HR_BUILD_ROOT/logs/verify-unit-test.log" rc=0 proto
	: > "$out"
	for proto in $PROTOS; do
		hr_proto_load "$proto"
		( cd "$FRR_BUILD" && make "$P_TEST_BINARY" && "./$P_TEST_BINARY" ) >>"$out" 2>&1 || rc=$?
		grep -q 'tests passed' "$out" || rc=1
	done
	if [ "$rc" = 0 ]; then
		rec_pass "B5 单元测试" "$(printf '%s ' $PROTOS)的 test_packet 现场执行通过（$(grep -c 'tests passed' "$out") 个测试程序）"
	else
		rec_fail "B5 单元测试" "rc=$rc，见 $out"
	fi
	return 0
}

verify_check_tests() {
	local log="$HR_BUILD_ROOT/logs/verify-check-tests.log" rc=0 total pass_n fail_n proto miss="" names=""
	( cd "$FRR_BUILD" && make check-TESTS ) >"$log" 2>&1 || rc=$?
	total="$(grep -m1 '^# TOTAL:' "$log" | awk '{print $3}' || true)"
	pass_n="$(grep -m1 '^# PASS:' "$log" | awk '{print $3}' || true)"
	fail_n="$(grep -m1 '^# FAIL:' "$log" | awk '{print $3}' || true)"
	for proto in $PROTOS; do
		hr_proto_load "$proto"
		names="$names $P_TEST_BINARY"
		grep -qE "^PASS: $P_TEST_BINARY$" "$log" || miss="$miss $P_TEST_BINARY"
	done
	if [ "$rc" = 0 ] && [ -z "$miss" ] && [ "${fail_n:-1}" = 0 ]; then
		rec_pass "B6 make check-TESTS" "PASS:$(printf '%s' "$names")（TOTAL=${total:-?} PASS=${pass_n:-?} FAIL=0）"
	else
		rec_fail "B6 make check-TESTS" "rc=$rc 未出现PASS:$miss TOTAL=${total:-?} PASS=${pass_n:-?} FAIL=${fail_n:-?}，见 $log"
	fi
	return 0
}

verify_full_check() {
	if [ "$SKIP_FULL_CHECK" = 1 ]; then
		rec_skip "B7 完整 make check" "--skip-full-check 指定跳过（已知 14 项与 --disable 的 daemon 相关，见 docs/known-failures.md）"
		return 0
	fi
	local log="$HR_BUILD_ROOT/logs/verify-make-check.log" rc=0 summary tsv md disabled unclassified nknown
	( cd "$FRR_BUILD" && make -j"$JOBS" check ) >"$log" 2>&1 || rc=$?
	if [ -f "$FRR_BUILD/test-suite.log" ]; then
		cp -f "$FRR_BUILD/test-suite.log" "$HR_BUILD_ROOT/logs/test-suite.log"
	fi
	summary="$(grep -E '^=+ [0-9]+ (failed|passed)' "$log" | tail -1 | sed 's/^=* //; s/ =*$//' || true)"
	tsv="$HR_BUILD_ROOT/logs/known-failures.tsv"
	md="$HR_REPO_ROOT/docs/known-failures.md"
	disabled="$(sed -n 's/^--disable-//p' "$HR_BUILD_ROOT/logs/configure-args.txt" 2>/dev/null | tr '\n' ' ' || true)"
	# shellcheck disable=SC2086
	if ! python3 "$HR_REPO_ROOT/scripts/parse-make-check.py" "$log" "$tsv" "$md" $disabled; then
		rec_fail "B7 完整 make check" "日志解析失败，见 $log"
		return 0
	fi
	unclassified="$(awk -F'\t' '$1=="UNCLASSIFIED" {print $2}' "$tsv" | tr '\n' ' ' || true)"
	nknown="$(awk -F'\t' '$1=="KNOWN"' "$tsv" | wc -l || true)"
	if [ "$rc" = 0 ]; then
		rec_pass "B7 完整 make check" "make check rc=0（$summary）"
	elif [ -z "$unclassified" ]; then
		rec_known "B7 完整 make check" "原始 rc=$rc 保留；$nknown 项失败的直接证据都是「被 --disable 的模块缺少可执行文件」，逐条见 docs/known-failures.md（$summary）"
	else
		rec_fail "B7 完整 make check" "rc=$rc；无法归因的失败:$unclassified（见 docs/known-failures.md）"
	fi
	return 0
}

verify_dist() {
	if [ "$SKIP_DIST" = 1 ]; then
		rec_skip "B8 make dist" "--skip-dist 指定跳过"
		return 0
	fi
	if [ ! -d "$FRR_BUILD" ]; then
		rec_skip "B8 make dist" "没有构建树 $FRR_BUILD"
		return 0
	fi
	local tarball list f missing="" rc=0
	tarball="$(ls -1t "$FRR_BUILD"/*.tar.gz 2>/dev/null | head -1 || true)"
	if [ -z "$tarball" ]; then
		( cd "$FRR_BUILD" && make -j"$JOBS" dist ) >"$HR_BUILD_ROOT/logs/verify-make-dist.log" 2>&1 || rc=$?
		tarball="$(ls -1t "$FRR_BUILD"/*.tar.gz 2>/dev/null | head -1 || true)"
	fi
	if [ "$rc" != 0 ] || [ -z "$tarball" ]; then
		rec_fail "B8 make dist" "rc=$rc，未找到 tarball"
		return 0
	fi
	list="$HR_BUILD_ROOT/logs/verify-dist-contents.txt"
	if ! tar tzf "$tarball" >"$list"; then
		rec_fail "B8 make dist" "无法读取 $(basename "$tarball")"
		return 0
	fi
	local files=""
	for proto in $PROTOS; do
		hr_proto_load "$proto"
		for f in $P_SOURCES; do files="$files $P_DAEMON/$f"; done
		files="$files $P_DAEMON/test_packet.c $P_DAEMON/subdir.am $P_DAEMON/README.md"
	done
	for f in $files; do
		grep -q "/$f$" "$list" || missing="$missing $f"
	done
	if [ -z "$missing" ]; then
		rec_pass "B8 make dist" "$(basename "$tarball") $(du -h "$tarball" | cut -f1)，$(printf '%s ' $PROTOS)的源码与 automake 片段齐全"
	else
		rec_fail "B8 make dist" "包内缺少:$missing"
	fi
	return 0
}

# ---------------- C. 实验环境 ----------------
phase_lab() {
	log "========== [C] 实验环境"
	if ! printf '%s\n' $PROTOS | grep -qx 'egp'; then
		rec_skip "C0 实验前置" "容器实验目前只覆盖 EGP；--protocols 里没有 egp，跳过 C 段"
		return 0
	fi
	if ! command -v podman >/dev/null 2>&1; then
		rec_skip "C0 实验前置" "本机没有 podman"
		return 0
	fi
	local labdir="$HR_REPO_ROOT/lab/egp"
	if [ ! -x "$labdir/lab.sh" ]; then
		rec_fail "C0 实验前置" "缺少 $labdir/lab.sh"
		return 0
	fi

	local image prefix mount env_out
	# 参数从 lab.sh env 读（这样 lab.env 的覆盖也生效，且不需要在 verify 里重复解析）
	env_out="$( cd "$labdir" && ./lab.sh env 2>/dev/null || true )"
	image="$( sed -n 's/^LAB_IMAGE=\([^ ]*\).*/\1/p' <<<"$env_out" | head -1 )"
	prefix="$( sed -n 's/^LAB_PREFIX=\([^ ]*\).*/\1/p' <<<"$env_out" | head -1 )"
	mount="$( sed -n 's/.*LAB_MOUNT=\([^ ]*\).*/\1/p' <<<"$env_out" | head -1 )"
	if [ -z "$image" ] || [ -z "$prefix" ] || [ -z "$mount" ]; then
		rec_fail "C0 实验前置" "无法从 lab.sh env 解析参数（image='$image' prefix='$prefix' mount='$mount'）"
		return 0
	fi

	if podman image exists "$image" 2>/dev/null; then
		rec_pass "C0 实验前置" "podman $(podman --version | awk '{print $3}')，镜像 $image 已存在"
	else
		local rc=0
		( cd "$labdir" && ./lab.sh build ) >>"$HR_LOG_FILE" 2>&1 || rc=$?
		if [ "$rc" = 0 ]; then
			rec_pass "C0 实验前置" "镜像不存在 → 由 Containerfile 现场构建成功（$image）"
		else
			rec_fail "C0 实验前置" "镜像缺失且构建失败（见 $HR_LOG_FILE）"
			return 0
		fi
	fi

	if [ "$CAP_AUDIT" = 1 ]; then verify_cap_audit "$image" "$prefix" "$mount"; fi

	local rc=0 out
	out="$( cd "$labdir" && ./lab.sh up 2>&1 )" || rc=$?
	printf '%s\n' "$out" >>"$HR_LOG_FILE"
	if [ "$rc" = 0 ]; then
		rec_pass "C1 实验启动" "$(grep -o '两端 EGP 邻居均已 Up（约 [0-9]*s）' <<<"$out" | head -1 || echo 'up 成功')"
	else
		rec_fail "C1 实验启动" "lab.sh up rc=$rc：$(tail -3 <<<"$out")"
		( cd "$labdir" && ./lab.sh down ) >>"$HR_LOG_FILE" 2>&1 || true
		return 0
	fi

	rc=0
	out="$( cd "$labdir" && ./lab.sh up 2>&1 )" || rc=$?
	printf '%s\n' "$out" >>"$HR_LOG_FILE"
	if [ "$rc" != 0 ] && grep -qiE '已经存在|已存在|exists' <<<"$out"; then
		rec_pass "C2 重复 up 拒绝" "第二次 up 被拒绝（rc=$rc）：$(grep -iE '已经存在|已存在|exists' <<<"$out" | head -1)"
	else
		rec_fail "C2 重复 up 拒绝" "重复 up 未被拒绝（rc=$rc）：$(tail -2 <<<"$out")"
	fi

	rc=0
	out="$( cd "$labdir" && ./lab.sh test 2>&1 )" || rc=$?
	printf '%s\n' "$out" >>"$HR_LOG_FILE"
	local line
	line="$(grep -E '^汇总:' <<<"$out" | tail -1 || true)"
	if [ "$rc" = 0 ] && [ -n "$line" ]; then
		rec_pass "C3 集成测试" "$line（12 项 + 收尾校验，逐项断言真实状态）"
	elif [ -n "$line" ]; then
		rec_fail "C3 集成测试" "$line；$(grep -E '^  \[FAIL\]' <<<"$out" | head -3 || true)"
	else
		rec_fail "C3 集成测试" "rc=$rc，未得到汇总行"
	fi

	if [ "$KEEP_LAB" = 1 ]; then
		rec_skip "C4 异常中断后清理" "--keep-lab 指定保留实验，跳过"
		rec_skip "C5 清理验证" "--keep-lab 指定保留实验，跳过"
		rec_skip "C6 重复 down 幂等" "--keep-lab 指定保留实验，跳过"
		return 0
	fi

	rc=0
	podman kill "egp-lab-r2" >/dev/null 2>&1 || true
	out="$( cd "$labdir" && ./lab.sh down 2>&1 )" || rc=$?
	printf '%s\n' "$out" >>"$HR_LOG_FILE"
	if [ "$rc" = 0 ]; then
		rec_pass "C4 异常中断后清理" "先 podman kill 掉一个容器，down 仍成功（rc=0）"
	else
		rec_fail "C4 异常中断后清理" "down rc=$rc：$(tail -3 <<<"$out")"
	fi

	local leftover=""
	if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^egp-lab'; then leftover="$leftover 容器"; fi
	if podman network ls --format '{{.Name}}' 2>/dev/null | grep -qx 'egp-lab-net'; then leftover="$leftover 网络"; fi
	if pgrep -x zebra >/dev/null 2>&1; then leftover="$leftover 宿主机zebra"; fi
	if pgrep -x egpd >/dev/null 2>&1; then leftover="$leftover 宿主机egpd"; fi
	if ip -4 route 2>/dev/null | grep -qE '^(10\.0\.0\.0/8|172\.16\.0\.0/16)'; then leftover="$leftover 宿主机路由"; fi
	if [ -z "$leftover" ]; then
		rec_pass "C5 清理验证" "无实验容器/网络、无 zebra/egpd 进程、宿主机无 10/8 与 172.16/16 路由"
	else
		rec_fail "C5 清理验证" "清理后仍有残留:$leftover"
	fi

	rc=0
	out="$( cd "$labdir" && ./lab.sh down 2>&1 )" || rc=$?
	if [ "$rc" = 0 ]; then
		rec_pass "C6 重复 down 幂等" "资源已不存在时 down 仍返回 0"
	else
		rec_fail "C6 重复 down 幂等" "rc=$rc：$(tail -2 <<<"$out")"
	fi
	return 0
}

# 最小权限 A/B：证明 zebra 编译期声明的能力集确实需要 SYS_ADMIN
verify_cap_audit() {
	local image="$1" host_prefix="$2" mount="$3"
	local pidir="$HR_BUILD_ROOT/.cap-audit"
	if [ -z "$host_prefix" ] || [ -z "$mount" ] || [ ! -d "$host_prefix" ]; then
		rec_skip "C0b 最小权限 A/B" "拿不到宿主安装前缀或容器挂载点（prefix='$host_prefix' mount='$mount'）"
		return 0
	fi
	# 前缀是只读挂载，zebra 需要 var/ 与 run/ 存在才能被 tmpfs 盖住。
	# lab.sh 的 check_prefix 会在 up 时创建；这里先建成同样的条件，保证 A/B 与实验一致。
	mkdir -p "$host_prefix/var" "$host_prefix/run"
	rm -rf -- "$pidir"; mkdir -p "$pidir/run"
	printf 'hostname capaudit\nlog stdout\n' > "$pidir/zebra.conf"

	local common=(--rm --network none --security-opt label=disable
		-v "$host_prefix:$mount:ro" -v "$pidir:/cfg"
		--tmpfs "$mount/var:rw,mode=1777" --tmpfs "$mount/run:rw,mode=1777")
	local out_no out_yes
	out_no="$(podman run "${common[@]}" --cap-add NET_ADMIN --cap-add NET_RAW "$image" \
		sh -c "timeout 4 $mount/sbin/zebra -u root -g root -f /cfg/zebra.conf -i /cfg/run/zebra.pid -z /cfg/run/zserv.api --vty_socket /cfg/run 2>&1; echo 退出码=\$?" 2>&1 || true)"
	out_yes="$(podman run "${common[@]}" --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN "$image" \
		sh -c "timeout 4 $mount/sbin/zebra -u root -g root -f /cfg/zebra.conf -i /cfg/run/zebra.pid -z /cfg/run/zserv.api --vty_socket /cfg/run 2>&1; echo 退出码=\$?" 2>&1 || true)"

	local ev="$HR_REPO_ROOT/docs/evidence/sys-admin-ab.txt"
	mkdir -p "$(dirname "$ev")"
	{
		echo "# zebra 最小权限 A/B（scripts/verify.sh 现场执行）"
		echo "时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo
		echo "## 只给 NET_ADMIN + NET_RAW"
		printf '%s\n' "$out_no"
		echo
		echo "## 再加 SYS_ADMIN"
		printf '%s\n' "$out_yes"
	} >"$ev"

	if grep -q 'cap_set_proc' <<<"$out_no" && ! grep -q 'cap_set_proc' <<<"$out_yes"; then
		rec_pass "C0b 最小权限 A/B" "无 SYS_ADMIN 时 privs_init 失败、加上后正常启动 → 最小集是 NET_ADMIN+NET_RAW+SYS_ADMIN（docs/evidence/sys-admin-ab.txt）"
	elif ! grep -q 'cap_set_proc' <<<"$out_no"; then
		rec_skip "C0b 最小权限 A/B" "未观察到 cap_set_proc 失败，结论待人工确认（docs/evidence/sys-admin-ab.txt）"
	else
		rec_fail "C0b 最小权限 A/B" "两组都报 cap_set_proc 失败（docs/evidence/sys-admin-ab.txt）"
	fi
	rm -rf -- "$pidir"
	return 0
}

# ---------------- 主流程 ----------------
phase_repo
case "$MODE" in
	build) phase_build; verify_a4 ;;
	lab)   verify_a4; phase_lab ;;
	all)   phase_build; verify_a4; phase_lab ;;
esac

P_N="$(count_st PASS)"; F_N="$(count_st FAIL)"; S_N="$(count_st SKIP)"; K_N="$(count_st KNOWN-FAIL)"
{
	echo
	echo "================ 汇总 ================"
	printf 'PASS %3s   KNOWN-FAIL %3s   SKIP %3s   FAIL %3s\n' "$P_N" "$K_N" "$S_N" "$F_N"
	for r in "${ROWS[@]}"; do
		printf '[%-10s] %-34s %s\n' "$(row_status "$r")" "$(row_name "$r")" "$(row_detail "$r")"
	done
} | tee -a "$HR_LOG_FILE"

if [ -n "$JSON_OUT" ]; then
	{
		echo "{"
		printf '  "mode": "%s",\n' "$MODE"
		printf '  "counts": {"pass": %s, "known_fail": %s, "skip": %s, "fail": %s},\n' "$P_N" "$K_N" "$S_N" "$F_N"
		echo '  "results": ['
		first=1
		for r in "${ROWS[@]}"; do
			if [ "$first" = 1 ]; then first=0; else echo ","; fi
			printf '    {"status": "%s", "name": "%s", "detail": "%s"}' \
				"$(row_status "$r")" "$(row_name "$r" | sed 's/"/\\"/g')" "$(row_detail "$r" | sed 's/"/\\"/g')"
		done
		echo
		echo "  ]"
		echo "}"
	} >"$JSON_OUT"
	log "JSON: $JSON_OUT"
fi

log "完整日志: $HR_LOG_FILE"
if [ "$F_N" -gt 0 ]; then
	log "结果: FAIL（$F_N 项）"
	exit 1
elif [ "$S_N" -gt 0 ]; then
	log "结果: 未完整验证（SKIP $S_N 项 / PASS $P_N 项 / KNOWN-FAIL $K_N 项）"
	exit 3
else
	log "结果: PASS（$P_N 项通过，$K_N 项 KNOWN-FAIL）"
	exit 0
fi
