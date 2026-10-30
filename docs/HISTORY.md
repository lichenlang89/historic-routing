# 迁移历史与冻结记录（S0）

## 2026-10-27：受限主动 Update

按 RFC 904 §4.1.1 / §4.4 记录接收命令序列号 R，进入 Up 或网络配置改变后在预算
允许时发送一次主动 Update。不同 Poll 开放一个新发送区间，重复 Poll 不增加预算。
接收主动 Update 要匹配当前 S，且不消费未决普通响应；无效报文不消耗预算。
Hello 复用 S，Poll 递增 S；保留 Down 状态不处理主动更新这一可选行为。
单测与原始报文验证序列号、重复限流、普通响应未决和配置变更的实际发包。

## 2026-10-27：RFC 888 遗漏老化

区分显式不可达与未宣告：distance 255 立即撤路，网络连续被三份有效 Update
遗漏才移除，重新出现会重置遗漏次数。三次是实现选择，RFC 888 §5 没有给定次数。
更新在临时表中计算，重复网络或保留表容量溢出整包拒绝，不部分修改现有 RIB。
保留每邻居最多 255 个网络的限制。单测覆盖计数、重新出现、255、重复与容量；
原始对端逐包断言前两次保留、第三次删除以及显式撤路立即生效。

## 2026-10-27：获取与停止控制状态

依据 RFC 904 §3.4 / §3.5 / §4.1.4 / §4.2 实现 Idle/Acquisition/Down/Up/Cease，
Refuse 返回 Idle；删除邻居等待停止握手完成后再释放 socket，错序 Cease-ack 被忽略。
Request/Cease 每 P3=30s 以相同序列号重传，P5=120s abort；有效可达性将 Down/Up
的 abort 延长至 P4=3600s。SIGTERM 保留事件循环完成握手，第二次信号可强制退出。
新增 `clear ip egp neighbor` 作为显式 Start；Idle 不自动重试，但可接受新的 Request。
时间边界通过可控时钟单测，丢失 Cease-ack 的 P3 重传通过独立原始报文测试。

## 2026-10-27：RFC 904 邻居可达性

补齐 §3.3 / §4.3 的 Confirm、Update 与 Poll 可达性来源，使用按时间戳过期的
四 T1 窗口，每 T1 最多计一次。匹配响应只能消费一次，错误序列号不续命；
状态变化时停止未决 Poll 并撤路。独立原始报文对端验证 active 只靠 Update、
passive 只靠 Poll 仍可存活，以及错误 I-H-U 和四 T1 过期。
新增 `egp_reach.h` 已在资源登记表和 automake 头文件清单登记，源码哈希同步更新。

## 2026-10-26：EGP Update 距离与显式撤路

本轮单独修改协议核心源码，修复两处会影响互通的行为：编码器曾忽略
`egp_route.distance`、总是发送 distance 1；接收器曾因一条 distance 255 的网络
拒绝整份 Update，连带丢失其它网络的更新并保留旧路由直到超时。

