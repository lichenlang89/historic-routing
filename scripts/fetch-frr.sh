#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 拉取 patches/frr/BASELINE 指定提交的上游 FRR 源码到一个新建目录。
# 不修改任何已存在的目录；只在自己创建的目录里工作。
set -Eeuo pipefail
HR_SCRIPT=fetch-frr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	cat <<'EOF'
用法: fetch-frr.sh --dir DIR [--force]

  --dir DIR    目标目录（不存在则创建；已存在且提交正确则复用）
  --force      目标目录存在但提交不对时，删掉重建（仅限 BUILD_ROOT 之下）

环境变量:
  HR_BUILD_ROOT   允许 --force 删除的根目录（必须设置）
EOF
}

DIR=""
FORCE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dir)   DIR="${2:?}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
done
[ -n "$DIR" ] || { usage; die "必须指定 --dir"; }

hr_require_cmd git
hr_read_baseline
# 离线/镜像构建：HR_FRR_REPO 可覆盖传输来源（内容仍由 $FRR_COMMIT + 补丁 SHA256 校验，
# BASELINE 里的 FRR_COMMIT 不会变；使用了覆盖会写进日志与指纹）
case "$DIR" in /*) ;; *) DIR="$(cd "$(dirname "$DIR")" 2>/dev/null && pwd || echo "$PWD")/$(basename "$DIR")" ;; esac
FRR_REPO_ORIG="$FRR_REPO"
if [ -n "${HR_FRR_REPO:-}" ]; then
	FRR_REPO="$HR_FRR_REPO"
	log "WARN 源码来源被 HR_FRR_REPO 覆盖: $FRR_REPO_ORIG -> $FRR_REPO（提交仍须等于 BASELINE）"
fi

# 真正离线的构建输入（S8-B）：vendor/frr-<short>.git.tar.xz + SHA256SUMS + VENDOR.txt。
# 解包前先校验 SHA256，解包后仍然要用 BASELINE 的 FRR_COMMIT 强校验（下面的 fetch 流程不变）。
if [ -n "${HR_FRR_MIRROR_TARBALL:-}" ]; then
	hr_require_cmd tar
	[ -f "$HR_FRR_MIRROR_TARBALL" ] || die "HR_FRR_MIRROR_TARBALL 不存在: $HR_FRR_MIRROR_TARBALL"
	_mdir="$(cd "$(dirname "$HR_FRR_MIRROR_TARBALL")" && pwd)"
	[ -f "$_mdir/SHA256SUMS" ] || die "缺少 $_mdir/SHA256SUMS（离线镜像必须自带校验和）"
	( cd "$_mdir" && sha256sum -c SHA256SUMS --status ) \
		|| die "离线镜像 SHA256 校验失败: $(basename "$HR_FRR_MIRROR_TARBALL")"
	_repo_dirname="$(sed -n 's/^REPO_DIRNAME=//p' "$_mdir/VENDOR.txt" 2>/dev/null | head -1)"
	[ -n "$_repo_dirname" ] || die "VENDOR.txt 里没有 REPO_DIRNAME"
	_unpack="${DIR%/frr-src}/frr-mirror"
	hr_safe_rm_rf "$_unpack" "frr-mirror"
	mkdir -p "$_unpack"
	tar -xJf "$HR_FRR_MIRROR_TARBALL" -C "$_unpack" || die "解包离线镜像失败"
	FRR_REPO="$_unpack/$_repo_dirname"
	log "WARN 使用离线镜像（已校验 SHA256）: $(basename "$HR_FRR_MIRROR_TARBALL") -> $FRR_REPO"
fi



log "上游仓库 : $FRR_REPO"
log "固定基线 : $FRR_COMMIT ($FRR_DESCRIBE)"
log "目标目录 : $DIR"

if [ -d "$DIR/.git" ]; then
	cur="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo none)"
	dirty="$(git -C "$DIR" status --porcelain | wc -l)"
	if [ "$cur" = "$FRR_COMMIT" ] && [ "$dirty" -eq 0 ]; then
		log "复用已存在的源码树（提交与基线一致，工作树干净）"
		exit 0
	fi
	if [ "$FORCE" != 1 ]; then
		die "$DIR 已存在但不可复用（HEAD=$cur，脏文件=$dirty）；如需重建请加 --force"
	fi
	log "强制重建: HEAD=$cur 脏文件=$dirty（--force）"
	hr_safe_rm_rf "$DIR" "$(basename "$DIR")"
fi

mkdir -p "$DIR"
cd "$DIR"
git init -q .
git remote add origin "$FRR_REPO"

log "尝试浅取单个提交（--depth 1）"
# 错误输出用临时文件：不能写进源码树，否则会让工作树变脏（apply-patches 会拒绝）
FETCH_ERR="$(mktemp)"
trap 'rm -f "$FETCH_ERR"' EXIT
shallow_ok=0
for attempt in 1 2 3; do
	if git fetch -q --depth 1 origin "$FRR_COMMIT" 2>"$FETCH_ERR"; then
		shallow_ok=1
		break
	fi
	warn "浅取失败（第 $attempt/3 次）: $(tail -n 1 "$FETCH_ERR" 2>/dev/null)"
	if [ "$attempt" -lt 3 ]; then
		sleep 15
	fi
done
if [ "$shallow_ok" != 1 ]; then
	warn "改为过滤克隆 + 取该提交（网络不稳时会慢一些）"
	git fetch -q --filter=blob:none --no-tags origin '+refs/heads/*:refs/remotes/origin/*' \
		|| die "无法从 $FRR_REPO 获取引用"
	git fetch -q origin "$FRR_COMMIT" || die "无法获取提交 $FRR_COMMIT"
fi
git checkout -q --detach FETCH_HEAD 2>/dev/null || git checkout -q --detach "$FRR_COMMIT"

cur="$(git rev-parse HEAD)"
[ "$cur" = "$FRR_COMMIT" ] || die "检出的提交 $cur 与基线 $FRR_COMMIT 不一致"
[ -z "$(git status --porcelain)" ] || die "检出的工作树不干净"

# 基线标记写在 .git/ 里：既不污染工作树（apply-patches 要求工作树干净），
# 又跟着这棵源码树走，便于排查这棵树是怎么来的。
printf 'FRR_REPO=%s\nFRR_COMMIT=%s\n' "$FRR_REPO" "$FRR_COMMIT" > "$DIR/.git/hr-baseline"
log "完成: HEAD=$cur，文件数 $(git ls-files | wc -l)"
