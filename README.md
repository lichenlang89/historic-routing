# historic-routing

在现代 Linux 上重现历史路由协议，观察邻居建立、路由交换和实际转发。

项目基于 FRRouting，独立维护协议实现和适配补丁。目前可用的是 **EGP（RFC 904）**：
`egpd` 负责协议通信，通过 Zebra 将学到的路由写入内核，并由 `vtysh` 提供配置和查询。
适合协议学习、抓包分析和隔离网络实验。

当前版本：[v0.1.1（预发布版）](https://github.com/lichenlang89/historic-routing/releases/tag/v0.1.1)，
提供 RPM、DEB 和包含 FRR 离线镜像的源码包。

## 支持什么

| 协议 | 规范 | 状态 |
| --- | --- | --- |
| EGP | [RFC 904](https://www.rfc-editor.org/rfc/rfc904.html) | 已实现实验性 stub gateway，可建立邻居、交换路由并验证转发 |
| GGP | [RFC 823](https://www.rfc-editor.org/rfc/rfc823.html) | 计划中，尚无实现 |
| HELLO | [RFC 891](https://www.rfc-editor.org/rfc/rfc891.html) | 计划中，尚无实现 |

EGP 使用 IPv4 协议号 **8**，路由在 `show ip route` 中显示为 **G**，管理距离为 **140**。
当前实现支持 IPv4 A/B/C 类网络、默认 VRF，最多 16 个邻居；不支持 CIDR、IPv6、
认证或 RFC 904 的 core gateway 功能。具体行为见 [RFC 实现范围](docs/FIDELITY.md)。

## 安装

从 [v0.1.1 发布页](https://github.com/lichenlang89/historic-routing/releases/tag/v0.1.1)
下载对应平台的 `historic-routing-runtime` 和 `historic-routing-egp`，两个包需要一起安装。

**Debian 13 / amd64：**

```sh
sudo apt install ./historic-routing-runtime_0.1.1-1_amd64.deb \
                 ./historic-routing-egp_0.1.1-1_amd64.deb
```

**RHEL 10.1 / x86_64：**

```sh
sudo dnf install ./historic-routing-runtime-0.1.1-1.el10.x86_64.rpm \
                 ./historic-routing-egp-0.1.1-1.el10.x86_64.rpm
```

安装目录为 `/opt/historic-routing/27f287be9/`，配置在其 `etc/frr/` 下。
安装包提供 systemd 服务，默认不启动。准备好实验配置后启动：

```sh
sudo systemctl start historic-routing-zebra.service historic-routing-egpd.service
sudo /opt/historic-routing/27f287be9/bin/vtysh
```

进入后可以查看：

```text
show daemons
show ip egp neighbors
show ip route
show running-config
```

未配置 EGP 时，本地 AS 为 0，邻居列表为空。配置示例见
[EGP 配置说明](protocols/egp/README.md#configuration)。

`show ip route egp`、`show ip route json` 里的 `"protocol": "egp"` 和
`redistribute egp` 在默认构建里都可用（`lib/log.c` 的 `proto_redistnum` 映射随
`0001` 补丁一起应用）；文本 `show ip route` 里的 `G` 行仍然是最直观的查看方式。

程序和配置文件使用独立路径，但 Zebra 会修改所在网络命名空间的内核路由。
请在实验机上运行，避免与系统 FRR 的 Zebra 同时管理同一张路由表；
`egpd`、`zebra`、`libfrr` 和 `vtysh` 也必须来自同一次构建。
安装、升级和卸载细节见 [v0.1.1 发行说明](docs/RELEASE_NOTES_v0.1.1.md)。

## 运行双路由器实验

仓库提供两台隔离 Podman 容器：各运行 `zebra + egpd`，互相宣告一个 stub 网络。
实验覆盖邻居建立、双向路由学习、UDP 转发、撤路，以及守护进程重启后的恢复。

在 RHEL 10.1 实验机上，使用匹配的 RPM 安装产物，运行以下命令。
需要 rootful Podman 和 Python 3；以下以 root 身份执行：

```sh
git clone https://github.com/lichenlang89/historic-routing.git
cd historic-routing/lab/egp

export LAB_PREFIX=/opt/historic-routing/27f287be9
./lab.sh build
./lab.sh up
./lab.sh status
./lab.sh vty 1       # 进入第一台路由器；exit 退出
./lab.sh test
./lab.sh down
```

`test` 会修改实验配置、重启实验中的守护进程，并在结束时检查恢复状态；
结束后用 `down` 清理容器与网络。容器需要 `NET_ADMIN`、`NET_RAW` 和 `SYS_ADMIN`。
地址、AS、镜像和安装前缀均可配置，见 [实验手册](lab/README.md)；
容器权限及隔离边界见 [实验环境说明](docs/LAB_SAFETY.md)。

## 从源码构建

仓库保存协议源码和 FRR 适配补丁，构建脚本会获取
[固定的 FRR 提交](patches/frr/BASELINE)，应用补丁后一起编译。
先安装 FRR 的 Linux 构建依赖，以及 Python 的 `pytest`、`pytest-xdist`；
构建选项与验证流程见 [构建脚本说明](scripts/README.md)。

在仓库根目录执行：

```sh
./scripts/build.sh --jobs 4
```

默认构建目录为 `build/`，安装产物在 `build/prefix/`，日志和构建指纹也保存在构建目录中。
可用 `--prefix /absolute/path` 指定安装位置。
`--with-optional` 仍保留给未来的协议（各协议可自带 `0005` 可选补丁）；EGP 的
`redistribute egp` 支持已并入必需补丁 `0001`，不需要该开关。

构建、测试和双路由器实验的统一验证入口：

```sh
./scripts/verify.sh --all --build-root "$PWD/build"
```

离线构建可使用发布页提供的 `historic-routing-<commit>-src.tar.xz`，
其中包含固定提交的 FRR 镜像及校验清单。打包命令见
[发行说明中的源码构建步骤](docs/RELEASE_NOTES_v0.1.1.md#从源码构建)。

## 验证情况与已知限制

- **RPM**：已在 RHEL 10.1 x86_64 验证安装、systemd 起停、升级、降级和卸载，
  并通过双路由器实验的 13 项检查。
- **DEB**：已在 Debian 13 amd64 用户态容器验证安装和运行流程，
  并通过同样的 13 项实验检查。该验证使用 RHEL 宿主内核，独立 Debian 主机仍需验证。
- **测试**：EGP 报文单元测试通过。完整 FRR `make check` 的记录为
  14 failed / 514 passed / 5 skipped；失败证据指向已禁用的 `isisd`、`pimd`
  缺少可执行文件，尚未通过启用它们的对照构建确认。见 [失败记录](docs/known-failures.md)。
- **互通范围**：尚未与历史 EGP 实现做互通认证；当前版本用于实验，不建议部署到生产网络。

## 文档与源码

| 路径 | 内容 |
| --- | --- |
| [protocols/egp/](protocols/egp/) | EGP 守护进程、报文编解码和单元测试 |
| [patches/frr/](patches/frr/) | FRR 固定基线与集成补丁 |
| [scripts/](scripts/) | 构建、验证和打包脚本 |
| [lab/](lab/) | 双路由器容器实验 |
| [wireshark/](wireshark/) | EGP Lua 报文解析器、安装说明和离线回归 |
| [架构说明](docs/ARCHITECTURE.md) | 协议如何接入 FRR |
| [新增协议指南](docs/ADD_A_PROTOCOL.md) | 目录约定、资源登记和接入步骤 |
| [AI 协作指南](AGENTS.md) | 编码助手的项目边界、验证流程和交付要求；Claude 入口见 [CLAUDE.md](CLAUDE.md) |
| [开发历史](docs/HISTORY.md) | 仓库迁移过程及历史验证记录 |
| [版本记录](CHANGELOG.md) | 各版本变更 |

## 许可

[GPL-2.0-or-later](LICENSE)。本项目独立维护，不隶属于 FRRouting 官方项目。
源码来源和分发说明见 [许可审计](docs/LICENSE_AUDIT.md)。
