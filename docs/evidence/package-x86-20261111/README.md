# Issue #22 x86 安装包实机验收

候选源码为 `50c81b1b7600e88a070ce86456325940fdbf5930`，FRR 基线为
`27f287be9210d4024a140486b7b8ddd5eb41fe04`，原始 ABI 标识为
`50c81b1-27f287be9`。DEB 元数据用带 `0.` 前缀的 ABI 标识。

| 平台 | 构建与实装验收 |
| --- | --- |
| RHEL 10.1 x86_64，内核 6.12.0-124.8.1.el10_1，SELinux Enforcing | EL10 RPM 的 runtime、egp 与可选 selinux profile 三包。使用 CentOS Stream 10 和 EPEL 软件源提供依赖，实装事务使用 dnf 的依赖解析。 |
| Debian 13.7 amd64，内核 6.12.113+deb13-cloud-amd64 | 独立 KVM 来宾，systemd 为 PID 1。runtime 与 egp DEB 通过 apt 安装，两个构建的 lintian 退出码均为 0。 |

两平台都从同一候选源码构建两个包修订，实测首次安装后两个 unit
均为 inactive/PID 0、显式起停、拒绝版本不匹配的包组合、成套升级、
回退、再次升级和卸载。升级回退保留修改后的配置，显式启动后双向邻接、
Zebra 路由与内核路由恢复。RHEL 使用 `noreplace`，DEB 使用
`Dpkg::Options::=--force-confold`。

安装 unit 的 `systemctl reload` 覆盖 network 增删、幂等、清空、AS/timers
变化、语法及语义错误与恢复。单独停止并启动 egpd 后，Zebra PID 和
`zserv.api` inode 保持，双向路由恢复。

RHEL 验证了 profile 正常安装、重装和卸载，策略缺失时两个 unit 拒绝启动，
重装包后恢复。profile 生效时两个 daemon 均运行于 `frr_t`。整套卸载时
四个修改过的配置均生成 `.rpmsave`，逐字节与原内容一致。最终两套
验收退出码均为 0，宿主路由和网络命名空间快照一致。

首次 RPM 构建的输出目录位于源码树内，打包时 tar 报文件变化。改用外部
输出目录后，两个 EL10 修订均构建成功。初次实装基线中，测试对端经
`ip netns exec` 启动后进入 `ifconfig_t`，套接字创建被拒。改由
`nsenter` 进入隔离网络，并从 SSH 登录上下文运行验收驱动后通过。
首次整套卸载对未经修改的出厂配置期待 `.rpmsave`，最终轮先写入配置
标记，再核对实际保留的内容。

本轮覆盖同一源码的两个开发包修订。发布版本之间的跨源码升级需要用
对应发布包复验。

[RHEL 验收日志摘录](rhel.txt) · [Debian 验收日志摘录](debian.txt)
