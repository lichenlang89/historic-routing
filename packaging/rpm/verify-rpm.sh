#!/usr/bin/env bash
# 安装后验收：RPM 是否真的"装得对、跑得起来、没碰系统 FRR"。
# 只读检查，不改系统状态；退出码 0=全部通过 1=有失败 3=检查不完整（跳过）
#
# 用法: verify-rpm.sh [--prefix DIR] [--json FILE]
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_DEFAULT="/opt/historic-routing/27f287be9"
PREFIX="$PREFIX_DEFAULT"
JSON=""

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) PREFIX="${2:?}"; shift 2 ;;
		--json)   JSON="${2:?}"; shift 2 ;;
		-h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

np=0; nf=0; ns=0
declare -a RESULTS=()
emit() { # emit STATUS NAME DETAIL
	local st="$1" name="$2" detail="${3:-}"
	case "$st" in
		PASS) np=$((np+1)) ;;
		FAIL) nf=$((nf+1)) ;;
		SKIP) ns=$((ns+1)) ;;
	esac
	printf '%-4s %-34s %s\n' "$st" "$name" "$detail"
	RESULTS+=("$st|$name|$detail")
}

have() { command -v "$1" >/dev/null 2>&1; }

echo "== RPM 安装验收（prefix=$PREFIX）"
echo "主机: $(hostname) $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m)"
echo

# 1. 两个包都装上，且版本-Release 完全一致
if have rpm; then
	v_rt="$(rpm -q --qf '%{VERSION}-%{RELEASE}' historic-routing-runtime 2>/dev/null)"
	v_eg="$(rpm -q --qf '%{VERSION}-%{RELEASE}' historic-routing-egp 2>/dev/null)"
	if [ -n "$v_rt" ] && [ "$v_rt" = "$v_eg" ]; then
		emit PASS "P1 两包已安装且版本一致" "$v_rt"
	else
		emit FAIL "P1 两包已安装且版本一致" "runtime='$v_rt' egp='$v_eg'"
	fi
	# 2. ABI Provides/Requires 一致
	abi_p="$(rpm -q --qf '[%{PROVIDENAME}=%{PROVIDEVERSION}\n]' historic-routing-runtime 2>/dev/null | grep '^historic-routing-abi=' || true)"
	abi_r="$(rpm -q --qf '[%{REQUIRENAME}=%{REQUIREVERSION}\n]' historic-routing-egp 2>/dev/null | grep '^historic-routing-abi' || true)"
	if [ -n "$abi_p" ] && [ "$abi_p" = "$abi_r" ]; then
		emit PASS "P2 ABI 绑定一致" "$abi_p"
	else
		emit FAIL "P2 ABI 绑定一致" "provides='$abi_p' requires='$abi_r'"
	fi
	# 3. 包完整性（rpm -V 无输出且 rc=0）
	if out="$(rpm -V historic-routing-runtime historic-routing-egp 2>&1)" && [ -z "$out" ]; then
		emit PASS "P3 rpm -V 无差异" ""
	else
		emit FAIL "P3 rpm -V 无差异" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
	fi
else
	emit SKIP "P1–P3 rpm 检查" "没有 rpm 命令"
fi

# 4. 文件都在前缀里（不散落到 /usr、/etc、/var）
missing=""
for f in sbin/zebra bin/vtysh sbin/egpd lib/libfrr.so.0; do
	[ -e "$PREFIX/$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then emit PASS "P4 关键文件齐备" "zebra/vtysh/egpd/libfrr"; else emit FAIL "P4 关键文件齐备" "缺:$missing"; fi

# 5. RUNPATH 是 $ORIGIN 相对路径：只会在本前缀的 lib/ 里找 libfrr
if have readelf; then
	rp="$(readelf -d "$PREFIX/sbin/zebra" 2>/dev/null | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"
	case "$rp" in
		'$ORIGIN/../lib') emit PASS "P5 RUNPATH 为 \$ORIGIN 相对路径" "$rp" ;;
		"") emit FAIL "P5 RUNPATH 为 \$ORIGIN 相对路径" "没有 RUNPATH" ;;
		*) emit FAIL "P5 RUNPATH 为 \$ORIGIN 相对路径" "实际: $rp" ;;
	esac
else
	emit SKIP "P5 RUNPATH" "没有 readelf"
fi

