# Issue #16 收口方案：历史实现互通、长期丢包/乱序、多邻居压力

关联：Issue [#14](https://github.com/lichenlang89/historic-routing/issues/14)（跟踪单）、
[#16](https://github.com/lichenlang89/historic-routing/issues/16)（本方案主体）。
基线 `main` = `4b81f2a`（已含 #15、#17、#18）。本文件是计划，不是完成记录。

## 2026-11-07 补验索引

- S-A：GateD 和 egpd 在互补角色下均可双向内核装表和转发。另用受控 Update
  验证显式撤路、连续遗漏与恢复。双向 Cease 和重新建邻通过。
  见 [互通补验](../evidence/issue16-interop/follow-up-20261107.md)。
- S-B：1%/5%/10% 丢包各 20 分钟，伴随固定种子的延迟和乱序。陈旧/重复
  Update 在接收窗口关闭后均被拒绝。全断链后邻居和双向路由恢复。10% 阶段有短时掉路。
  见 [链路证据](../evidence/issue16-stress/README.md)。
- S-C：从 1 扩到 16 个对端。16 个邻居和 32 条正确下一跳稳定 180 秒，
  并发撤路、老化与对端重启恢复通过。见 [多邻居证据](../evidence/issue16-stress/README.md)。
- 新版安装包的目标平台复验另由 [Issue #22](https://github.com/lichenlang89/historic-routing/issues/22) 跟踪。

## 1. Issue #14 现状审计（对照 main 与证据）

| Issue #14 验收项 | 状态 | 依据 |
| --- | --- | --- |
| reload 接到正确重载入口 | 已完成 | `packaging/rpm/units/historic-routing-egpd.service:20`、`packaging/debian/*egpd*.service.in:19` 均为同树 `frr-reload.py --reload --daemon egpd` 并显式给 bindir/confdir/rundir/vty_socket |
| 实际 RPM/DEB 安装环境 `systemctl reload` | 已完成 | `docs/evidence/package-service-20261031/{rhel,deb,deb-old}-reload.log` 均有 `PASS installed package systemctl reload behavior cases`；驱动 `packaging/test_installed_reload.py` |
| reload 的失败返回值和诊断 | 已完成 | `lab/egp/test_reload.py` 语法/语义错误用例；`packaging/test_driver_regressions.py` |
| `no egp local-as` / `no egp timers` 语义与默认值 | 已完成 | `protocols/egp/src/egpd.c:559,573`；默认 AS 0、30/120；有邻居（含 Cease 清理中）拒绝修改 |
| 删除顺序与清空全部 EGP 配置 | 已完成 | `lab/egp/test_reload.py` 全量清空、重复应用、AS/timers 变更、失败恢复 |
| network 无损重载与幂等回归保留 | 已完成 | 同上，PID 不变 |
| 多网关 Update 接收范围、来源标记、合法公共网络 | 已完成 | `protocols/egp/src/egpd.c:434` 附近；`docs/FIDELITY.md:36-40` |
| 独立对端测混合/无效下一跳/撤路/老化 | 已完成 | `lab/egp/test_protocol.py:416,488` |
| 不跨 AS 比较距离 | 已完成 | 同上实现与 `docs/FIDELITY.md:40` |
| 接收多网关与 core 中继分范围 | 已完成 | `docs/FIDELITY.md:137` 明确未实现中继 |
| 统一 README / 协议 README / FIDELITY / 手册入口 | 已完成 | #15 文档提交；`protocols/egp/doc/` 接入 Sphinx |
| S9 遗留的正式手册/man 页构建验证 | 已完成 | `docs/plan/issue-14-handoff.md` 记录 HTML 与 `frr-egpd.8` 构建、进入 `make dist` |
| `redistribute egp` 名字映射 vs RIB 导入 | 已完成 | `README.md:72`、`protocols/egp/README.md:147` |
| 独立历史实现互通 / 长期丢包乱序 / 多邻居压力 | 已完成本轮实测 | 见上方补验索引及各报告的验证范围 |
| 实际安装包服务与 SELinux 验收 | 已完成 | #17、#18 证据目录 |

#18 合并后，#16 的前置门禁（可选 frr_t 配置的包管理集成）已满足。
#16 本轮实测结果见上方索引。#14 的目标平台安装包复验由 #22 跟踪。

## 2. 资源与环境（已探测）

- 实验机：RHEL 10.2 aarch64（2 vCPU / 3 GB，SELinux Enforcing，rootful Podman 5.8.2），根分区剩余约 2.8 GB。
- 现有安装前缀 `/opt/historic-routing/27f287be9` 来自 `bb070e0`；`git diff bb070e0 4b81f2a -- protocols/ patches/` 为空，协议源码与当前 main 相同，可用 `protocols/egp/evidence/SOURCES.sha256` 复核后复用，避免重新全量构建（磁盘不足）。
- 另有两只早期构建/实验主机在本轮不可达（路由与凭据均不满足），本轮不依赖它们。
- 独立历史实现候选：**GateD 3.6**（`gated-public-3_6`，Merit GateD Consortium 2000 年公开版，含 `src/egp/egp.c`）。
  来源 `https://bio.nic.funet.fi/pub/mirrors/ftp.gated.merit.edu/research.and.development/gated/gated-3-6.tar.gz`，
  SHA256 `60beeb04349e7061d4f1398ef3dc888ef8934baaa8b7cdda61172d060ce42da5`，许可文本见包内 `README` 第 5–36 行（允许使用/复制/修改/再分发，免责声明）。

## 3. 已完成的前置探测（S0，实测）

在实验机的 gated 解包目录内，用以下最小移植改动把 gated 3.6 构建成功并跑通 `-v`（补丁已随本 PR 收录于 `docs/evidence/issue16-interop/gated-3.6-port.patch`）：

1. 编译参数：`-std=gnu89 -fcommon -D_GNU_SOURCE -DYYDEBUG=1`，旧式 `-Werror` 关掉。
2. `src/krt_os/krt_symbols_proc.c:98`：`resp = (char *)(fp = fopen("/proc/net/snmp","r"));`（原写法对强转赋值）。
3. `src/gii/gii.h`：`char [][]` → `char [GIITOKENLEN][GIINBMAXTOKENS]`（与定义一致）。
4. `src/gated/list.h:89,97,103`：`((list_t *)start) = ...` → `(start) = ...`。
5. `src/gated/lexer.l:181`：`int yylineno = 0;` → `extern int yylineno;`（flex 2.6 自带定义）。
6. 构建序：`make depend`；`parse.o`/`lexer.o` 需以 `-DYYDEBUG=1` 重编。

结果：`src/gated/gated`（3.7 MB）链接成功、`./gated -v` 输出版本与启动时间，无运行时缺失（日志 `make11.log`）。
**未做**：gated 的 EGP 邻居配置、与 egpd 的实际报文互通。这一项属 S-A。

## 4. 阶段划分

### S-A 历史实现互通（GateD 3.6 ↔ egpd）

- 范围：独占 netns/容器内，gated 启用 `egp`，与 egpd 建立邻居；抓包与独立报文比对
  Acquire/Hello/Poll/Update/Cease、主动/被动、AS/timers、撤路与恢复。
- 完成标准：
  - gated 与 egpd 双方邻居进入 Up（或给出规范级原因说明为何不能，并保留双方日志与抓包）；
  - 抓包逐字段比对（版本、类型/码/状态、AS、序列号、距离分块、网关列表）；
  - 撤路（255 与连续遗漏老化）与恢复在两侧内核/RIB 上可见；
  - 列出规范差异清单（本实现 vs RFC 904/888 vs gated 行为），不把 stub 角色差异写成缺陷。
- 回滚：只删除本任务创建的容器、netns、运行目录与 gated 构建目录；不动宿主 systemd 的 FRR 与本项目 unit。
- 证据：`docs/evidence/issue16-interop/`（抓包 pcap + 双方日志 + 源提交与 gated 补丁记录）。
- **当前状态（2026-11-05）：S-A 的邻居层、报文层与单条路由装表均已通过。**
  gated 3.6 在修正 7 处现代内核/工具链差异后与 egpd 双向邻居 **Up**；export 加 `metric 1`
  后同一会话内通告 `172.16.0.0` 距离 1，egpd 侧 `Up active 2`、Zebra `G>* [140/1]`、
  内核 `proto zebra` 三层都装表。此前"距离 255 导致不装表"已定位为 export 缺 `metric`。
  非请求 Update 中，egpd 按 RFC 904 §4.1.1 使用 `R=1`，GateD 按同节建议丢弃与本地
  `S=2` 不符的报文。随后 GateD 解析了序号匹配的 Poll 回复。
  2026-11-07 对照复验：GateD 开启 `importdefault` 后将 `10.0.0.0/8` 选入内部 RIB。
  该次对照限于 GateD RIB。后续的内核装表、双向转发、撤路与恢复、Cease、
  主动/被动角色及定时器对照见上方补验索引。
  详见 [互通记录](../evidence/issue16-interop/README.md)。

### S-B 长期丢包/乱序

- 范围：netem 固定种子与 loss/delay/reorder 模型；明确时长与停止条件（建议 60 min 单轮 + 递增 loss）。
- 完成标准：重传/接收窗口、遗漏老化、陈旧 Update 行为符合实现声明；周期性采样 RSS/FD/CPU 无单调增长；
  故障解除后邻接与双向路由恢复；保留首次失败。
- 回滚：清 netem 规则与本节容器；不重启宿主 FRR/SELinux。
- 证据：`docs/evidence/issue16-stress/`（采样 CSV、曲线、日志）。

### S-C 多邻居压力

- 范围：按声明容量 1→16 逐级增加邻居（第 17 个必须拒绝）；同时建立/撤销、多个 peer 的第三方下一跳、邻居重启。
- 完成标准：无跨邻居状态污染、无错误下一跳安装、无残留内核路由；分别报告"容量边界"与"稳定运行规模"。
- 回滚：同上，只清理本任务资源。
- 证据：`docs/evidence/issue16-stress/`。

### S-D 收口

- 更新 `docs/FIDELITY.md`、协议 README、本计划与 `docs/plan/issue-14*.md` 的状态；
  在 #14/#16 上按实测结果更新进度（评论与关闭需单独授权）。
- 完成标准：证据索引可用、未验证项明确、CI 复跑通过（文档改动只查链接/命令）。

## 5. 风险

- gated 的 EGP 是 2000 年代实现，可能只支持特定 neighbor 角色或固定版本号；若无法建立邻居，S-A 只能给出
  报文级可达性结论与规范差异，不能宣称"互通通过"。
- 实验机磁盘 2.8 GB、2 vCPU：不支持再全量构建 FRR；复用现有前缀时必须以哈希核对来源。
- 单机单网络命名空间内的"两路由器"实验不能替代真实链路；结论按"该主机实测"表述。
