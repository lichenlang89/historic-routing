#!/usr/bin/env bash
# historic-routing 的 Debian 打包入口。
#
# 做的事：
#   1. 从**干净的 git 工作树**用 git archive 取源码快照；
#   2. 把 packaging/debian/ 装成源码树里的 debian/，替换版本/提交/前缀/ABI 宏；
#   3. 调 dpkg-buildpackage（binary-only），debhelper 全流程；
#   4. 对产物做 dpkg-deb -I/-c、依赖检查、SHA256、lintian。
#
# 必须在一个真实的 Debian 环境里运行（dpkg-buildpackage + debhelper + lintian 可用）。
# 在非 Debian 系统上会直接拒绝，不会"生成一个 DEB 就宣称支持 Debian"。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HR_REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

WORK=""
VERSION=""
RUN_LINTIAN=1
KEEP=0
ALLOW_DIRTY=0

usage() {
	cat <<'EOF'
用法: package-deb.sh [选项]

  --work DIR        构建工作目录（默认 <repo>/build-deb）
  --version V       覆盖上游版本（默认 0.1.1~dev<源码短提交>）
  --no-lintian      跳过 lintian
  --allow-dirty     允许工作树脏（不推荐：包必须对应确定的提交）
  --keep            构建成功后保留工作目录
  -h, --help        显示帮助

退出码: 0 成功；1 构建失败；2 环境不满足（不是 Debian / 缺工具）；3 产物检查失败
EOF
}

die() { echo "FAIL $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--work)       WORK="${2:?}"; shift 2 ;;
		--version)    VERSION="${2:?}"; shift 2 ;;
		--no-lintian) RUN_LINTIAN=0; shift ;;
		--allow-dirty) ALLOW_DIRTY=1; shift ;;
		--keep)       KEEP=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		*) usage >&2; echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

log() { printf '%s\n' "$*"; }

# ---------- 0. 环境必须是 Debian ----------
if [ ! -f /etc/debian_version ]; then
	echo "FAIL 当前系统不是 Debian（/etc/debian_version 不存在）。" >&2
	echo "     Debian 包必须在 Debian 环境里构建与验证；请勿在 RHEL 上用 alien 转换。" >&2
	exit 2
fi
for t in dpkg-buildpackage dpkg-deb dpkg-query fakeroot dh_installsystemd; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAIL 缺少工具: $t（apt install debhelper devscripts fakeroot）" >&2; exit 2; }
done
dpkg-query -W -f='${Status}' debhelper 2>/dev/null | grep -q "install ok installed" 	|| { echo "FAIL 没有安装 debhelper（apt install debhelper）" >&2; exit 2; }
DEB_VER="$(cat /etc/debian_version)"
log "== 构建环境: Debian $DEB_VER / $(dpkg --print-architecture) / dpkg $(dpkg-query -W -f='${Version}' dpkg)"

# ---------- 1. 源码提交 ----------
cd "$HR_REPO_ROOT"
if [ -d .git ]; then
	DIRTY="$(git status --porcelain | wc -l)"
	if [ "$ALLOW_DIRTY" = 0 ] && [ "$DIRTY" != 0 ]; then
		die "工作树有 $DIRTY 个未提交改动：DEB 必须对应确定的源码提交（可加 --allow-dirty）"
	fi
	SHA="$(git rev-parse HEAD)"
else
	die "这里不是 git 工作树：请在仓库内运行（构建需要 git archive 出确定的源码快照）"
fi
SHORT="${SHA:0:7}"
FRR_COMMIT="$(sed -n 's/^FRR_COMMIT=//p' patches/frr/BASELINE | head -1)"
[ -n "$FRR_COMMIT" ] || die "patches/frr/BASELINE 里没有 FRR_COMMIT"
FRR_SHORT="${FRR_COMMIT:0:9}"
[ -n "$VERSION" ] || VERSION="0.1.1~dev$SHORT"
DVERSION="$VERSION-1"           # Debian revision 固定为 1（本轮只有开发构建）
PREFIX="/opt/historic-routing/$FRR_SHORT"
ABI="$SHORT-$FRR_SHORT"
RUNSTATEDIR="/run/historic-routing"
STAMP="$(LC_ALL=C date -R)"

