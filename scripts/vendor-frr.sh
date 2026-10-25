#!/usr/bin/env bash
# 把固定 FRR 提交做成**可校验的构建输入**，让正式打包不再依赖构建时联网。
#
# 产出（默认在 vendor/）：
#   frr-<short9>.git.tar.xz   固定提交所在的 git 仓库（bare 形式，shallow 也可以）
#   VENDOR.txt                清单：commit / tree / describe / 文件数 / tar 的 SHA256
#   SHA256SUMS                tar 的校验和
#
# 用法：
#   ./scripts/vendor-frr.sh --from /root/frr-mirror.git --out vendor
#   ./scripts/vendor-frr.sh --verify vendor/frr-27f287be9.git.tar.xz
#
# 构建时用 scripts/fetch-frr.sh 的 HR_FRR_MIRROR_TARBALL=<该 tar>，
# 它会在解包前校验 SHA256，解码后仍强制校验 FRR_COMMIT。
set -Eeuo pipefail
HR_SCRIPT=vendor-frr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: vendor-frr.sh [--from DIR] [--out DIR] [--commit SHA]
       vendor-frr.sh --verify FILE

  --from DIR     含固定提交的 git 仓库（默认: 环境变量 HR_FRR_SRC 或 /root/frr-mirror.git）
  --out DIR      输出目录（默认 <repo>/vendor）
  --verify FILE  只校验已有的 vendor 包（SHA256 + commit/tree 一致性）
EOF
}

FROM="${HR_FRR_SRC:-/root/frr-mirror.git}"
OUT=""
VERIFY=""
while [ $# -gt 0 ]; do
	case "$1" in
		--from)   FROM="${2:?}"; shift 2 ;;
		--out)    OUT="${2:?}"; shift 2 ;;
		--commit) FRR_COMMIT_OVERRIDE="${2:?}"; shift 2 ;;
		--verify) VERIFY="${2:?}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "未知参数: $1" ;;
	esac
done

hr_require_cmd git
hr_require_cmd tar
hr_read_baseline
[ -n "${FRR_COMMIT_OVERRIDE:-}" ] && FRR_COMMIT="$FRR_COMMIT_OVERRIDE"
SHORT="${FRR_COMMIT:0:9}"

verify_one() {
	local tarfile="$1" dir="$2"
	local sums
	sums="$(dirname "$tarfile")/SHA256SUMS"
	[ -f "$sums" ] || die "缺少 $sums（无法校验）"
	( cd "$(dirname "$tarfile")" && grep -F "  $(basename "$tarfile")" "$sums" >/dev/null ) \
		|| die "$(basename "$tarfile") 不在 SHA256SUMS 里"
	( cd "$(dirname "$tarfile")" && sha256sum -c SHA256SUMS --status ) \
		|| die "$(basename "$tarfile") SHA256 校验失败"
	local want_tree
	want_tree="$(sed -n 's/^TREE=//p' "$(dirname "$tarfile")/VENDOR.txt" | head -1)"
	[ -n "$want_tree" ] || die "VENDOR.txt 里没有 TREE="
	local got_type got_tree
	got_type="$(git --git-dir="$dir" cat-file -t "$FRR_COMMIT" 2>/dev/null || echo none)"
	[ "$got_type" = "commit" ] || die "仓库里没有提交 $FRR_COMMIT（cat-file: $got_type）"
	got_tree="$(git --git-dir="$dir" rev-parse "$FRR_COMMIT^{tree}")"
	[ "$got_tree" = "$want_tree" ] || die "tree 不一致：期望 $want_tree，实际 $got_tree"
	echo "PASS 校验通过: commit=$FRR_COMMIT tree=$got_tree"
}

if [ -n "$VERIFY" ]; then
	[ -f "$VERIFY" ] || die "文件不存在: $VERIFY"
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	tar -xJf "$VERIFY" -C "$tmp"
	gitdir="$(find "$tmp" -maxdepth 2 -name HEAD -printf '%h\n' | head -1)"
	[ -n "$gitdir" ] || die "tar 里没找到 git 仓库"
	verify_one "$VERIFY" "$gitdir"
	exit 0
fi

[ -d "$FROM" ] || die "源仓库不存在: $FROM"
git --git-dir="$FROM" cat-file -e "$FRR_COMMIT^{commit}" 2>/dev/null \
	|| die "$FROM 里没有提交 $FRR_COMMIT"

[ -n "$OUT" ] || OUT="$HR_REPO_ROOT/vendor"
mkdir -p "$OUT"
TAR="$OUT/frr-$SHORT.git.tar.xz"

TREE="$(git --git-dir="$FROM" rev-parse "$FRR_COMMIT^{tree}")"
DESCRIBE="$(git --git-dir="$FROM" describe --tags --always "$FRR_COMMIT" 2>/dev/null || echo unknown)"
NCOMMIT="$(git --git-dir="$FROM" rev-list --count "$FRR_COMMIT" 2>/dev/null || echo unknown)"

log "打包 $FROM -> $TAR"
tar -cJf "$TAR" -C "$(dirname "$FROM")" "$(basename "$FROM")"

{
	echo "# historic-routing 的固定 FRR 源码输入（离线构建用）"
	echo "FRR_COMMIT=$FRR_COMMIT"
	echo "FRR_SHORT=$SHORT"
	echo "TREE=$TREE"
	echo "DESCRIBE=$DESCRIBE"
	echo "COMMITS_REACHABLE=$NCOMMIT"
	echo "REPO_DIRNAME=$(basename "$FROM")"
	echo "CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "CREATED_ON=$(uname -srm)"
} > "$OUT/VENDOR.txt"

( cd "$OUT" && sha256sum "$(basename "$TAR")" > SHA256SUMS )
log "完成：$TAR ($(du -h "$TAR" | cut -f1))"
log "清单：$OUT/VENDOR.txt"
sed -n '2,6p' "$OUT/VENDOR.txt"
