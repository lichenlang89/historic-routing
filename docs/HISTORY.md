# 迁移历史与冻结记录（S0）

## 冻结的源仓库

| 项 | 值 |
| --- | --- |
| 仓库 | `https://github.com/lichenlang89/frr`（FRRouting/frr 的 fork） |
| 本地克隆 | `<原始 EGP 工作树>` |
| 已验证提交 | `3ab0ca74700bf6e8175ec07e930a320a79f232d9` |
| Tag | `egp-verified-20261024`（annotated，本地创建；**尚未推送**到 GitHub） |
| 上游基线 | `27f287be9210d4024a140486b7b8ddd5eb41fe04`（FRRouting/frr，2026-10-23，`Merge pull request #23811`） |
| FRR 版本 | `10.9.0-dev` |

`3ab0ca7470` 是 fork 上把上游 7 个提交并入后的合并提交，其父提交为
`491b56cb75`（fork 自有工作）与 `27f287be9`（上游）。因此
`git diff 27f287be9..3ab0ca7470` 精确等于本项目自有改动：22 个文件，`+1084 / −2`。

## 备份位置

`<仓库外备份目录>/`（在本仓库之外，不进版本库）

| 文件 | 内容 |
| --- | --- |
| `frr-egp-3ab0ca7.bundle` | `git bundle --all` 完整历史（含所有分支与 tag），可离线克隆 |
| `source-3ab0ca7470.tar.gz` | `git archive` 的源码快照（不带 .git） |
| `diff-27f287be9-3ab0ca7470.patch` | 只含自有改动的完整 diff（22 文件） |
| `format-patch-original/` | `git format-patch 27f287be9..3ab0ca7470` 的 5 个提交补丁（历史存档，不是本项目的补丁系列） |
| `BASELINE.txt` | 基线、验证范围、时间戳 |
| `SHA256SUMS.txt` | 上述文件的校验和 |

## 恢复验证（实跑，不是计划）

从 bundle 克隆到临时目录后核对：

| 检查 | 结果 |
| --- | --- |
| `git bundle verify` | `is okay`，`records a complete history` |
| 恢复后 tag 指向 | `3ab0ca74700bf6e8175ec07e930a320a79f232d9` ✅ 与原始一致 |
| 树对象 | 原始 `ac02e4f4cffc854e9ea161ade28c93ec6d60ff05`，恢复同值 ✅ |
| 文件数 | 原始 9595，恢复 9595 ✅ |

## 已验证范围（来自真机，不是推断）

在 RHEL 10.1 x86_64（<实验机 A> / <实验机 B>，gcc 14.3.1，libyang 2.1.x，
内核 6.12.0-124.8.1.el10_1）上：

- `make` / `make install` / `egpd/test_packet` 通过；
- EGP 双向邻接 `Up`（65001 active、65002 passive），双向路由学习并下发内核（距离 140）；
- 撤路/重宣告、egpd 重启后邻接与路由恢复、`write memory` 配置持久化；
- 3 份 pcap 与逐包解码（校验和全部 ok）。

**未验证**（不要当作已通过）：

- 完整 `make check`（启用 egpd 时 `TESTS` 被覆盖，见 `patches/frr/README.md`）；
- 通过 `frrinit.sh` / `systemd` 启动；
- 以 `frr` 用户 + `frr_t` SELinux 域运行。

---

## S2：补丁拆分（执行记录）

从 `git diff 27f287be9..3ab0ca7470` 按 FRR 层次切成 5 个补丁，见 `patches/frr/`。
在一个**临时克隆**里重建提交并导出 `git format-patch`，原仓库未产生任何提交。

在干净基线（`27f287be9`）的独立 worktree 上按 0001→0005 顺序应用：

- 5 个补丁全部 `git apply` 成功；
- 应用后与已验证树逐文件比对，13 个被补丁触及的文件中 12 个完全一致，
  唯一差异是 `tests/subdir.am` 的 `TESTS =` → `TESTS +=`（刻意修正，见
  `patches/frr/README.md`）；
- 补丁中 `+++ b/egpd/` 出现次数为 0，即不含任何 EGP 源码。

整树比对时，`egpd/*.c` 等 8 个文件显示为"缺失"，这是因为它们由构建时复制
（S4 的 `integrate-sources.sh`）提供，补丁系列按设计不包含源码。

## S3：源码迁移（执行记录）

**关于"逐字节不变"的口径**：原仓库的 Windows 克隆设置了 `core.autocrlf=true`，
所以同一个文件有两份字节序列——**仓库内的 blob 是 LF**（这也是 GitHub 上的内容、
以及在 Linux 上真实编译通过的那份），**工作树是 CRLF**。迁移以 blob 为准：

| 文件 | git blob（迁移源 = 目标） |
| --- | --- |
| `egpd/egpd.c` | `06e45413e6711925763a97432911c0b2c9b120a5` |
| `egpd/egp_packet.c` | `6c610b2eec9af35787682f18323ac5ef792f00e7` |
| `egpd/egp_packet.h` | `ebefa4230bcda4485433682b78e79789c4186fc1` |
| `egpd/test_packet.c` | `953cd36208b6e3c491e69983a7253a88f4a618ba` |
| `egpd/subdir.am` | `7013e4a57735523e60eb75700ba9815f43e9a41b` |
| `egpd/README.md` | `b43770d0ba0f3e05b99fd477854f6077984b6c34` |
| `egpd/lab.sh` | `252093631307ecc0818b234feb4d688d4d6d0759` |
| `egpd/test_lab.py` | `45be8a7c6116df3baa3aff1a764874c359c42d58` |

校验方式（双证）：每个目标文件的 `sha256sum` 等于源 blob 的 `sha256sum`，
且 `git hash-object <目标>` 等于源 blob 的 object id。8/8 通过，
明细在 `protocols/egp/evidence/MIGRATION.sha256`。

配套决定：本仓库 `core.autocrlf=false` + `.gitattributes` 固定 `eol=lf`，
保证后续任何 Windows 侧操作都不会再引入换行转换。

