# 合并后的安装包服务验收 — 2026-10-31

PR #15 已合并：head `179005d05f7db633447055622ba960b564c58e89`，merge
`b22d0e890acdd0e4e5c6c7e17e3f81f6bad160d5`。Issue #14 保持开放。
本次独立分支只修打包和验收工具；协议源码、FRR 补丁均与已复核实现相同。
所有包仍是 dev，未打发布 tag、未创建正式 Release。

## 实际范围与结果

用户限定使用现有两台 aarch64 主机，暂缓 x86_64/amd64。RHEL 是原生宿主服务；
DEB 使用 Debian 用户态及 systemd 容器，不能当作完整 Debian 宿主或 x86 验收。

| 环境 | 实际包/来源 | 结果 |
| --- | --- | --- |
| RHEL 10.2 aarch64，kernel 6.12，SELinux Enforcing | RPM `0.1.1-0.1.dev00dcc4f.el10` → `0.1.1-0.2.devbb070e0.el10` | 原安装 unit reload、成对升级/回退/再升级、配置保护、依赖拒绝与双向路由恢复通过 |
| Debian 13.7 arm64/systemd 容器；Fedora 42 aarch64 宿主，kernel 6.19，SELinux Disabled | DEB `0.1.1~dev3dd0c63-1` → `0.1.1~devservice2-2`（bb070e0）→ `0.1.1~devservice3-3`（d098a0d） | 两轮成对升级/回退通过；最终新包全量实际 reload 通过；--keep 确认保留构建证据 |
| RHEL Enforcing，手动标签/最小扩展/环境 drop-in | 同一套已安装 RPM，目标进程 `system_u:system_r:frr_t:s0` | 全量 reload 与升级/回退通过；最终审计监听无相关 AVC；可选 .te/.fc 源文件另经编译、加载和全量 reload 验证 |

匹配指同一构建内 runtime/egp 的版本和 ABI；不要求两台邻居使用相同开发提交。
包 SHA256 见 [packages.sha256](packages.sha256)，实际源提交及 FRR 基线见
[RHEL fingerprint](rhel-fingerprint.txt) 和 [DEB fingerprint](deb-fingerprint.txt)。
本地构建输入都是固定 FRR `27f287be9210d4024a140486b7b8ddd5eb41fe04`；
正常 dnf/apt 解析依赖，没有 --nodeps、旧前缀复制或修改断言来通过测试。
[RHEL 构建与 rpmlint](rhel-build.log)、[首次正常安装](rhel-install.log)。

## 服务与生命周期证据

RHEL target 只为隔离路由添加 NetworkNamespacePath；SELinux 专项另加 HOME 与
PYTHONNOUSERSITE。DEB 两端真实 systemd PID 1、各自安装包与根文件系统。
原 ExecStart/ExecReload 保留；对端 veth 直接移入独占 namespace，不接宿主路由。

- reload：network 增删/幂等，全部清空/重复清空，AS/timers 变化，语法错误和语义错误；
  成功不重启 egpd，MainPID 不变，末尾恢复原文件字节、邻接、RIB/内核路由。
  [RHEL](rhel-reload.log)、[DEB 首轮](deb-old-reload.log)、[DEB 最终包](deb-reload.log)。
- lifecycle：逐个新组件的依赖探测必须拒绝不匹配组合；然后成对升级 → 回退 → 再升级。
  每步停自己的服务、确认包不自动启动、保留运维配置，再验证双向邻接与 RIB/内核恢复。
  原生 peer 共享安装前缀，替换文件前也会停止，再用新二进制启动。
  [RHEL](rhel-lifecycle.log)、[DEB 首轮](deb-old-lifecycle.log)、[DEB 最终包](deb-lifecycle.log)。
- RPM noreplace 保留旧配置，新默认 stdout 会留下 `.rpmnew`，需运维复核合并；
  rpm -V 的 egpd.conf 差异是保留旧配置的预期结果。DEB 测试显式使用 force-confold，
  不声称自动合并不同配置内容。最后恢复原运维文件。

DEB 清理前的实际邻接、RIB 与内核表见[最终状态](deb-final-routing.log)。

复测入口及 backend 要求见 [packaging/TESTING.md](../../../packaging/TESTING.md)。

## 本次修复与首次失败

首次失败没有被重试结果覆盖，下面均保留直接日志：

1. RPM spec 固定 x86_64，阻挡当前用户指定的 aarch64 原生构建；删除固定 BuildArch，
   version/ABI 精确依赖仍保留。新 RPM rpmlint 0 errors / 0 warnings。
2. Debian libtool 包不提供 libtool 命令，首次构建失败，补齐 Build-Depends libtool-bin：
   [失败](deb-first-libtool.log)。在线固定基线获取也曾 TLS 中断：[环境失败](deb-first-online.log)。
3. 离线输入原来只复制 tar，不带 SHA256SUMS/VENDOR.txt，校验直接拒绝；
   改为一并携带清单：[修复前](deb-first-offline.log)。
4. RPM 默认配置指向不存在的 prefix/run/egpd.log，服务 active 仍报日志文件错误：
   [首次启动](rhel-stock-first.log)。两种包的新默认改为 log stdout，交给 journal。
