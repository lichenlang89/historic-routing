# historic-routing

以 FRRouting 为底层框架，复活已经退出主流使用的历史路由协议。

> **本项目不是 FRRouting 官方项目，也不向 FRRouting 官方提交任何代码。**
> FRR 在这里只作为底层框架（RIB、内核下发、CLI、ZAPI、构建系统）。协议实现和
> FRR 适配补丁都由本项目独立维护，与 FRRouting 项目无关，也不代表其立场。

## 协议

| 协议 | 规范 | 状态 |
| --- | --- | --- |
| EGP | [RFC 904](https://www.rfc-editor.org/rfc/rfc904.html)（Historic） | 实现完成并在真机验证过；本仓库已迁入源码（S3） |
| GGP | RFC 823（Historic） | 规划中，**尚无代码** |
| HELLO | RFC 891（Historic） | 规划中，**尚无代码** |

## 当前状态

本仓库按迁移方案分阶段建立，**本轮只执行到 S3**：

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| S0 | 冻结原 fork（tag、bundle、快照、差异备份、恢复验证） | 已完成 |
| S1 | 建立本仓库骨架（目录、README、架构、许可、BASELINE） | 已完成 |
| S2 | 从原 fork 提取 FRR 适配补丁（0001–0005） | 已完成 |
| S3 | 把 EGP 协议源码迁入 `protocols/egp/`（逐字节不变） | 已完成 |
| S4 | 构建编排（`scripts/build.sh` 等） | 已完成（RHEL 10.1 实跑通过，见 `docs/HISTORY.md`） |
| S5 | 实验环境参数化（`lab/egp/`） | 已完成（容器实验 13/13 实跑通过，见 `docs/HISTORY.md`） |
| S6 | 回归清单自动化与证据归档 | **未开始** |
| S7 | 新协议模板验证（空壳 GGP） | **未开始** |

因此请注意：

- **本仓库现在能从零一键构建到安装前缀**：`./scripts/build.sh --jobs N --prefix DIR`
  （取固定基线 FRR → 打补丁 → 集成源码 → 编译 → 单测 → make check → make dist → 安装 → 指纹）。
  详见 `scripts/README.md`。
- **"EGP 构建与单测通过" ≠ "完整 FRR 测试通过"**：EGP 的门禁 `make check-TESTS` 为
  `PASS: egpd/test_packet`；而完整 `make check` 会跑上游 pytest 套件，其中
  `tests/isisd/*`、`tests/pimd/*` 需要被本项目禁用的 daemon，实测 14 failed（详情与
  原始退出码见 `docs/build-fingerprint-20261024.txt` 与 `scripts/README.md`）。
- `lab/egp/` 已完成参数化（S5）：无硬编码个人路径、无私有镜像，
  `lab.env.example` 集中管理参数，容器内固定挂载路径在 `lab/README.md` 中文档化。
  集成测试 13/13 在容器内实跑通过（见 `docs/HISTORY.md` 的 S5 记录）。
- 已构建好的实机产物在 `<实验机 B>:/opt/historic-routing/egp-27f287be9`（`sbin/egpd`、
  `sbin/zebra`、`bin/vtysh`），指纹见 `docs/build-fingerprint-20261024.txt`。
  原 fork 的已验证树（tag `egp-verified-20261024`）作为历史对照保留。

## 仓库结构

```
patches/frr/     FRR 原生文件的适配补丁（按 FRR 内部层次拆分），以及钉死的上游基线
protocols/       每个历史协议一个目录：src（协议源码）、build（automake 片段）、tests、evidence
scripts/         构建编排：拉取固定 FRR、应用补丁、集成源码、编译、验证（S4）
lab/             实验环境：容器镜像、地址规划、端到端集成检查
docs/            架构说明、迁移历史、忠实度矩阵、加协议手册
tools/           pcap 解码器、协议解析器（dissector）
```

设计要点（详见 `docs/ARCHITECTURE.md`）：

- **本仓库不包含 FRR 源码**，只包含补丁；补丁里也不包含整份 EGP 源码。
- 协议源码在构建时被复制进 FRR 树的对应目录（`$FRR/<proto>/`），因此加文件不需要改补丁。
- 每个协议 = 独立目录 + 固定的 4 个集成补丁（+ 可选能力补丁），协议之间互不引用。

## 许可

- 本仓库整体按 **GPL-2.0-or-later** 分发，与 FRR 一致；全文见 `LICENSE`。
- `protocols/egp/src/`、`protocols/egp/tests/` 下的源码来自 `lichenlang89/frr`（tag
  `egp-verified-20261024`），文件头保留原有 `SPDX-License-Identifier: GPL-2.0-or-later`
  与版权说明，未做任何改写。
- 补丁（`patches/frr/`）修改的是 FRR 原生文件，许可随原文件（GPL-2.0-or-later）。
- 新增文档（`docs/`、各 `README.md`）同样按 GPL-2.0-or-later 提供，以便与代码同许可分发。

## 兼容性与约束

- FRR 只按 `patches/frr/BASELINE` 里钉死的提交使用，不跟随上游 `master`。
- EGP 的路由类型是新的 ZAPI 常量，**egpd 必须与同一棵树编译出来的 zebra / libfrr / vtysh
  一起运行**，不能把 egpd 二进制装进发行版 FRR。
- 本项目不开发脱离 FRR 的后端（例如 netlink-only）。
