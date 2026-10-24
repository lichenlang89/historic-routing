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


---

## S4：构建自动化与首次迁移验证（执行记录）

日期 2026-10-24。执行机：`<实验机 B>`（RHEL 10.1 x86_64，4 vCPU / 7.6 GiB，
gcc 14.4.1，libyang 2.1.148，json-c 0.18，pytest 7.4.3 + pytest-xdist 3.6.1）。
**不再依赖原 fork 工作目录**：FRR 源码由 `scripts/fetch-frr.sh` 从
`https://github.com/FRRouting/frr` 浅取固定提交 `27f287be9…`。

### 命令

```sh
./scripts/build.sh --jobs 4 \
  --build-root /root/hr-build \
  --prefix /opt/historic-routing/egp-27f287be9 \
  --reuse-source      # 首次不需要；后续增量复用 frr-src/frr-build
```

### 结果

| 步骤 | 结果 |
| --- | --- |
| 拉取 FRR | `HEAD=27f287be9…`，工作树干净，9587 个文件 |
| 应用补丁 | 0001–0004 全部 `git apply --check` + `git apply` 成功；改动 12 个文件（与补丁自身推导一致）；0005 未启用 |
| 集成源码 | 8 个文件复制进 `frr-src/egpd/`，逐个 SHA256 与仓库内副本一致（与 S3 记录值相同） |
| bootstrap / configure | 通过；`HAVE_EGPD` 已定义 |
| 路由类型 | `ZEBRA_ROUTE_EGP=32`、`ZEBRA_ROUTE_ALL=33`、`ZEBRA_ROUTE_MAX=34` |
| 编译 | `egpd/egpd`、`zebra/zebra`、`vtysh/vtysh` 全部产出（-j4，约 2.5 分钟） |
| 单元测试 | `EGP codec: golden wire format, bounds, checksum and unaligned tests passed` |
| `make check-TESTS` | `PASS: egpd/test_packet`，TOTAL 1 / PASS 1 / FAIL 0 |
| `make check`（完整） | **rc=2**：`14 failed, 514 passed, 5 skipped`；14 个失败全部在 `tests/isisd/*` 与 `tests/pimd/*`，原因是这些用例要执行 `isisd/test_*`、`pimd/pimd` 等产物，而这两个 daemon 按已验证 configure 集合被 `--disable` 掉（构建目录里确实没有这两个二进制）。判为已知限制，原始 rc 与失败目录已写入指纹 |
| `make dist` | `frr-10.9.0-dev.tar.gz` 8.1 MB，2193 条目，`egpd/` 下 8 个文件全部在内 |
| `make install` | 安装到 `/opt/historic-routing/egp-27f287be9`（81 MB）；`sbin/{egpd,zebra,staticd}`、`bin/vtysh`、`lib/libfrr.so` 俱在；`ldd egpd` 无未解析库 |
| 指纹 | `docs/build-fingerprint-20261024.txt` |

### 明确区分两件事

- **EGP 构建与单测：通过。**（`make`、`make egpd/test_packet`、`make check-TESTS`）
- **完整 FRR 测试套件：本配置下不通过，且与 EGP 无关。** 若要它全绿，需要
  额外启用 isisd/pimd 等 daemon（换 configure 集合），或在上游层面修这些测试
  对"daemon 必须存在"的假设。本轮不做，只记录。

### 真实运行暴露并修掉的脚本缺陷（都是跑出来的，不是看出来的）

1. 日志初始化在 `HR_LOG_FILE` 就绪前发生 → `logs/` 为空。
2. `exec > >(tee ...)` 接管道是块缓冲，失败瞬间 `hr_tail_log` 读不到内容 → 改为逐行
   append 写文件。
3. `hr_log_start` 在 `log()` 定义之前被调用 → 子脚本 `source` 时直接
   `log: command not found` 退出。
4. `--force` 只在"提交不符"时生效，"提交对但工作树脏"时直接报错 → 改为所有不可复用
   场景都重建。
5. 基线标记 `fetch.err` / `.hr-baseline` 写进了源码树，污染工作树导致补丁步骤拒绝执行
   → 改为 `mktemp` 与写进 `.git/`。
6. `set -e` 下 `命令; rc=$?` 会让 `make check` 失败静默退出 → 改 `|| rc=$?`。
7. **automake 拒绝 `TESTS +=`**（`TESTS` 只在 pceplib 的条件块里定义过）→ 补丁 0004
   改为在 `Makefile.am` 里先无条件 `TESTS =`（位置在 pceplib 之前），再在
   `tests/subdir.am` 里 `+=`。
8. `tar tzf … | grep -q` 在 `pipefail` 下因 SIGPIPE 误判"包内缺文件" → 先把清单落文件。
9. `install.sh` 用 `>` 重定向写共享日志，清空了前面步骤的 `build.log` → 改 `>>`
   （该修复已单独验证：预置的哨兵行仍在，日志 154 行）。
10. `libfrr.so` 的安装校验写死了 `lib/frr/` 布局 → 改用 `find` 在前缀内查找。

### 遗留

- 本轮 `build.log` 因第 9 条缺陷在安装阶段被截断（各步骤独立日志完整：`patches-applied.txt`、
  `integration-manifest.txt`、`make.log`、`make-check*.log`、`make-dist*`、`unit-test.log`、
  `install-manifest.txt`）。修复已提交，下次运行的 `build.log` 会完整。
- `verify.sh` / `rebase.sh` 未实现（S6 / 未来）。
- 未做双路由器集成实验（属 S5–S6）。
