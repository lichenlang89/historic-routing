# RPM 的可选 SELinux targeted 配置

开发验证功能。安装 `historic-routing-selinux` 才启用本项目的受限服务配置；
只装 runtime/egp 时没有这个 profile，不据此宣称受限域验收。三包从同一构建配套安装，
该 noarch 子包严格依赖同版 runtime、发行版 `frr-selinux`、targeted 策略和工具。
DEB 不携带此 RPM profile，Debian SELinux 不在本轮范围。

## 安装与运行

先停止本项目的 historic-routing-egpd、historic-routing-zebra，再正常 dnf 安装
同次构建的 runtime、egp、selinux 三个 RPM。不能使用 --nodeps/--noscripts。
首次添加 profile 时若本项目 unit 仍 active/activating，preinstall 会明确拒绝，
避免把已有 unconfined_service_t 进程误当作已转入受限域。

包脚本安装 priority 200 的 historic_routing_egp 模块，重标本前缀及已有运行目录，
安装 `/usr/lib/systemd/system/historic-routing-*.service.d/20-selinux.conf`。
该 drop-in 只设置 HOME/PYTHONNOUSERSITE，并在 daemon 启动前准备标签；
ExecStart/ExecReload 保持原包入口。不自动 enable/start/restart 服务。
首次添加或移除 profile 前后都由操作者安排本项目停机及显式启动。

每次服务启动由 ExecStartPre 处理 RuntimeDirectory 的既存/重建标签，并检查
模块及 frr_exec_t。Enforcing 下目标 Zebra/egpd 应为 system_u:system_r:frr_t:s0；
同时核对真实 reload、邻接、双向 RIB/内核路由及 AVC，不能只看 systemctl active。
完整实验始终放在独占 namespace/container，不与系统 Zebra 共用业务路由。

## 升级、回退、卸载

同版三包必须一起升级/回退；旧版本 postun 不移除新版本模块。停止自己的服务后
执行正常包管理器事务，再显式启动并验证路由；配置由原 runtime/egp 的 noreplace 保留。

单独卸载 selinux 子包时，preun 先停止本项目两个 unit，再仅移除自己的 priority-200
模块、恢复本前缀/运行目录标签，最后移除 vendor drop-in 并 daemon-reload。
不重启服务。runtime/egp 配置与二进制保留，之后显式启动会使用无此 profile 的原单元。
移除全部包时，runtime/egp 的 preun 也分别停止自己的 daemon；配置保留为 rpm 的
原文件或 rpmsave，不能据此声称安装包会自动合并修改。

若包脚本失败，保留诊断并修复；服务准备步骤在 Enforcing 下要求自身模块及二进制标签
正确，不会将缺失策略默认为受限成功。不支持使用 --noscripts 移除再期待标签自动恢复。

## 管理范围

复用发行版 frr_t，仅添加已经实测必要的
`allow frr_t node_t:rawip_socket node_bind`。该授权也作用于同域系统 FRR，
不是独立 EGP 域；不授予 root 家目录访问，不设置 permissive，不关闭 Enforcing。
二进制目录 bin_t、可执行文件 frr_exec_t、私有库 lib_t、配置 frr_conf_t、
运行目录 frr_var_run_t；文件上下文随当前 FRR 安装前缀生成。

包仅管理 priority 200 的自身模块；首次发现手工同名模块，或存在其他优先级覆盖时拒绝覆盖，
需管理员先核对来源和迁移。保留管理员本地 fcontext 和其他模块。
本机 Fedora/RHEL 宏会删除或重建额外 varrun 模块，并吞掉某些失败；本项目以严格退出码
直接管理自身 semodule 和限定路径 restorecon，避免修改任务前存在的 extra_varrun。
设计参考 [Fedora 独立策略打包说明](https://fedoraproject.org/wiki/SELinux/IndependentPolicy)，
优先级采用其 200 约定；没有全局 fixfiles、semanage fcontext 或 varrun-convert。

SELinux Disabled 时安装到 targeted store，以支持离线策略部署；不声称内核已执行访问控制。
后续启用 SELinux 的全系统引导/重标仍由系统管理员负责，本轮不改变全局模式。

## 迁移旧手工实验

早期手工 .te/.fc 编译和测试证据保留在
[2026-10-31 记录](../../docs/evidence/package-service-20261031/README.md)。
以前手工创建的模块和 /etc drop-in 不归此 RPM 所有；核对其来源并自行停止服务、
移除旧的同名模块和该实验自己的 drop-in 后，再安装新子包。不要删除发行版 frr 模块
或无关本地规则。