依据 [RFC 904 附录 A.4](https://www.rfc-editor.org/rfc/rfc904.html#appendix-A.4)
和 [RFC 888 第 5 节](https://www.rfc-editor.org/rfc/rfc888.html#section-5)，
现在按实际 distance 分组编码，配置的本地 network 显式使用 distance 1；
接收普通、匹配未决 Poll 的 Update 时滤掉不可达项，再替换该邻居的路由集合。
不改资源分配、FRR 补丁、ABI 编号或已发布 tag。

新增独立报文金样本、255 路由/距离分组边界检查，以及
`lab/egp/lab.sh test-updates` 原始报文对端测试。协议源码哈希清单随本次改动更新。
验证记录见 [本轮证据](evidence/egp-update-rfc904-20261026.md)；
剩余 stub/完整快照简化见 [忠实度矩阵](FIDELITY.md)。

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

---

## S7：多协议架构验证（执行记录）

日期 2026-10-24。执行机：实验机（RHEL 10.1 x86_64，gcc 14.4.1）。
**没有实现 GGP/HELLO，没有做 RPM/DEB，没有改 v0.1.0 的 tag/Release，没有推送。**

### 审查结论：加第二个协议会撞在哪

逐个集成点看了 5 个补丁触及的 12 个 FRR 文件（`lib/route_types.txt`、`lib/command.h`、
`lib/subdir.am`、`zebra/rt_netlink.c`、`zebra/zebra_rib.c`、`vtysh/vtysh.c`、
`vtysh/vtysh.h`、`configure.ac`、`Makefile.am`、`tests/subdir.am`、
`tools/etc/frr/daemons`、`tools/frrcommon.sh.in`），其中 4 处是**结构性冲突点**：

| # | 问题 | 后果 |
| --- | --- | --- |
| 1 | `lib/route_types.txt` 的编号**由行位置决定**，EGP 的 32 已发布 | 新协议若插在 EGP 之前，EGP 变成 33 —— 与 v0.1.0 的 CLI/pcap/指纹不一致 |
| 2 | `vtysh/vtysh.h` 的 `VTYSH_ALL` 是**同一行**宏 | 两个协议各改这一行 → 文本冲突，且位值可能撞车 |
| 3 | `tools/frrcommon.sh.in` 的 `DAEMONS="..."` 是**单行字符串** | 同上；还可能打乱 topotest 期望的顺序 |
| 4 | `zebra/rt_netlink.c` 的 `switch (proto)` 首条 / `lib/command.h` 的 `NODE_TYPE_MAX` 前 | 同锚点插入，顺序决定结果 |

其余 8 处（`lib/subdir.am`、`zebra_rib.c` 距离表、`vtysh.c` 的 client 表/节点、`configure.ac`、
`Makefile.am`、`tests/subdir.am`、`daemons` 文件）都是"追加一行/一块"的形态，语义独立、
文本上容易合。

### 做了什么

| 新增/修改 | 内容 |
| --- | --- |
| `protocols/<name>/PROTOCOL.meta`（新增，egp 一份） | 协议的**唯一资源登记处**：daemon、configure 开关、automake 条件、HAVE 宏、路由类型符号/名字、显示码、距离、vtysh 符号/位、CLI 节点、补丁目录、源文件、测试目标 |
| `patches/frr/<name>/`（egp 的 5 个补丁移入） | 每协议一个补丁目录；**内容零改动**（SHA256 与移动前逐一相同） |
| `scripts/lib.sh` | `hr_proto_load()` / `hr_proto_list()`；`hr_patch_list()` 改为按登记顺序产出补丁 |
| `scripts/apply-patches.sh` | 断言全部由登记驱动（路由类型行、距离、vtysh 位、client 表、configure/AM_CONDITIONAL、`include`、`TESTS +=`、daemons、DAEMONS 串、`if <COND>` 块） |
| `scripts/integrate-sources.sh` | 目标目录、源文件集合、EXTRA_DIST 文件都来自登记，不再写死 8 个文件名 |
| `scripts/build.sh` | `--protocols LIST`；configure 开关、产物、单测、`PASS:` 断言行、指纹全部按协议循环；路由类型编号断言改为"32 + 登记序、ALL 紧随、MAX=ALL+1" |
| `scripts/install.sh` | daemon 清单、ldd 校验、安装清单按协议生成 |
| `scripts/check-allocations.sh`（新增） | 12 类资源跨协议唯一性 + vtysh 位区间/2 的幂 + **补丁与登记一致性** + 可选与基线比对 |
| `scripts/verify.sh` | 新增 **A6 多协议资源分配**；`--protocols`；B2/B3/B4/B5/B6/B8 全部协议化；C 段在协议集不含 egp 时明确 SKIP |
| 文档 | `ARCHITECTURE`（多协议：规则/12 个集成点/构建流程/基线升级检查清单）、`ADD_A_PROTOCOL`（重写为可执行手册）、`FIDELITY`（资源表改成"EGP 占用 + 下一个可用值"，指向登记表）、`PACKAGING.md`（RPM/DEB 划分设计）、`patches/frr/README.md`（目录约定 + 应用顺序）、`scripts/README.md`、`README`、`CHANGELOG` |

### 编号与位的分配规则（已固化到代码里）

- 路由类型：`32 + 登记顺序`（egp=32，下一个 33）；`ZEBRA_ROUTE_ALL` = 32+n；`MAX` = ALL+1。
  `build.sh` 从生成的 `route_types.h` 反查，与登记顺序不符就 FAIL。
- 显示码：单大写字母，且不在基线 `route_types.txt` 已用集合里（`check-allocations.sh --frr`）。
- vtysh 位：保留区间 `0x400000`..`0x3FFFFFF`，必须是 2 的幂；egp=`0x400000`，下一个 `0x800000`。
- daemon 名 / CLI 节点 / 补丁目录 / 测试目标：跨协议唯一。

### 实际执行结果（全部真跑）

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 资源检查（无源码树） | `check-allocations.sh` | 通过，1 个协议 0 冲突；与基线比对 SKIP（说明原因） |
| 资源检查（有源码树） | `check-allocations.sh --frr /root/hr-s7-build/frr-src` | 通过：显示码/路由类型/vtysh 位均未被上游占用 |
| 全量构建 | `build.sh --protocols egp --build-root /root/hr-s7-build` | 成功：14:41:35 拉取 → 打补丁（12 文件）→ 集成（8 文件）→ configure（`--enable-egpd` 由登记生成）→ make → 单测 → `make check-TESTS 1/1` → 完整 `make check` rc=2（14 failed，与 S4/S6 相同）→ `make dist` 8.1M → 安装 → 指纹 |
| 指纹新字段 | — | `PROTOCOLS=egp`、`PROTOCOL_EGP_ROUTE_TYPE_ID=32`、`DISPLAY_CHAR=G`、`DISTANCE=140`、`VTYSH_BIT=0x400000`、`ZEBRA_ROUTE_ALL_ID=33`、`ZEBRA_ROUTE_MAX=34` |
| 全流程验证 | `verify.sh --all --protocols egp` | **21 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL**，rc=0（A6 新增，其余与 S6 一致） |
| EGP 回归 | 同上 C3 | 容器内 **13/13**；单元测试 `egpd/test_packet` 通过；`ZEBRA_ROUTE_EGP=32`、距离 140 未变 |
| 负向：未登记协议 | `verify.sh --build-only --protocols egp,ggp` | rc=1，`FAIL 协议 'ggp' 不存在：没有 protocols/ggp/ 目录` |
| 负向：未登记协议 | `build.sh --protocols ggp` | rc=1，同上信息 |
| 负向：资源冲突 | 在临时副本里造一个与 EGP 抢同一套资源的 `ggp` 登记 | 12 类冲突全部被点名（daemon/configure/conditional/HAVE/route-type/name/display-char/vtysh-symbol/vtysh-bit/cli-node/patch-dir/test-binary），并列出 12 个共享集成点 |

> 负向测试用的是 `/tmp` 下的**临时副本**，仓库里没有、也不会有假的 GGP。

### 本轮修掉的两个自身缺陷

1. `verify.sh` 的 `--protocols` 起初没生效：参数写进了 `PROTOCOLS`，而 `hr_proto_list` 读的是
   `HR_PROTOCOLS`，导致 `--protocols egp,ggp` 被**静默忽略**并去做一次默认构建。
   已修为先赋值再解析，负向测试因此变成"立刻报错退出 1"。
2. `build.sh` 起初用 `grep "^EGPD_TRUE" Makefile` 判断 AM_CONDITIONAL：automake 会把条件
   展开成 `@EGPD_TRUE@`，生成的 Makefile 里没有这个字符串。改为断言展开后的结果
   （`Makefile` 里出现 `--enabled egpd`），这才是"条件真的生效"的证据。

### EGP 行为不变的依据

- 协议源码与补丁**逐字节未变**：`sha256sum -c protocols/egp/evidence/SOURCES.sha256` 7/7 OK、
  `patches/frr/SHA256SUMS` 5/5 OK（补丁只是换了目录，内容与 v0.1.0 完全相同）。
- 运行时验证：13/13 集成测试、单元测试、`G`/140/编号 32 全部与 v0.1.0 一致。
- 二进制 SHA 与 v0.1.0 不同，原因是**构建前缀不同**（`--prefix` 会编进二进制），
  不是源码变化；本轮没有用 `/opt/...` 前缀重编，以免覆盖既有安装。

### 未解决 / 风险

1. **多协议未真机验证**：只有 EGP 一个协议，`--protocols egp,ggp` 的"两个 daemon 同时编译"
   从未真实跑过（也没有第二个协议可跑）。机制本身的参数化、断言、冲突检查都已实测，
   但"两个真实协议共存"要等 GGP 有代码后再验。
2. **补丁顺序耦合**：4 个热点（route_types 编号、VTYSH_ALL 行、DAEMONS 行、switch 首条）
   要求新协议补丁以前一个协议应用后的状态为基线生成；`rebase.sh` 仍未实现，
   基线升级后需要人工重新生成补丁（`verify.sh` 的 A4 会真打一遍，失败即报）。
3. **打包设计未验证**：`docs/PACKAGING.md` 是设计稿，`ld.so`/systemd/RPM 的
   `%config(noreplace)` 追加语义都还没落地。
4. **保留区间是团队约定**：`0x400000`..`0x3FFFFFF` 不在任何规范里，只是本项目自用；
   若将来与上游 FRR 的位分配冲突，`check-allocations.sh --frr` 会报出来，需要改用新位。

## S9：收口文档里写着的三条限制（执行记录，S9.1/S9.2）

本轮只做 S9 的前两个子步，S9.3–S9.5 未执行，因此本节不涉及 Error/Refuse、
`doc/user/egp.rst` 与 frr-reload 回归。

### S9.1 `show ip route egp` / `redistribute egp` 默认可用

原可选补丁 `0005`（`lib/log.c` 的 `proto_redistnum` 加一行 `"egp"` 映射）并入必需补丁
`0001`：路由类型和它的名字选择器是同一项能力。EGP 补丁集由 5 个变为 4 个，
`0002`–`0004` 的 Subject 序号同步改为 `/4`，`patches/frr/SHA256SUMS` 全部重算。
`--with-optional` 保留给未来协议，EGP 不再有 `0005`。

连带更新：`scripts/apply-patches.sh`（可选补丁断言只在协议确实提供 `0005` 时执行）、
`scripts/build.sh` 帮助文本、`patches/frr/README.md`、`README.md`、`docs/ARCHITECTURE.md`、
`docs/FIDELITY.md`、`AGENTS.md`、`lab/README.md`、`lab/egp/test_lab.py` 的说明，
以及 `lab` 的检查 04 新增第三条证据路径（协议名选择器）。

### S9.2 可观测性

- `show ip egp neighbors [detail] [json]`、`show ip egp neighbors A.B.C.D [json]`
- `clear ip egp neighbor *`
- 每邻居 tx/rx 计数（hello/poll/update），只用于观测，协议状态机不读它
- `protocols/egp/evidence/SOURCES.sha256` 随 `egpd.c` 更新

### 实测（证据见 `docs/evidence/s9-20261030.md` 与同目录两份原始日志）

- `verify.sh --build-only`：PASS 13 / KNOWN-FAIL 1 / SKIP 0 / FAIL 0；
  `A2` 为 4 个补丁、`A4` 为 13 个文件（原 12），`B7` 仍为 14 failed（isisd/pimd，未新增）。
- `lab.sh up && status && test`：13/13 通过；检查 04 的 `show ip route egp` 命中
  `172.16.0.0/16` 与 `10.0.0.0/8`，`show ip route egp` 的 legend 出现 `G - EGP`。

### 本轮的环境事实（与 S5/S6 记录不同的部分）

构建在 `localhost/frr-23837-base:20261022`（Fedora 42）容器里做，宿主为 RHEL 10.2 aarch64；
FRR 源码来自 15M 的离线 bare 镜像（容器内无外网）。实验镜像复用了
`localhost/hr-rfc904-lab:20261026`，因为 Containerfile 只装运行期库、FRR 前缀运行时挂载。
宿主机上旧实验网络 `egp-lab-net` 占用 `198.18.123.0/24`，本轮改用 `egp-s9-net`
（`198.18.140.0/24`）并在结束时清理。
