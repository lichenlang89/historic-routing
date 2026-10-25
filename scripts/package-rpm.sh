#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 从当前源码树构建 historic-routing 的 RPM（开发验证构建）。
#
# 流程（全部真执行）：
#   0. 检查工作树干净、取 HEAD 提交
#   1. git archive 出源码 tarball（%build 会在里面真跑 scripts/build.sh）
#   2. rpmbuild -bb：%build 从固定 FRR 基线完整构建 → %install 只挑选要装的文件
#   3. 对生成的 RPM 做检查：文件名/大小/SHA256、rpm -qpl、rpm -qpR、rpmlint
#
# 用法：
#   scripts/package-rpm.sh [选项]
#     --version V         RPM Version（默认 0.1.1，开发版）
#     --release R         Release 前缀（默认 0.1.dev<sha7>；实际为 <R><dist>）
#     --topdir DIR        rpmbuild 顶层目录（默认 <repo>/build/rpmbuild）
#     --no-rpmlint        跳过 rpmlint
#     --allow-dirty       允许工作树脏（不推荐，会写进 RPM 溯源信息）
#
# 退出码：0 成功；1 构建/检查失败；2 用法错误。
set -Eeuo pipefail
HR_SCRIPT=package-rpm.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

VERSION="0.1.1"
RELEASE=""
KIND="dev"
TOPDIR=""
RUN_RPMLINT=1
ALLOW_DIRTY=0
GIT_SHA_ARG=""
FRR_REPO_ARG=""

usage() {
	cat <<'EOF'
用法: package-rpm.sh [选项]

  --version V      RPM Version（默认 0.1.1；这是开发验证构建，Release 里带 dev+提交号）
  --release R      Release 前缀（默认 0.1.dev<源码短提交>）
  --topdir DIR     rpmbuild 顶层目录（默认 <repo>/build/rpmbuild）
  --no-rpmlint     跳过 rpmlint
  --allow-dirty    允许工作树脏
  --git-sha SHA    没有 .git 的目录树（例如 tar 解出来的）必须显式给出源码提交
  --kind dev|release  发布类型（默认 dev；release 时包内文案改为正式发布，不再写 NOT released）
  --frr-repo URL   覆盖 FRR 源码传输来源（离线镜像；提交与补丁哈希仍强制校验）
  -h, --help       显示帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--version)     VERSION="${2:?}"; shift 2 ;;
		--release)     RELEASE="${2:?}"; shift 2 ;;
		--kind)        KIND="${2:?}"; shift 2 ;;
		--topdir)      TOPDIR="${2:?}"; shift 2 ;;
		--no-rpmlint)  RUN_RPMLINT=0; shift ;;
		--allow-dirty) ALLOW_DIRTY=1; shift ;;
		--git-sha)     GIT_SHA_ARG="${2:?}"; shift 2 ;;
		--frr-repo)    FRR_REPO_ARG="${2:?}"; shift 2 ;;
		-h|--help)     usage; exit 0 ;;
		*) usage >&2; echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

hr_require_cmd rpmbuild rpm git sha256sum
hr_read_baseline

cd "$HR_REPO_ROOT"
if [ -d .git ]; then
	if [ "$ALLOW_DIRTY" = 0 ] && [ -n "$(git status --porcelain)" ]; then
		die "工作树不干净：RPM 必须对应确定的源码提交（可加 --allow-dirty，但会写进 RPM 信息）"
	fi
	GIT_SHA="$(git rev-parse HEAD)"
	GIT_SHORT="$(git rev-parse --short=7 HEAD)"
else
	[ -n "$GIT_SHA_ARG" ] || die "当前目录不是 git 工作树：请用 --git-sha 指定源码提交"
	GIT_SHA="$GIT_SHA_ARG"
	GIT_SHORT="${GIT_SHA:0:7}"
fi
FRR_SHORT="${FRR_COMMIT:0:9}"
[ -n "$RELEASE" ] || RELEASE="0.1.dev$GIT_SHORT"

TOPDIR="${TOPDIR:-$HR_REPO_ROOT/build/rpmbuild}"
TOPDIR="$(mkdir -p "$TOPDIR" && cd "$TOPDIR" && pwd)"
for d in BUILD BUILDROOT RPMS SOURCES SPECS SRPMS; do mkdir -p "$TOPDIR/$d"; done

log "源码提交 : $GIT_SHA"
log "FRR 基线 : $FRR_COMMIT"
if [ "$KIND" = release ]; then log "版本     : $VERSION-$RELEASE%{?dist}（正式发布构建）"; else log "版本     : $VERSION-$RELEASE%{?dist}（开发验证构建，不是发布版本）"; fi
log "rpmbuild : $TOPDIR"

