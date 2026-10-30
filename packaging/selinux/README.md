# RHEL 10 的可选 SELinux 实验配置

状态：开发验证配置，尚未自动集成到 RPM 安装/卸载脚本。必须先安装发行版的
`frr-selinux`；本模块复用其 `frr_t`，不能替代完整的发行版策略。
RHEL 10.2 aarch64、SELinux Enforcing 实测见
[安装包验收](../../docs/evidence/package-service-20261031/README.md)。
Debian 容器的宿主 SELinux 为 Disabled，本轮不对 Debian SELinux 作结论。

## 权限与标签

原生 `/opt` 安装启动后实际是 `unconfined_service_t`，不能据此宣称已受 `frr_t` 约束。
仅标注为 `frr_t` 会在 EGP bind 本地 IP 时失败，AVC 明确为
`frr_t node_t:rawip_socket { node_bind }`。本模块只增加这一条 allow，
不对整个域设 permissive，不允许访问 root 家目录，也不批量导入 audit2allow 输出。

`.fc` 标注本项目的二进制、私有库、配置和运行目录；bin/sbin **目录**保持 `bin_t`，
普通可执行文件为 `frr_exec_t`，避免误把目录标为 executable 类型。
`node_bind` 授权复用的整个 `frr_t`，因此也会作用于该域的系统 FRR；它不是独立 EGP 域。
固定前缀对应当前 FRR 基线，更换前缀必须重新检查标签与测试。

## 在独占实验资源内验证

需要 `checkmodule`、`semodule_package`、`semodule`、`restorecon`、`semanage`。
先检查 `semodule -l` 和 `semanage fcontext -C -l`，若已有同名模块或本前缀本地规则，
先复核它们的来源，不覆盖已有配置。始终保持 Enforcing。

```sh
cd packaging/selinux
checkmodule -M -m -o historic_routing_egp.mod historic_routing_egp.te
semodule_package -o historic_routing_egp.pp -m historic_routing_egp.mod \
  -f historic_routing_egp.fc
semodule -i historic_routing_egp.pp
mkdir -p /run/historic-routing/frr
restorecon -RF /opt/historic-routing/27f287be9 /run/historic-routing
```

现存目录也必须 `restorecon`；仅添加 file-context 规则不会修改它们的当前标签。
重新安装 RPM 后也应核对文件及新建 runtime 目录的实际标签。

给两个本项目 unit 分别添加自己管理的 drop-in，例如
`30-historic-routing-selinux.conf`，内容为：

```ini
[Service]
Environment=HOME=/run/historic-routing/frr PYTHONNOUSERSITE=1
```

这让 vtysh 历史文件使用已有可写运行目录，并阻止 Python 搜索 root 的 user-site。
本轮同时使用 `NetworkNamespacePath` 将实际服务放进独占网络命名空间，
不在宿主默认命名空间同时运行两套 Zebra。ExecStart/ExecReload 没有替换。
`systemctl daemon-reload` 后再启动和执行实际 `systemctl reload`；核对 daemon 的
`ps -o label` 为 `system_u:system_r:frr_t:s0`、邻接、双向 RIB/内核路由及审计记录。

本轮使用内核 audit multicast 只读监听捕获 AVC；它不替换 auditd，也不修改审计规则。
先保留原策略拒绝日志，再验证补丁配置，不以缺失的 audit.log 更新冒充无 AVC。

## 恢复

先停止本项目两个服务并清理独占网络资源。只删除自己添加的上述 drop-in，
随后 `systemctl daemon-reload`。确认该模块由本次实验创建后执行：

```sh
semodule -r historic_routing_egp
restorecon -RF /opt/historic-routing/27f287be9
# 仅当本项目运行目录仍存在时：
restorecon -RF /run/historic-routing
```

不要删除发行版 `frr` 模块或其他本地 fcontext。比较前后本地规则、Enforcing 状态、
原系统 FRR PID 与宿主路由。本轮已恢复；可选模块没有留装在测试机上。

正式发行前仍需将策略的依赖、升级/卸载及目录重建行为纳入安装包自动化，
并在每个目标发行版重新验证；当前保持实验性/预发布定位。