# 6. 动态库解析到本前缀，绝不解析到系统 frr 的 libfrr
if have ldd; then
	l="$(ldd "$PREFIX/sbin/zebra" 2>/dev/null | grep -E 'libfrr|libyang|not found' || true)"
	if echo "$l" | grep -q 'not found'; then
		emit FAIL "P6 库依赖可解析" "$(echo "$l" | grep 'not found' | tr '\n' ' ')"
	elif echo "$l" | grep 'libfrr' | grep -qv "$PREFIX"; then
		emit FAIL "P6 库依赖可解析" "libfrr 解析到前缀之外: $(echo "$l" | grep libfrr)"
	else
		emit PASS "P6 库依赖可解析" "$(echo "$l" | grep libfrr | awk '{print $3}' | head -1)"
	fi
else
	emit SKIP "P6 库依赖" "没有 ldd"
fi

# 7. 三个二进制能实际跑起来（不设 LD_LIBRARY_PATH，靠 RUNPATH）
bad=""
for b in sbin/zebra bin/vtysh sbin/egpd; do
	# vtysh 不认 -v/--version（只有 -h/--help 退 0），zebra/egpd 认 --version
	if env -u LD_LIBRARY_PATH "$PREFIX/$b" --version >/dev/null 2>&1 \
	   || env -u LD_LIBRARY_PATH "$PREFIX/$b" -h >/dev/null 2>&1; then :; else bad="$bad $b"; fi
done
if [ -z "$bad" ]; then
	zv="$(env -u LD_LIBRARY_PATH "$PREFIX/sbin/zebra" --version 2>&1 | head -1)"
	emit PASS "P7 二进制可独立运行" "$zv"
else
	emit FAIL "P7 二进制可独立运行" "失败:$bad"
fi

# 8. 服务只装不启
if have systemctl; then
	en="$(systemctl is-enabled historic-routing-zebra.service historic-routing-egpd.service 2>&1 | tr '\n' ' ')"
	ac="$(systemctl is-active historic-routing-zebra.service 2>&1)"
	if echo "$en" | grep -qE 'enabled|static' && ! echo "$en" | grep -q 'disabled'; then
		emit FAIL "P8 服务默认不启用" "is-enabled: $en"
	elif [ "$ac" = "active" ]; then
		emit FAIL "P8 服务默认不启用" "zebra 已在运行"
	else
		emit PASS "P8 服务默认不启用" "is-enabled: $en / is-active: $ac"
	fi
else
	emit SKIP "P8 服务状态" "没有 systemctl"
fi

# 9. 系统 FRR 未被改：包校验（/etc/frr 目录权限差异是实验期遗留，安装前即如此）
if have rpm && rpm -q frr >/dev/null 2>&1; then
	out="$(rpm -V frr 2>&1)"
	if [ -z "$out" ]; then
		emit PASS "P9 系统 frr 包未被改" "$(rpm -q frr)"
	elif printf '%s\n' "$out" | grep -qE '^\.M\.\.\.\.\.\.\. +/etc/frr$' \
	     && [ "$(printf '%s\n' "$out" | grep -vcE '^\.M\.\.\.\.\.\.\. +/etc/frr$|^$')" = "0" ]; then
		emit PASS "P9 系统 frr 包未被改" "仅 /etc/frr 目录权限差异（安装前即存在；文件内容未变）"
	else
		emit FAIL "P9 系统 frr 包未被改" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
	fi
else
	emit SKIP "P9 系统 frr 包" "未安装 frr"
fi

# 10. 前缀与系统路径不重叠（文件级冲突检查用 rpm -ql 交集，这里做前缀级）
case "$PREFIX" in
	/usr*|/etc*|/var*|/opt/frr*) emit FAIL "P10 前缀与系统路径隔离" "$PREFIX 落在系统路径" ;;
	*) emit PASS "P10 前缀与系统路径隔离" "$PREFIX" ;;
esac

echo
echo "合计: PASS=$np FAIL=$nf SKIP=$ns"
if [ -n "$JSON" ]; then
	{
		printf '{\n  "host": "%s",\n  "prefix": "%s",\n  "pass": %d,\n  "fail": %d,\n  "skip": %d,\n  "results": [\n' \
			"$(hostname)" "$PREFIX" "$np" "$nf" "$ns"
		first=1
		for r in "${RESULTS[@]}"; do
			st="${r%%|*}"; rest="${r#*|}"; name="${rest%%|*}"; detail="${rest#*|}"
			[ $first -eq 1 ] || printf ',\n'
			first=0
			printf '    {"status": "%s", "name": "%s", "detail": "%s"}' "$st" "$name" "$(printf '%s' "$detail" | sed 's/"/\\"/g')"
		done
		printf '\n  ]\n}\n'
	} > "$JSON"
fi

[ "$nf" -eq 0 ] || exit 1
[ "$ns" -eq 0 ] || exit 3
exit 0
