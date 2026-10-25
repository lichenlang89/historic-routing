# historic-routing v0.1.1 发行说明

> 状态：**实验性软件，非生产用途。** EGP（RFC 904）实现仅为 stub gateway，不是 RFC 904 意义上的
> core gateway。本项目与 FRRouting 官方项目无关。

## 这个版本是什么

v0.1.1 是把"以 FRRouting 为框架复活历史路由协议"这件事做成**可安装、可复现构建**的第一个发布版：
RPM（RHEL 10.1 x86_64）与 DEB（Debian 13 amd64）两套原生包，来自**同一个源码提交**，
内含 FRR 10.9.0-dev（基线 `27f287be9`）加 4 个 FRR 适配补丁，以及实验性 EGP 守护进程 `egpd`。

包内容：

| 包 | 内容 |
| --- | --- |
| `historic-routing-runtime` | `libfrr.so.0`、`zebra`、`vtysh`、配置骨架、zebra unit |
| `historic-routing-egp` | `egpd`、`egpd.conf` 示例、egpd unit（精确依赖同一次构建的 runtime） |

安装位置 `/opt/historic-routing/27f287be9/`，**不覆盖系统 FRR**（`/usr/sbin/frr*`、`/etc/frr`、
`/usr/lib/*/frr`、`frr.service` 全部不动）。

## 安装

### RHEL 10.1 / x86_64

```sh
sudo dnf install ./historic-routing-runtime-0.1.1-*.el10.x86_64.rpm \
                 ./historic-routing-egp-0.1.1-*.el10.x86_64.rpm
# 服务只安装、不启用、不启动
sudo systemctl start historic-routing-zebra.service historic-routing-egpd.service
sudo /opt/historic-routing/27f287be9/bin/vtysh -c 'show daemons'
```

依赖：`libyang`（3.x）、`json-c`、`libcap`、`libcrypt`、`readline`、`pcre2`（由 dnf 自动解析）。

### Debian 13 / amd64

```sh
sudo apt install ./historic-routing-runtime_0.1.1-*_amd64.deb \
                 ./historic-routing-egp_0.1.1-*_amd64.deb
sudo systemctl start historic-routing-zebra.service historic-routing-egpd.service
```

依赖：`libyang3`、`libjson-c5`、`libcap2`、`libcrypt1`、`libreadline8t64`（apt 自动解析）。

### 卸载

```sh
# RHEL
sudo systemctl disable --now historic-routing-egpd historic-routing-zebra
sudo dnf remove historic-routing-egp historic-routing-runtime
# Debian
sudo systemctl disable --now historic-routing-egpd historic-routing-zebra
sudo apt purge historic-routing-egp historic-routing-runtime
```

卸载不会删除 `/opt/historic-routing` 下的其它版本目录；运行期 socket/PID 在
`/run/historic-routing/frr`，由 systemd 回收，不留残留。

## 与系统 FRR 同时运行的风险（重要）

- 两套 `zebra` 都会编程同一个内核 RIB。**不要同时运行** `frr.service` 与
  `historic-routing-zebra.service`，否则路由会被互相覆盖/撤掉，且难以排查。
- 两套 `vtysh` 用不同 socket 目录（`/run/frr` vs `/run/historic-routing/frr`），互不干扰，
  但同一终端里容易混淆，建议显式写全路径。
- 包级**没有** `Conflicts: frr`：文件级交集只有公共父目录，库解析被 `RUNPATH=$ORIGIN/../lib`
  隔离。约束靠"不要同时启动 zebra"这条运维规则，而不是包管理器。
- 同一个 `libfrr.so.0` 的 soname 在两套构建里相同，但 ZAPI/路由类型编号不同，
  **禁止**把系统 `frr` 的组件与本包组件混装混跑；包内用 `historic-routing-abi` 标识绑定同一次构建。

## 配置

- `zebra`：`/opt/historic-routing/27f287be9/etc/frr/frr.conf`
- `egpd`：`/opt/historic-routing/27f287be9/etc/frr/egpd.conf`（示例，含 `egp local-as` / `egp timers` / `egp neighbor`）
- 全部按 conffile 语义保护（RPM `%config(noreplace)`，DEB `*.conffiles`），升级不会覆盖你的修改。

## 验证范围（诚实说明）

- **RPM**：RHEL 10.1 x86_64 实机安装 → systemd 起停 → 双路由器 EGP 13 项 → 升级/降级 → 卸载，
  34 项检查全通过；`rpmlint` 0 error / 0 warning。
- **DEB**：Debian 13.7 amd64 **用户态容器**（宿主内核为 RHEL 10.1 的 6.12，**不是 Debian 自带内核**）
  安装/运行/升级/降级/purge 全流程通过；双路由器 EGP 13 项通过；`lintian` 0 error / 2 warning。
  **未在独立 Debian 机器上验证。**
- `make check`：14 项已知失败原样保留（全部落在编译期已 `--disable` 的 isisd/pimd），
  见 `docs/known-failures.md`。
- 只测了 amd64；arm64、Debian 12、RHEL 9 未测。

## 从源码构建

发布源码包（`historic-routing-<short>-src.tar.xz`）内含源码树 + 固定提交的 FRR 离线镜像 +
校验清单，**不需要联网**：

```sh
tar xJf historic-routing-<short>-src.tar.xz && cd historic-routing-<short>
# Debian
HR_FRR_MIRROR_TARBALL=$PWD/vendor/frr-27f287be9.git.tar.xz ./scripts/package-deb.sh --git-sha <sha> --kind release
# RHEL（RPM 需要 bare 仓库路径）
mkdir -p /tmp/frr-mirror && tar -xJf vendor/frr-27f287be9.git.tar.xz -C /tmp/frr-mirror
./scripts/package-rpm.sh --git-sha <sha> --kind release --frr-repo file:///tmp/frr-mirror/frr-27f287be9.git
```

## 许可

GPL-2.0-or-later。详见 `LICENSE`、`docs/LICENSE_AUDIT.md`；FRR 源码与补丁的分发方式见该审计文档 §2。

## 升级到本版本

从任何 0.1.0 之后的开发构建升级：RPM 用 `dnf upgrade` 本地包、DEB 用 `apt install` 新包即可；
配置文件按 conffile 保留。**v0.1.0 是源码 tag，没有配套安装包**，不存在从 v0.1.0 安装包升级的路径。
