# historic-routing v0.1.0 — Experimental EGP (RFC 904)

> **草稿，尚未发布。** 本轮不创建 tag、不推送远端、不创建 GitHub Release。
> 发布前必须把 `docs/RELEASE_CHECKLIST.md` 的每一项都走完。

## 这是什么

`historic-routing` 是一个独立项目：**以 FRRouting 为底层框架，复活已经退出主流使用的历史路由协议**。
本项目不是 FRRouting 官方项目，也不向 FRR 官方提交代码。

v0.1.0 只包含一个协议：**EGP（RFC 904，IETF 状态 Historic）**，实现方式是
`protocols/egp/` 里的协议源码 + `patches/frr/` 里 4 个（可选 5 个）FRR 适配补丁。

**定位说清楚**：这是实验性的 **stub gateway**，不是 RFC 904 意义上的 core gateway，
不是生产可用的路由协议。它的价值是"能用真实的 EGP 报文在真实的路由栈里跑起来，并且结果可复现、可验证"。

## 这个版本能做什么

- 从**固定基线** FRR（`27f287be9210d4024a140486b7b8ddd5eb41fe04`，10.9.0-dev）一键构建：
  `./scripts/build.sh --jobs 4 --prefix DIR`
- 一条命令验证全部：`./scripts/verify.sh --all --build-root DIR`
- 两台 Podman 容器跑 EGP：邻居建立 → 双向学习 → zebra 显示 `G`（管理距离 140）→
  内核路由 → 两个 stub 网络之间 UDP 双向通信 → 撤宣告/重宣告/进程崩溃/进程重启/zebra 重启/删邻居
  全部真实执行并通过（13/13）
- 单元测试：EGP 报文的金样本、边界、校验和、非对齐访问

## 这个版本明确不做什么

| 项 | 状态 |
| --- | --- |
| core gateway 行为（第三方路由中继、度量比较） | 未实现 |
| IPv6、CIDR/超网、默认路由、VRF | 未实现（只支持 IPv4 有类网络、默认 VRF） |
| 认证、route-map、`redistribute egp` | 未实现（0005 为可选补丁，默认关闭） |
| EGP Error 报文生成 | 未实现（只解码） |
| 系统服务启动（`frrinit`/systemd/`watchfrr`） | 未验证，本版本一律显式跑二进制 |
| SELinux `frr_t` 域 | 未验证 |
| 跨发行版 / 第二台机器复现 | 未验证（只在 RHEL 10.1 x86_64 + podman 5.6 上跑过） |
| 完整 `make check` 全绿 | 否：14 项失败，逐条证据见 `docs/known-failures.md` |

## 安装

本版本**不提供发行包**，从源码构建：

```sh
git clone <repo> historic-routing && cd historic-routing
./scripts/verify.sh --all --build-root /root/hr-build      # 构建 + 全部验证
# 或只构建：
./scripts/build.sh --jobs 4 --prefix /opt/historic-routing/egp
```

依赖（RHEL 10.1 实测）：`gcc gcc-c++ make autoconf automake libtool bison flex
python3-devel json-c-devel readline-devel libcap-devel libyang-devel c-ares-devel
pcre2-devel systemd-devel patch tar gzip pkgconf-pkg-config python3-pytest
python3-pytest-xdist`，以及 `podman`（做容器实验时）。

## 快速上手（容器实验）

```sh
cd lab/egp
./lab.sh build      # 构建实验镜像
./lab.sh up         # 起两台路由器，等邻居 Up
./lab.sh status     # 邻居 / zebra 的 G 路由 / 内核路由
./lab.sh vty 1      # 进 r1 的 vtysh
./lab.sh test       # 13 项集成测试
./lab.sh down       # 清理
```

## 证据与可追溯性

| 证据 | 位置 |
| --- | --- |
| 构建指纹（基线、补丁、源码、gcc、configure、测试结果） | `docs/build-fingerprint-20261024.txt`、构建根 `fingerprint.txt` |
| 协议源码迁移逐字节对照 | `protocols/egp/evidence/MIGRATION.sha256`、`SOURCES.sha256` |
| 集成测试原始日志 | `protocols/egp/evidence/lab-test-20261024.log` 等 |
| 完整 `make check` 逐条失败证据 | `docs/known-failures.md`（自动生成） |
| 最小权限 A/B | `docs/evidence/sys-admin-ab.txt` |
| 分阶段执行记录（S0–S6） | `docs/HISTORY.md` |

## 许可与来源

GPL-2.0-or-later。EGP 源码来自作者自己的 `lichenlang89/frr`（tag `egp-verified-20261024`），
迁移时逐字节保持不变；补丁修改的 FRR 文件仍随 FRR 原许可。详见 `LICENSE` 与 `README.md`。