log "== 源码提交: $SHA"
log "== Debian 版本: $DVERSION（上游 $VERSION，revision 1）"
log "== 安装前缀: $PREFIX   runstatedir: $RUNSTATEDIR   ABI: $ABI"
log "== FRR 基线: $FRR_COMMIT"

# ---------- 2. 组装源码树 ----------
[ -n "$WORK" ] || WORK="$HR_REPO_ROOT/build-deb"
case "$WORK" in /*) ;; *) WORK="$PWD/$WORK" ;; esac
SRC_PARENT="$WORK/src"
SRC="$SRC_PARENT/historic-routing-$VERSION"
# 安全边界：只删本脚本自己创建的工作目录（必须有标记文件），不做"无保护的 rm -rf"
case "$WORK" in /|""|/root|/home|/usr|/var) die "拒绝把 $WORK 当作工作目录" ;; esac
if [ -d "$WORK" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
	[ -f "$WORK/.hr-deb-work" ] || die "$WORK 非空且不是本脚本的工作目录（缺 .hr-deb-work 标记），拒绝删除"
	rm -rf "$WORK"
fi
mkdir -p "$SRC"
: > "$WORK/.hr-deb-work"
log "== 工作目录: $WORK"

git archive --format=tar HEAD | tar -x -C "$SRC" || die "git archive 失败"
[ -d "$SRC/scripts" ] || die "源码快照不完整（缺 scripts/）"

cp -a "$HR_REPO_ROOT/packaging/debian" "$SRC/debian"
rm -f "$SRC"/debian/*.in.rej 2>/dev/null || true

# ---------- 3. 变量替换 ----------
# changelog 先由模板生成（dpkg 要求 debian/changelog 存在且版本匹配）
sed -e "s|@VERSION@|$DVERSION|g" \
    -e "s|@DATE@|$STAMP|g" \
    -e "s|@COMMIT@|$SHA|g" \
    -e "s|@FRR_COMMIT@|$FRR_COMMIT|g" \
    -e "s|@ABI@|$ABI|g" \
    -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@RUNSTATEDIR@|$RUNSTATEDIR|g" \
    "$SRC/debian/changelog.in" > "$SRC/debian/changelog"
rm -f "$SRC/debian/changelog.in"

# 其余文件统一替换（含 .in 结尾的重命名、rwx 位）
for f in "$SRC"/debian/control.in "$SRC"/debian/rules.in \
         "$SRC"/debian/*.install "$SRC"/debian/*.conffiles "$SRC"/debian/*.docs \
         "$SRC"/debian/*.shlibs.in "$SRC"/debian/*.service.in "$SRC"/debian/config/*.conf; do
	[ -f "$f" ] || continue
	sed -i -e "s|@VERSION@|$DVERSION|g" \
	       -e "s|@COMMIT@|$SHA|g" \
	       -e "s|@FRR_COMMIT@|$FRR_COMMIT|g" \
	       -e "s|@ABI@|$ABI|g" \
	       -e "s|@PREFIX@|$PREFIX|g" \
	       -e "s|@RUNSTATEDIR@|$RUNSTATEDIR|g" "$f"
done
mv "$SRC/debian/control.in" "$SRC/debian/control"
mv "$SRC/debian/rules.in"   "$SRC/debian/rules"
chmod 0755 "$SRC/debian/rules"
mv "$SRC/debian/historic-routing-runtime.shlibs.in" "$SRC/debian/historic-routing-runtime.shlibs"
for f in "$SRC"/debian/*.service.in; do
	[ -f "$f" ] || continue
	mv "$f" "${f%.in}"
done

# 语法自检：不合规就在这里失败，而不是让 dpkg-buildpackage 半途炸
if command -v dpkg-parsechangelog >/dev/null 2>&1; then
	( cd "$SRC" && dpkg-parsechangelog -S Version ) | grep -qx "$DVERSION" \
		|| die "debian/changelog 版本与 $DVERSION 不一致"
fi

# ---------- 4. dpkg-buildpackage ----------
LOG="$WORK/dpkg-buildpackage.log"
log "== 开始 dpkg-buildpackage -b（%build 会从固定 FRR 基线完整构建，约数分钟）"
( cd "$SRC" && dpkg-buildpackage -us -uc -b -tc ) >"$LOG" 2>&1
rc=$?
if [ "$rc" != 0 ]; then
	echo "---- 构建日志尾部 ----"
	tail -40 "$LOG"
	die "dpkg-buildpackage 失败（rc=$rc），完整日志: $LOG"
fi
log "== 构建成功（日志: $LOG）"

# ---------- 5. 产物检查 ----------
shopt -s nullglob
DEBS=( "$SRC_PARENT"/historic-routing-runtime_"$DVERSION"_*.deb
       "$SRC_PARENT"/historic-routing-egp_"$DVERSION"_*.deb )
shopt -u nullglob
[ "${#DEBS[@]}" -eq 2 ] || die "产物数量不对（期望 2 个 .deb，实际 ${#DEBS[@]}）：${DEBS[*]:-无}"

check_fail=0
for d in "${DEBS[@]}"; do
	echo
	echo "================ $(basename "$d")"
	stat -c '大小   : %s bytes' "$d"
	sha256sum "$d"
	echo "---- dpkg-deb -I（元数据）"
	dpkg-deb -I "$d" | sed -n '1,40p'
	echo "---- dpkg-deb -c（文件清单）"
	dpkg-deb -c "$d" | awk '{print $1, $3, $6}'
done

# 依赖自检：私有 libfrr 必须由 runtime 提供，egp 必须精确依赖 runtime
RT_DEB=$(printf '%s\n' "${DEBS[@]}" | grep runtime)
EG_DEB=$(printf '%s\n' "${DEBS[@]}" | grep egp)
DEP_EG=$(dpkg-deb -f "$EG_DEB" Depends)
echo
echo "================ 依赖自检"
echo "egp Depends: $DEP_EG"
case "$DEP_EG" in
	*"historic-routing-runtime (= $DVERSION)"*) log "PASS egp 精确依赖 runtime 的同一版本" ;;
	*) log "FAIL egp 没有精确依赖 runtime (= $DVERSION)"; check_fail=1 ;;
esac
case "$DEP_EG" in
	*"historic-routing-abi"*) log "PASS egp 依赖 ABI 标识" ;;
	*) log "FAIL egp 缺 historic-routing-abi 依赖"; check_fail=1 ;;
esac
if dpkg-deb -f "$RT_DEB" Depends | grep -q "libfrr"; then
	log "FAIL runtime 依赖里出现 libfrr（应只由本包自带）"
	check_fail=1
else
	log "PASS runtime 不依赖外部 libfrr"
fi
if dpkg-deb -f "$RT_DEB" Provides | grep -q "historic-routing-abi (= $ABI)"; then
	log "PASS runtime 提供 historic-routing-abi = $ABI"
else
	log "FAIL runtime 未提供 ABI = $ABI"
	check_fail=1
fi

# ---------- 6. lintian ----------
if [ "$RUN_LINTIAN" = 1 ]; then
	if command -v lintian >/dev/null 2>&1; then
		echo
		echo "================ lintian"
		lintian --no-tag-display-limit "${DEBS[@]}" 2>&1 | tee "$WORK/lintian.log"
		echo "(lintian 退出码 $?；逐条在报告里说明)"
	else
		log "SKIP 没有 lintian（apt install lintian 后可复查）"
	fi
fi

if [ "$KEEP" = 0 ]; then
	log "== 产物保留在: $SRC_PARENT"
	log "== 构建树（已清）: $SRC"
else
	log "== 保留工作目录: $WORK"
fi

[ "$check_fail" = 0 ] || exit 3
exit 0
