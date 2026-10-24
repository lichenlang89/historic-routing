# 迁移历史与冻结记录（S0）

## 冻结的源仓库

| 项 | 值 |
| --- | --- |
| 仓库 | `https://github.com/lichenlang89/frr`（FRRouting/frr 的 fork） |
| 本地克隆 | `<原始 EGP 工作树（本仓库之外）>` |
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

在 RHEL 10.1 x86_64（实验机 A / 实验机 B，gcc 14.3.1，libyang 2.1.x，
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

日期 2026-10-24。执行机：实验机（RHEL 10.1 x86_64，4 vCPU / 7.6 GiB，
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

---

## S5：EGP 双路由器实验参数化与真实验证（执行记录）

日期 2026-10-24。执行机：实验机（RHEL 10.1，podman 5.6.0 rootful）。
使用 S4 的前缀 `/opt/historic-routing/egp-27f287be9`，**未重新编译 FRR**（也不需要）。

### 做了什么

- `lab/egp/lab.sh` 重写：`build|up|status|vty N|exec N -- CMD|test|down|env`，
  参数全部来自 `lab.env.example`（默认值）+ 可选 `lab.env`（覆盖）。
- `lab/egp/test_lab.py` 重写：12 项检查 + 收尾校验，逐项断言解析后的状态；
  破坏性检查在 `finally` 里恢复实验；日志写到 `$LAB_RUNDIR/logs/test-*.log`。
- 新增 `lab/egp/Containerfile`（`quay.io/centos/centos:stream10` + 运行期库 + iproute2 +
  procps + python3）与 `lab/egp/lab.env.example`；`lab.env` 进 `.gitignore`。
- 移除开发者个人路径与私有镜像：不再有 `/root/frr-egp-build/prefix`、
  不再依赖 `localhost/frr-23837-base:20261022`。

### 实测结果

主路径（`egp-lab-r1/r2`，`198.18.123.0/24`，`/var/tmp/egp-lab`）：

```
汇总: 13 通过 / 0 失败 / 共 13 项
01 进程   egpd=17 zebra=11       02 邻居   R1->198.18.123.2 Up(active) R2->198.18.123.1 Up(passive)
03 路由   双向 protocol=egp      04 类型/距离  JSON distance=140；文本 G>* 172.16.0.0/16 [140/1]
05 内核   172.16.0.0/16 via .2 proto zebra / 10.0.0.0/8 via .1 proto zebra
06 数据面 10.0.0.1->172.16.0.1 OK ECHO；反向 OK ECHO
07/08 撤路 4s 消失、重宣告 6s 恢复
09/10 SIGKILL 后 7s 对端撤路；重启后 7s 邻居+路由恢复
11/12 zebra 重启后 0s 重放；删邻居后 0s 双端撤路
13 收尾 8s 内实验恢复
```

参数化验证（另一路径 `/root/hr-alt`、另一套名字/网段 `egp-lab2-r*`、
`198.18.124.0/24`、`/var/tmp/egp-lab2`，`lab.env` 只写差异项）：**同样 13/13 通过**。

### 真实运行暴露并修掉的问题（都在实验脚本/容器配置层，EGP 代码一行未改）

1. **zebra 起不来**：`privs_init: initial cap_set_proc failed`。zebra 编译期声明的能力集是
   `{NET_ADMIN, SYS_ADMIN, NET_RAW}`，容器只给了前两个 → 补 `--cap-add SYS_ADMIN`。
2. **zebra 报 `failed to mkdir .../var/lib/frr`**：安装前缀里本来就没有 `var/`、`run/`
   （`make install` 没创建空目录），且容器里是只读挂载 → 宿主侧 `mkdir -p $LAB_PREFIX/{var,run}`
   作为挂载点，容器里用 `--tmpfs` 盖住这两个目录。
   *（S6 更正：这行其实只是**警告**，zebra 仍能正常启动并装路由；当时真正的阻塞只有下一条的
   `privs_init: initial cap_set_proc failed`。目录与 tmpfs 保留，用于提供可写 state/run 路径。）*
3. **僵尸进程让"进程在不在"判断失真**：容器 PID 1 原为 `sleep infinity`，不回收子进程，
   被 SIGKILL 的 egpd 以 `Z` 状态留在进程表 → 容器加 `--init`（`podman-init` 回收），
   同时测试侧增加"排除僵尸"的存活性判定。
4. **只写差异项的 `lab.env` 直接崩**：原实现是"有 lab.env 就只加载它"，未定义变量在
   `set -u` 下报错 → 改为"先加载 `lab.env.example` 的默认值，再用 `lab.env` 覆盖"。