# ---- 1. 源码 tarball ----
TARBALL="$TOPDIR/SOURCES/historic-routing-$VERSION.tar.gz"
rm -f "$TARBALL"
if [ -d .git ]; then
	git archive --format=tar --prefix="historic-routing-$VERSION/" HEAD | gzip -9 > "$TARBALL"
else
	tar czf "$TARBALL" --transform "s,^\.,historic-routing-$VERSION," 		--exclude=./.git --exclude=./build --exclude=./packaging/rpm/rpmlint* .
fi
log "源码 tarball: $(basename "$TARBALL") $(sha256sum "$TARBALL" | cut -c1-16)… $(du -h "$TARBALL" | cut -f1)"

# ---- 2. SPEC + unit 文件 ----
cp -f "$HR_REPO_ROOT/packaging/rpm/historic-routing.spec" "$TOPDIR/SOURCES/"
cp -f "$HR_REPO_ROOT/packaging/rpm/units/"*.service "$TOPDIR/SOURCES/"
log "SPEC/units 已就位"

# ---- 3. rpmbuild -bb（%build 里真跑 scripts/build.sh）----
LOG="$TOPDIR/build.log"
: > "$LOG"
log "开始 rpmbuild -bb（%build 会从固定 FRR 基线完整构建，约几分钟）"
# 二进制不带 /opt 绝对 rpath（SPEC 里用 patchelf 改成 $ORIGIN/../lib），
# 所以 rpm 的 brp check-rpaths 天然通过；QA_RPATHS 仍保留给旧版 rpm（本机 rpm 4.19 的
# check-rpaths-worker 已不读该变量，实测无效，故不作为依赖）。
rp_raths="${HR_RPATHS:-$(( 0x0001|0x0010 ))}"
log "QA_RPATHS=$rp_raths"
# 参数用数组：URL 里有特殊字符也不会被分词
def_args=(
	--define "_topdir $TOPDIR"
	--define "hr_version $VERSION"
	--define "hr_release $RELEASE"
	--define "hr_git $GIT_SHA"
	--define "hr_git_short $GIT_SHORT"
	--define "hr_frr $FRR_COMMIT"
	--define "hr_frr_short $FRR_SHORT"
)
if [ "$KIND" = release ]; then
	def_args+=(--define "hr_is_release 1")
elif [ "$KIND" != dev ]; then
	die "--kind 只能是 dev 或 release（收到: $KIND）"
fi
[ -n "$FRR_REPO_ARG" ] && def_args+=(--define "hr_frr_repo $FRR_REPO_ARG")
[ -n "$FRR_REPO_ARG" ] && log "FRR 源码来源覆盖为 $FRR_REPO_ARG（提交与补丁哈希仍强制校验）"
rc=0
QA_RPATHS="$rp_raths" rpmbuild -bb "$HR_REPO_ROOT/packaging/rpm/historic-routing.spec" \
	"${def_args[@]}" \
	>>"$LOG" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
	hr_tail_log "$LOG" 60 >&2
	die "rpmbuild 失败（rc=$rc），完整日志: $LOG"
fi
log "rpmbuild 成功（日志: $LOG）"

# ---- 4. 检查产物 ----
mapfile -t RPMS < <(find "$TOPDIR/RPMS" -name '*.rpm' | sort)
[ "${#RPMS[@]}" -ge 2 ] || die "只生成了 ${#RPMS[@]} 个 RPM（期望 runtime + egp）"
hrr_check=0
for r in "${RPMS[@]}"; do
	echo
	echo "================ $(basename "$r")"
	printf '大小   : %s\n' "$(du -h "$r" | cut -f1)"
	printf 'SHA256 : %s\n' "$(sha256sum "$r" | cut -d' ' -f1)"
	echo "---- rpm -qpR（依赖）"
	rpm -qpR "$r" | sort | sed 's/^/  /'
	echo "---- rpm -qpl（文件）"
	rpm -qpl "$r" | sed 's/^/  /'
done

if [ "$RUN_RPMLINT" = 1 ] && command -v rpmlint >/dev/null 2>&1; then
	echo
	echo "================ rpmlint"
	rpmlint --rpmlintrc "$HR_REPO_ROOT/packaging/rpm/rpmlintrc" "${RPMS[@]}" || hrr_check=$?
	echo "(rpmlint 退出码 $hrr_check；上面的 warning 逐条在报告里说明)"
fi

echo
log "RPM 目录: $TOPDIR/RPMS"
ls -1 "$TOPDIR/RPMS"/*/*.rpm 2>/dev/null || true