5. Debian 首轮 lintian 三条长行警告逐条保留：[旧结果](deb-old-lintian.log)；
   换行修正后[最终结果](deb-lintian.log)无包级告警，工具仍提示 root 执行及参数将弃用。
6. 首轮 Debian 容器 setup 对只读 /proc/sys 写 sysctl 失败；改为 podman run 的 --sysctl：
   [首次环境日志](deb-first-setup.log)。没有用 privileged 绕过。
7. 原生生命周期驱动首次启动 detached peer 时保留 stdout 管道，Python 等待管道 EOF，
   人工仅终止已确认属于本任务的驱动，rc=143：[首次](rhel-lifecycle-first.log)。
   给 daemon 独立日志文件后完整通过；不是 daemon 或包管理器被掩盖的成功。
8. 原 --keep 仍传 dpkg-buildpackage -tc，清掉完整构建证据。现仅非 --keep 使用 -tc；
   d098a0d 再构建、安装、生命周期和 reload 通过，完整日志已保存。

## SELinux：默认成功与受限域分开记录

默认 /opt 安装实际运行于 unconfined_service_t，不能把“Enforcing 没关闭”当作受限域验收。
先给本项目路径标注发行版 frr 类型，原策略出现
`frr_t node_t:rawip_socket { node_bind }` 拒绝，EGP 不建立邻接：
[失败](selinux-original-rejection.log)、[内核只读审计监听](selinux-original-avc.log)。

临时模块只加这条 node_bind。首次最小补丁的 reload 已通过，但监听发现 root user-site、
vtysh history、bin 目录误标的额外 AVC：[保留记录](selinux-minimal-avc.log)。
修正目录类型并为服务使用运行目录 HOME、关闭 Python user-site。
随后一次因未重标现存 runtime 目录而失败：
[日志](selinux-runtime-first.log)、[socket-create AVC](selinux-runtime-first-avc.log)。
添加 restorecon 后完整通过：[reload](selinux-reload.log)、[生命周期](selinux-lifecycle.log)、
[域与退出码](selinux-final-status.log)、[最终监听](selinux-final-avc.log)（空文件，监听期间无相关 AVC）。
未关闭 Enforcing、未设置 frr_t permissive、未放宽 root 家目录访问、未更改 auditd。

公共[可选策略](../../../packaging/selinux/README.md)与 .fc 源文件也实际编译/加载后复验：
[全量 reload](selinux-source-reload.log)、[结果](selinux-source-status.log)。
这些是**手动实验配置**，尚未自动集成到 RPM 的策略依赖/安装/升级/卸载流程；
默认 RPM 的受限部署仍须后续完成这一发布门禁。此配置复用 frr_t，node_bind 权限对整个
frr_t 生效，不宣称单独 EGP 域。Debian SELinux 未测试。

## 构建门禁与清理

最终 RHEL/DEB 均有 egpd/test_packet PASS、check-TESTS 1/1。
完整 make check 原 rc=2，分别为 14 failed / 514 passed / 5 skipped。
这不是全通过；按各测试自己的异常逐条分类为关闭 isisd/pimd 后缺可执行文件及其级联失败，
无 UNCLASSIFIED。未做另开 isisd/pimd 的对照构建，不能声称已证明与补丁完全无关。

- [RHEL 原始日志](rhel-make-check.log)、[逐条分类](rhel-known-failures.md)、[check-TESTS](rhel-check-TESTS.log)。
- [DEB 原始日志](deb-make-check.log)、[逐条分类](deb-known-failures.md)、[check-TESTS](deb-check-TESTS.log)、[完整打包](deb-build.log)。
- [本轮快速协议/哈希检查](quick-tests.log)通过；未把 PR #15 的既有完整协议矩阵说成本轮新跑。
- [清理比对](cleanup.log)：两宿主所有 route table 的 JSON 与初始快照字节一致，
  容器清单恢复原状，原系统 FRR 保持 active，RHEL 原 FRR PID 不变；临时 namespace、
  drop-in、peer、SELinux 模块/本地规则已清理，Enforcing 与原本地 fcontext 恢复。
  RHEL 留下最新匹配 dev 包但 inactive；构建依赖、镜像缓存及证据保留，没有全局 prune。

公开日志脱敏私有工作路径/宿主名，并规范化行尾空白；原始日志留存执行环境，命令结果与首次失败均保留。时间为 2026-10-30 UTC / 10-31 +08；
文件名使用维护者的 +08 日期。SHA256SUMS 覆盖本目录公开证据。

## 后续顺序

继续保持实验性/预发布，不关闭 Issue #14。正式发行前完成 SELinux 包管理集成、
目标平台复验；本轮未运行 RHEL x86_64/Debian amd64、完整 Debian 宿主内核、
历史实现互通、长期丢包/乱序或多邻居压力。互通与压力已另开 [Issue #16](https://github.com/lichenlang89/historic-routing/issues/16)，
不回填到已合并 PR #15，也不把本轮包服务验证扩大为协议完整性结论。