5. **`show ip route egp` 不可用**（"Unknown route type"）：该选择器依赖可选补丁 `0005`
   （`lib/log.c` 的 `proto_redistnum`）。本实验默认不启用 0005，所以测试改用
   `show ip route json`（`protocol=="egp"`、`distance==140`）+ 文本里的 `G>*` 行，
   `lab.sh status` 也改成过滤 `^G`。**没有为了测试去启用 0005 或改 EGP 代码。**

**第 3 次（14:42–14:44，用 `git archive HEAD` 导出的提交内容）**：同样 20 PASS / 1 KNOWN-FAIL /
0 SKIP / 0 FAIL，退出码 0。这一次是为了证明"归档的证据对应的是提交的内容"，而不是工作区里的临时改动。
`docs/evidence/verify-20261024.{log,json}` 就是这一次的原始输出。

### 清理状态

`./lab.sh down` 后：容器 0 个、网络只剩默认 `podman`、宿主机无 zebra/egpd 进程、
宿主机路由表与本实验开始前一致（原默认网关 + 两条直连网段，实验没有留下任何路由）。
另外顺手清理了**今天早些时候**做手工 EGP 演示留在 156 上的
`/opt/frr-egpd/3ab0ca7470` 的 zebra/egpd 进程与 `stub0`（不属于本实验，也非系统 FRR）。

### 明确区分

- **本实验在当前开发环境（同一台实验机）通过**：13/13，且有第二套参数/路径复跑为证。
- **未证明"在全新机器上可复现"**：只有这一台 RHEL 10.1 + podman 5.6 的机器可用；
  换机器需要重新验证 podman 版本、SELinux 行为、镜像拉取来源与内核模块。
  这一点不能混为一谈。

---

## S6：统一验证、可复现性检查、证据归档、v0.1.0 发布准备（执行记录）

日期 2026-10-24。执行机：实验机（RHEL 10.1 x86_64，gcc 14.4.1，podman 5.6.0 rootful）。
**本轮没有创建 tag、没有推送远端、没有创建 Release。**

### 新增

| 文件 | 作用 |
| --- | --- |
| `scripts/verify.sh` | 统一验证入口：A 仓库完整性 / B 构建与产物 / C 实验环境；状态 `PASS/FAIL/SKIP/KNOWN-FAIL`；退出码 0/1/2/3；`--build-only/--lab-only/--all` |
| `scripts/parse-make-check.py` | 从完整 `make check` 日志逐条提取失败测试自己的 `E` 行并分类，生成 `docs/known-failures.md` |
| `patches/frr/SHA256SUMS` | 5 个补丁的哈希基线（A2 用） |
| `protocols/egp/evidence/SOURCES.sha256` | 协议源码 6 个文件的哈希基线（A3 用） |
| `docs/LAB_SAFETY.md` | 实验环境八项安全审查 + 最小能力集 + 残余风险 |
| `docs/known-failures.md` | 自动生成的 14 项失败逐条证据（**不要手工改**） |
| `docs/evidence/sys-admin-ab.txt` | zebra 需要 `SYS_ADMIN` 的 A/B 现场输出 |
| `docs/evidence/verify-20261024.{log,json}` | 本轮最终一次 `verify.sh --all` 的完整日志与机器可读结果 |
| `CHANGELOG.md`、`docs/RELEASE_NOTES_v0.1.0.md`、`docs/RELEASE_CHECKLIST.md` | v0.1.0 发布准备（未发布） |

### 改动

- `lab/egp/lab.sh`：新增 `check_params()`（镜像名/网络名/前缀白名单、CIDR 与 IPv4 逐段校验、
  `LAB_PREFIX`/`LAB_MOUNT`/`LAB_RUNDIR` 必须是绝对路径且不是 `/`、AS/端口范围、`LAB_TIMERS` 格式）；
  每个命令入口先过校验；`up` 创建资源前装 ERR trap，中途失败提示 `down` 清理。
- 文档按"实际做到什么"重写：`FIDELITY`（已支持/简化/未实现 + 验证状态）、`ARCHITECTURE`（增加验证层）、
  `ADD_A_PROTOCOL`（从骨架改为可用 + 新协议最小验收清单）、`README`（验证边界）、`scripts/README`（verify 用法）。
- 发布前清理：把文档里的个人路径（`<用户主页>/...`）与实验机内网地址替换为占位说明；
  `MIGRATION.sha256` 只改注释行，哈希清单未动。

### 两次干净目录执行（新目录 + 新构建根，不用原 fork 源码）

`/root/hr-s6`（tar 导出，无 `.git`）+ `/root/hr-s6-build`（全新构建根），`lab/egp/lab.env`
只写 `LAB_PREFIX=/root/hr-s6-build/prefix`。

