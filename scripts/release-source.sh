#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 生成"发布源码包"：源码树 + 受校验的 FRR 构建输入（离线镜像）。
#
# 目的：让打包不再把"构建时能访问 github"当成隐含前提。发布源码包里带一份
# 固定提交的 bare FRR 仓库（vendor/），配 SHA256SUMS + VENDOR.txt；构建时用
#   HR_FRR_MIRROR_TARBALL=vendor/frr-<short>.git.tar.xz ./scripts/package-{rpm,deb}.sh
# 全程离线，内容仍由 patches/frr/BASELINE 的 40 位提交与补丁 SHA256 强校验。
#
# 用法:
#   ./scripts/release-source.sh --frr-mirror /path/to/frr-mirror.git \
#                              [--out dist] [--version 0.1.1~rc1]
#
# 产出:
#   <out>/historic-routing-<源码短提交>-src.tar.xz
#   <out>/MANIFEST.txt
#
# 退出码: 0 成功；1 失败；2 用法/环境错误
set -euo pipefail
set -f 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib.sh"

OUT="$REPO_ROOT/dist"
FRR_MIRROR=""
VERSION=""

usage() {
	cat <<'EOF'
用法: release-source.sh --frr-mirror <git 仓库路径> [选项]

  --frr-mirror PATH   FRR 的本地 bare 镜像（必须含 patches/frr/BASELINE 指定的提交）
  --out DIR           输出目录（默认 dist/）
  --version STR       版本标识（默认 0.1.1~dev<源码短提交>）
  -h, --help          显示本帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--frr-mirror) FRR_MIRROR="${2:?}"; shift 2 ;;
		--out)        OUT="${2:?}"; shift 2 ;;
		--version)    VERSION="${2:?}"; shift 2 ;;
		-h|--help)    usage; exit 0 ;;
		*)            echo "未知参数: $1" >&2; usage; exit 2 ;;
	esac
done

[ -n "$FRR_MIRROR" ] || { echo "FAIL 必须给 --frr-mirror（不要用网络下载当作构建输入）" >&2; exit 2; }
[ -d "$FRR_MIRROR" ] || { echo "FAIL 镜像不存在: $FRR_MIRROR" >&2; exit 2; }

cd "$REPO_ROOT"
[ -d .git ] || { echo "FAIL 必须在 git 工作树里运行" >&2; exit 2; }
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
[ "$DIRTY" = "0" ] || { echo "FAIL 工作树有 $DIRTY 个未提交改动：发布源码必须对应确定的提交" >&2; exit 1; }

SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short=10 HEAD)"
TREE="$(git rev-parse 'HEAD^{tree}')"
FRR_COMMIT="$(sed -n 's/^FRR_COMMIT=//p' patches/frr/BASELINE | head -1)"
[ -n "$FRR_COMMIT" ] || { echo "FAIL patches/frr/BASELINE 里没有 FRR_COMMIT" >&2; exit 1; }
FRR_SHORT="${FRR_COMMIT:0:9}"
[ -n "$VERSION" ] || VERSION="0.1.1~dev$SHORT"

mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hr-relsrc.XXXXXX")"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

log "== 源码提交 $SHA（tree $TREE，$VERSION）"

# ---------- 1. 受校验的 FRR 构建输入 ----------
log "== 生成离线 FRR 构建输入（vendor/）"
bash "$SCRIPT_DIR/vendor-frr.sh" --from "$FRR_MIRROR" --out "$WORK/vendor" 2>&1 \
	| sed 's/^/    /'
VENDOR_TAR="$WORK/vendor/frr-$FRR_SHORT.git.tar.xz"
[ -f "$VENDOR_TAR" ] || { echo "FAIL 没生成 $VENDOR_TAR" >&2; exit 1; }
bash "$SCRIPT_DIR/vendor-frr.sh" --verify "$VENDOR_TAR" 2>&1 | sed 's/^/    /'

# ---------- 2. 组装源码树 ----------
log "== 组装源码树"
mkdir -p "$WORK/pkg/historic-routing-$SHORT"
git archive --format=tar HEAD | tar -x -C "$WORK/pkg/historic-routing-$SHORT"
PKG="$WORK/pkg/historic-routing-$SHORT"
mkdir -p "$PKG/vendor"
cp -a "$WORK/vendor/." "$PKG/vendor/"

