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
REVISION="1"
GIT_SHA_ARG=""
KIND="dev"
RUN_LINTIAN=1
KEEP=0
ALLOW_DIRTY=0

usage() {
	cat <<'EOF'
用法: package-deb.sh [选项]

  --work DIR        构建工作目录（默认 <repo>/build-deb）
  --version V       覆盖上游版本（默认 0.1.1~dev<源码短提交>）
  --revision N      Debian revision（默认 1；升级测试时用 2）
  --kind dev|release  发布类型（默认 dev；release 时包内文案改为正式发布）
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
		--git-sha)    GIT_SHA_ARG="${2:?}"; shift 2 ;;
		--revision)   REVISION="${2:?}"; shift 2 ;;
		--kind)       KIND="${2:?}"; shift 2 ;;
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
	# 发布源码包（tar 解出来的目录，没有 .git）：必须显式给出来源提交，
	# 且构建输入必须带 vendor/ 里的离线 FRR 镜像（发布源码就是这样分发的）。
	[ -n "$GIT_SHA_ARG" ] || die "当前目录不是 git 工作树：发布源码包请用 --git-sha 指定源码提交"
	SHA="$GIT_SHA_ARG"
	log "WARN 没有 .git：按发布源码包处理，源码提交取自 --git-sha $SHA"
fi
SHORT="${SHA:0:7}"
FRR_COMMIT="$(sed -n 's/^FRR_COMMIT=//p' patches/frr/BASELINE | head -1)"
[ -n "$FRR_COMMIT" ] || die "patches/frr/BASELINE 里没有 FRR_COMMIT"
FRR_SHORT="${FRR_COMMIT:0:9}"
[ -n "$VERSION" ] || VERSION="0.1.1~dev$SHORT"
DVERSION="$VERSION-$REVISION"
PREFIX="/opt/historic-routing/$FRR_SHORT"
ABI_RAW="$SHORT-$FRR_SHORT"
if [ "$KIND" = release ]; then
	KIND_SHORT="official release $VERSION"
	KIND_LONG="this is the official release build v$VERSION"
	KIND_CHANGELOG="Official release v$VERSION"
elif [ "$KIND" = dev ]; then
	KIND_SHORT="development build, NOT released"
	KIND_LONG="this is a development build, not a released version"
	KIND_CHANGELOG="Development build (NOT released)"
else
	die "--kind 只能是 dev 或 release（收到: $KIND）"
fi
# Debian 的版本号必须以数字开头（dpkg-deb 会拒绝 "cefbfc6-..."），
# 所以 Provides/Depends 里的 ABI 标识加 "0." 前缀；原始标识记在 BUILD-INFO 与 changelog 里。
ABI="0.$ABI_RAW"
RUNSTATEDIR="/run/historic-routing"
STAMP="$(LC_ALL=C date -R)"

log "== 源码提交: $SHA"
log "== Debian 版本: $DVERSION（上游 $VERSION，revision 1）"
log "== 安装前缀: $PREFIX   runstatedir: $RUNSTATEDIR   ABI: $ABI（原始 $ABI_RAW）"
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

git archive --format=tar HEAD 2>/dev/null | tar -x -C "$SRC" || {
	# 发布源码包（无 .git）：整棵源码树照抄，vendor/ 里的离线镜像一起带上
	( cd "$HR_REPO_ROOT" && tar -cf - --exclude=./.git --exclude=./dist --exclude=./build-deb . ) \
		| tar -x -C "$SRC"
}
[ -d "$SRC/scripts" ] || die "源码快照不完整（缺 scripts/）"

cp -a "$HR_REPO_ROOT/packaging/debian" "$SRC/debian"
# 离线 FRR 构建输入：dpkg-buildpackage 会清环境变量，所以把它放进源码树，
# 由 debian/rules include debian/hroptions.mk 后再 export 给 scripts/build.sh。
if [ -n "${HR_FRR_MIRROR_TARBALL:-}" ]; then
	[ -f "$HR_FRR_MIRROR_TARBALL" ] || die "HR_FRR_MIRROR_TARBALL 不存在: $HR_FRR_MIRROR_TARBALL"
	mkdir -p "$SRC/vendor"
	cp -f "$HR_FRR_MIRROR_TARBALL" "$SRC/vendor/"
	VENDOR_REL="vendor/$(basename "$HR_FRR_MIRROR_TARBALL")"
	printf 'HR_FRR_MIRROR_TARBALL := $(CURDIR)/%s
' "$VENDOR_REL" > "$SRC/debian/hroptions.mk"
	log "离线 FRR 构建输入: $VENDOR_REL（已拷入源码树，dpkg 清环境也生效）"
fi
rm -f "$SRC"/debian/*.in.rej 2>/dev/null || true

# ---------- 3. 变量替换 ----------
# 统一由一个 helper 做占位符替换（含 @ABI_RAW@）；顺序上 @ABI_RAW@ 必须在 @ABI@ 之前。
subst() {
	sed -e "s|@VERSION@|$DVERSION|g" \
	    -e "s|@DATE@|$STAMP|g" \
	    -e "s|@COMMIT@|$SHA|g" \
	    -e "s|@FRR_COMMIT@|$FRR_COMMIT|g" \
	    -e "s|@ABI_RAW@|$ABI_RAW|g" \
	    -e "s|@ABI@|$ABI|g" \
	    -e "s|@PREFIX@|$PREFIX|g" \
	    -e "s|@RUNSTATEDIR@|$RUNSTATEDIR|g" \
	    -e "s|@KIND_SHORT@|$KIND_SHORT|g" \
	    -e "s|@KIND_LONG@|$KIND_LONG|g" \
	    -e "s|@KIND_CHANGELOG@|$KIND_CHANGELOG|g" "$1"
}
subst "$SRC/debian/changelog.in" > "$SRC/debian/changelog"
rm -f "$SRC/debian/changelog.in"

# 其余文件统一替换（含 .in 结尾的重命名、rwx 位）
for f in "$SRC"/debian/control.in "$SRC"/debian/rules.in \
         "$SRC"/debian/*.install "$SRC"/debian/*.conffiles "$SRC"/debian/*.docs \
         "$SRC"/debian/*.shlibs.in "$SRC"/debian/*.service.in "$SRC"/debian/config/*.conf; do
	[ -f "$f" ] || continue
	subst "$f" > "$f.tmp" && mv "$f.tmp" "$f"
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
		# 在源码树里跑，才能读到 debian/<pkg>.lintian-overrides
		( cd "$SRC" && lintian --no-tag-display-limit "${DEBS[@]}" 2>&1 ) | tee "$WORK/lintian.log"
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