**第 1 次（14:31–14:37，完整重建）**：18 PASS / 1 KNOWN-FAIL / 1 SKIP / 1 FAIL，退出码 1。
两条非产品失败，都是验证器自身的缺陷：

| 项 | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| A5 敏感信息扫描 FAIL | 命中 `scripts/verify.sh:193/198` | 扫描器把自己的模式串（`sshpass`、`toor` 裸词）也扫了出来 | 只保留高置信度形态（私钥块/`ghp_`/`AKIA`/`xox*`/`password=`），并排除扫描器自身 |
| C0b 最小权限 A/B SKIP | "前缀缺少 var/ 或 run/" | 把容器内挂载点 `LAB_MOUNT=/build/prefix` 当成宿主路径判断 | 改为从 `lab.sh env` 读 `LAB_PREFIX`/`LAB_MOUNT`（尊重 `lab.env` 覆盖），宿主侧 `mkdir -p var run` 后再做 A/B |

同一次运行里，B1 走的是真实全量构建：14:31:18 拉取 → 14:31:24 打补丁 → 14:31:35 configure →
14:32:03–14:34:32 编译（`OK egpd/egpd`、`OK zebra/zebra`、`OK vtysh/vtysh`）→ 单测 →
`make check`（rc=2）→ `make dist`（`frr-10.9.0-dev.tar.gz` 8.1M）→ 安装 → 指纹。

**第 2 次（14:38–14:40，复用构建）**：**20 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL，退出码 0**。
`B1` 明确打印"复用已有构建：指纹与当前 BASELINE/补丁/核心源码一致（未重复编译）"，
`B3` 复核三个二进制 SHA256 与指纹相符——复用不等于放松。

### 完整 `make check` 的逐条证据（原样保留 rc=2）

`14 failed, 514 passed, 5 skipped in 16.15s`。逐条（`docs/known-failures.md`）：

- 7 项：`FileNotFoundError: ... 'isisd/test_*'` / `'pimd/test_pim_jp_encode'` —— 被 `--disable` 的模块没有可执行文件；
- 7 项：`AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` —— 同一测试类
  `setUpClass` 里的上一条失败导致的 setup 级联（同组有直接的 `FileNotFoundError` 证据）。

**没有**按"失败发生在 isisd/pimd 目录"来归因；分类只看每个测试自己的异常文本。
**未完成**：启用 isisd/pimd 的对照构建（证明这些用例在启用后能过）——已作为限制写入
`docs/known-failures.md` 与发布清单。

### 实验安全：最小权限结论（现场 A/B）

`docs/evidence/sys-admin-ab.txt`：

```
## 只给 NET_ADMIN + NET_RAW
privs_init: initial cap_set_proc failed: Operation not permitted
Wanted caps: cap_net_admin,cap_net_raw,cap_sys_admin=p
Have   caps: cap_chown,...,cap_net_admin,cap_net_raw,...=ep       退出码=1
## 再加 SYS_ADMIN
（zebra 正常启动，跑到 timeout 被杀）                                退出码=124
```

结论：`SYS_ADMIN` 是 zebra 编译期能力集的一部分，**不给就起不来**；容器最小集为
`NET_ADMIN + NET_RAW + SYS_ADMIN`。动态验证覆盖 C1/C2/C3/C4/C5/C6：正常启停、重复 `up` 被拒、
13 项集成测试、`podman kill` 后仍能 `down`、清理后无残留、重复 `down` 幂等。

### 对 S5 结论的一处更正

S5 记录里把 `zebra: failed to mkdir "<前缀>/var/lib/frr"` 列为"zebra 起不来"的原因之一。
S6 复核发现：**这行只是警告**（zebra 仍正常启动并装路由），当时真正的阻塞只有
`privs_init: initial cap_set_proc failed`。`var/`、`run/` 两个目录仍然保留在实验流程里
（给容器里的 `--tmpfs` 提供挂载点），但不再声称它是启动失败的原因。
另外该警告在容器里会以**构建期前缀**的形式出现（二进制里写死了 `--prefix` 路径），属已知日志噪声。

### 清理状态

`verify.sh` 的 C5/C6 在最后一次运行后确认：无 `egp-lab*` 容器、无 `egp-lab-net` 网络、
宿主机无 `zebra`/`egpd` 进程、宿主机路由表无 `10.0.0.0/8` 与 `172.16.0.0/16`。
系统 `frr.service` 全程未启动。

### 可复现性的边界

- **已复现**：在同一台 RHEL 10.1 机器上，用**全新目录 + 全新构建根**从源码构建并通过全部验证
  （两次，第二次为复用构建的一致性复核）。
- **未复现**：第二台机器、其他发行版、SELinux 强制域、系统服务启动方式。
  **不声称跨发行版兼容。**