cat > "$PKG/SOURCE-COMMIT" <<EOF
# historic-routing 发布源码包
version=$VERSION
source_commit=$SHA
source_short=$SHORT
source_tree=$TREE
frr_commit=$FRR_COMMIT
packaged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 构建（离线，不访问网络）:
#   HR_FRR_MIRROR_TARBALL=vendor/frr-$FRR_SHORT.git.tar.xz ./scripts/package-deb.sh --git-sha $SHA
#   # RPM 需要 bare 仓库路径：先把 vendor 里的镜像解开
#   mkdir -p /tmp/frr-mirror && tar -xJf vendor/frr-$FRR_SHORT.git.tar.xz -C /tmp/frr-mirror
#   ./scripts/package-rpm.sh --git-sha $SHA --frr-repo file:///tmp/frr-mirror/$(basename vendor/frr-$FRR_SHORT.git)
EOF

# ---------- 3. 文件级一致性校验（git 索引 vs 解包后的树） ----------
log "== 校验源码树与 git 索引一致（逐文件 sha256 + 权限）"
git ls-tree -r --full-tree HEAD | awk '{print $1, $4, $3}' | sort > "$WORK/a.index"
( cd "$PKG" && find . -type f ! -path './vendor/*' ! -name 'SOURCE-COMMIT' -printf '%m %p\n' ) \
	| sed 's|^\([0-7]*\) \./|\1 |' | sort > "$WORK/a.files"
MISMATCH=0
while read -r mode path blob; do
	f="$PKG/$path"
	[ -f "$f" ] || { echo "FAIL 缺失文件: $path" >&2; MISMATCH=1; continue; }
	calc="$(git hash-object --no-filters "$f")"
	[ "$calc" = "$blob" ] || { echo "FAIL 内容不一致: $path" >&2; MISMATCH=1; }
	case "$mode" in
		100755) [ -x "$f" ] || { echo "FAIL 可执行位丢失: $path" >&2; MISMATCH=1; } ;;
		100644) [ -x "$f" ] && { echo "FAIL 多出可执行位: $path" >&2; MISMATCH=1; } ;;
	esac
done < "$WORK/a.index"
[ "$MISMATCH" = 0 ] || { echo "FAIL 源码树与提交 $SHA 不一致" >&2; exit 1; }
NFILES="$(wc -l < "$WORK/a.index" | tr -d ' ')"
log "    $NFILES 个文件全部与 git 索引一致（含可执行位）"

# ---------- 4. 打包 ----------
NAME="historic-routing-$SHORT-src.tar.xz"
log "== 打包 $NAME"
( cd "$WORK/pkg" && tar -cJf "$OUT/$NAME" "historic-routing-$SHORT" )
SIZE="$(wc -c < "$OUT/$NAME" | tr -d ' ')"
SUM="$(sha256sum "$OUT/$NAME" | cut -d' ' -f1)"

# ---------- 5. 回读校验：解包后 vendor 仍可校验 ----------
log "== 回读校验（解包 → sha256sum -c vendor/SHA256SUMS → 抽查源码）"
mkdir -p "$WORK/rt"
tar -xJf "$OUT/$NAME" -C "$WORK/rt"
RT="$WORK/rt/historic-routing-$SHORT"
( cd "$RT/vendor" && sha256sum -c SHA256SUMS ) | sed 's/^/    /'
[ "$(cat "$RT/SOURCE-COMMIT" | sed -n 's/^source_commit=//p')" = "$SHA" ] \
	|| { echo "FAIL 回读的 SOURCE-COMMIT 与 $SHA 不符" >&2; exit 1; }
[ -f "$RT/scripts/build.sh" ] && [ -f "$RT/patches/frr/BASELINE" ] \
	|| { echo "FAIL 回读的源码树不完整" >&2; exit 1; }

# ---------- 6. 清单 ----------
{
	echo "historic-routing 发布源码包"
	echo "version=$VERSION"
	echo "source_commit=$SHA"
	echo "source_short=$SHORT"
	echo "source_tree=$TREE"
	echo "frr_commit=$FRR_COMMIT"
	echo "file=$NAME"
	echo "size=$SIZE"
	echo "sha256=$SUM"
	echo "vendor_sha256=$(sha256sum "$PKG/vendor/frr-$FRR_SHORT.git.tar.xz" | cut -d' ' -f1)"
	echo "packaged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	echo "包含: 源码树（$NFILES 个文件，逐文件与 git 索引校验一致）"
	echo "      vendor/frr-$FRR_SHORT.git.tar.xz（离线 FRR 镜像，SHA256 校验通过）"
	echo "      vendor/VENDOR.txt（FRR_COMMIT / TREE / DESCRIBE）"
	echo "      vendor/SHA256SUMS"
	echo "      SOURCE-COMMIT（本清单的机器可读版本 + 构建命令）"
} > "$OUT/MANIFEST.txt"

log "OK $OUT/$NAME"
log "   size=$SIZE sha256=$SUM"
log "   清单: $OUT/MANIFEST.txt"
