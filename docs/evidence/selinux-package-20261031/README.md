# SELinux 包管理与共享运行目录验收（2026-10-31）

Refs #14。起点 main `3b09a58`（PR #17 已合并，head 2a7e874 的 CI 6/6）。
现有手工 SELinux 配置没有包管理生命周期；RPM 卸载也未完整停止各自 daemon。
本轮增加可选 noarch historic-routing-selinux，将模块、标签和服务 drop-in 交给包管理。
测试发现并修正共享 RuntimeDirectory 所有权，防止 egpd 停止时删除活跃 Zebra 的 socket。
协议源码、FRR 补丁和基线不变，不关闭 #14，不正式发布。

## 产物与实际范围

仅使用维护者指定的原两台 aarch64 主机；未扩大为 x86 或完整 Debian 宿主验收。
使用原安装 unit 的 ExecStart/ExecReload；仅为实验添加独占 NetworkNamespacePath，
SELinux 环境与 ExecStartPre 来自 RPM 自己的 vendor drop-in，没有手工补标签来代替包脚本。

| 平台 | 产物/执行版本 | 本轮结果 |
| --- | --- | --- |
| RHEL 10.2 aarch64，kernel 6.12，Enforcing | 0.4.devfd0c3ed.el10 三包；源码 fd0c3ed | 完整安装/拒绝负例/reload/目录重建/单包及整套卸载重装通过；0.3→0.4→0.3→0.4 通过；两个 daemon 真实 frr_t |
| Fedora 42 aarch64，kernel 6.19，Disabled | 0.4.devfd0c3ed.fc42；最终 0.5.devretain.fc42（源码 51c0197） | V2 完整包生命周期通过；V1/V2、V2/V3 两轮三包升级/回退通过；仅离线 targeted store 验证，不声称 MAC 生效 |
| Debian 13.7 arm64/systemd 容器，宿主为上述 Fedora | 0.1.1~devfd0c3ed-1 两包 | 同源重建、正常 apt 安装；egpd stop/start 保持 Zebra PID/socket，完整 reload 与 CRLF 字节校验通过 |

[交付包 SHA256](packages.sha256)覆盖最终选定的 8 个开发包（3+3+2）。
[三包驱动](../../../packaging/test_package_lifecycle.py)增加 --selinux，显式区分 Enforcing 与
Disabled，并逐次核对三包版本、策略模块及两个进程的实际域。
完整原生矩阵：[test_installed_profile.py](../../../packaging/selinux/test_installed_profile.py)。
执行驱动逐步完善于 e4509a9/ef91b43；包来源独立记录，不把测试脚本提交当作包源码提交。

## 包管理行为与证据

- 可选 profile 严格依赖同版 runtime、发行版 frr-selinux、targeted 策略和 SELinux 工具。
  受限部署正常 dnf 安装三包；只装 core 两包不算启用 profile。CI 也改为正常 dnf，移除 --nodeps。
- 模块只安装到 priority 200，自身 package source 包含 .pp.bz2；定向 restorecon 本前缀及
  运行目录，vendor drop-in 设置 HOME/PYTHONNOUSERSITE 和启动准备。不自动 enable/start/restart。
- 首次 profile 安装拒绝仍在运行的项目 unit，两个原 PID 保持；避免把旧 unconfined 进程当作
  已转入 frr_t。拒绝同名手工 priority-400 模块，保留它直至测试自己清理。
- Enforcing 下主动移除本模块后，两个 unit 均被 ExecStartPre 阻断、MainPID=0；
  通过正常 dnf reinstall 恢复模块后可恢复路由，无手工 relabel 补救。
- 删除整个运行目录根后再启动，目录标签及 frr_t 自动恢复；在线重装 profile 保持两个 PID。
- 单独卸载 profile 先停自己的两 unit，再卸载自身模块并恢复标签；core/config 保留，
  默认模式可显式重新启动；再次安装 profile 后恢复 frr_t 与路由。
- 单独删除 egp 必须停 egpd，Zebra PID/socket inode 保持；原配置以 rpmsave 保留；
  重新安装、恢复运维配置后恢复路由。删除 runtime 会正常解析并移除依赖的 egp/profile，
  两 unit 停止、模块移除；所有改过的配置逐个校验 rpmsave，再通过正常包事务重装恢复。

直接结果：[RHEL 完整矩阵](rhel-installed.log)、[Fedora 完整矩阵](fedora-installed.log)、
[RHEL 三包升级/回退](rhel-lifecycle.log)、[Fedora V1/V2](fedora-lifecycle.log)、
[Fedora 最终 V2/V3](fedora-v3-lifecycle.log)、[Debian 服务](deb-service.log)。
所有配置使用原始 bytes 和独立 SHA256，包括合法 CRLF；每次事务后两个 unit 都须 inactive/0，
再显式启动并验证双向邻接、RIB/内核路由。

## 共享目录缺陷的前后对照

V1 在两机的 EGP 单独卸载/重装后均出现路由不恢复，保留
[RHEL 首次完整失败](rhel-v1-route-failure.log)。独立复现确认：Zebra PID 仍 active，
停止 EGP 后 zserv.api 消失，EGP 重启显示 zebra disconnected，虽然邻居可能已经 Up：
[修复前](socket-before-fix.log)。这符合
[systemd RuntimeDirectory 生命周期](https://freedesktop.org/software/systemd/man/latest/systemd.exec.html)描述。

两个发行包模板改成仅 Zebra 声明 RuntimeDirectory，egpd 保留 Wants/After；
没有延长等待或重启 Zebra 绕过。新回归要求保持 Zebra PID 和原 socket inode，再恢复双向路由：
[RHEL 修复后](socket-after-fix.log)、[Debian 新包](deb-service.log)。
复测入口：[test_shared_runtime.py](../../../packaging/test_shared_runtime.py)。

## 首次失败与测试完善

1. 新 profile V1 的说明长行、ghost 权限和重复 drop-in 触发 3 errors/2 warnings：
   [首次 lint](first-fedora-lint.log)。已折行、明确 ghost 目录属性并用硬链接共享相同 drop-in；
   RPM 入口也改为 lint 非零则失败。最终 RHEL/Fedora 三包均 0 errors/0 warnings。
2. 首次 fixture 的 --rpmdir 少一层 RPMS，读包时 StopIteration，在执行包事务前退出：
   [首次](rhel-first-scenario.log)。修正输入，保留首次。
3. V2 在 Type=simple 刚 start 时立即读到 init_t：[首次](rhel-early-context.log)。
   同包在实际邻接与 RIB/内核就绪后两个进程为 frr_t：[独立结果](socket-after-fix.log)。
   按 systemd fork/exec 语义推断为启动过渡状态，驱动改为先要求真实就绪再核对域，
   frr_t 断言保持，未将任意域视为成功。
4. 缺失模块负例正确阻止启动，但 stop 后 unit 已被 GC，reset-failed 返回 not loaded：
   [首次](rhel-negative-cleanup-first.log)。改为核对真实 inactive/0 状态，
   [完整重试](rhel-installed.log)通过；没有放宽模块缺失的失败要求。
5. 第一次 V3 fixture 未把 selinux_mode 写到新的 backend，CLI 在事务前拒绝：
   [首次](fedora-v3-lifecycle-first.log)。修正 backend 路径后[实测通过](fedora-v3-lifecycle.log)。
6. Fedora RPM 4.20 的 rmbuild 自动删除内层构建目录，V2 只保留顶层 stdout、摘要和原 rc，
   不声称已保留其完整 pytest 日志。新增 %build 归档 logs/fingerprint 到 topdir/evidence，
   V3 重建确认 rmbuild 后仍保留，最终 V3 安装、升级/回退也已执行。

## SELinux 边界和原系统保护

沿用既有 frr_t 与最小 rawip_socket node_bind 授权；该 allow 作用于整个 frr_t，
不声称单独 EGP 域。遵循 [Fedora 独立策略](https://fedoraproject.org/wiki/SELinux/IndependentPolicy)
的 priority-200 约定；现场宏会操作已有 400/extra_varrun，故以严格退出码的 helper
仅管理自身模块，不运行全局 fixfiles、varrun-convert、semanage fcontext 或 permissive 切换。

RHEL [完整矩阵 AVC 监听](rhel-avc.log)、[三包生命周期 AVC](rhel-lifecycle-avc.log)为空，
表示默认审计配置的监听窗口没有匹配 AVC，不扩大为所有访问路径已覆盖。
发行版 frr_t 下 Zebra 的部分 Generic Netlink 特性探测仍有 Permission denied/
unsupported 提示，见[启动诊断](rhel-startup-diagnostics.log)；本轮 EGP 邻接及路由断言通过，
没有为消除非目标特性的提示扩大发行版权限。

最终[原 RHEL 包与配置、路由、容器、FRR PID、fcontext/模块恢复](rhel-cleanup.log)；
原 200/frr 与 400/extra_varrun 的源 CIL/HLL SHA256 均不变，Enforcing 保持。
[Fedora 最终](fedora-cleanup.log)恢复原路由、容器清单、FRR PID 和策略 store，仍 Disabled。
RHEL 回到任务前原开发包对、inactive；Fedora 移除本轮项目 RPM 与所有实验/构建容器。
构建依赖、构建缓存和本轮证据保留；测试生成的 rpmsave 用于举证，没有全局 prune。

## 构建与校验

最终三个平台均 egpd/test_packet、check-TESTS 1/1 通过。
完整 make check 原 rc=2，各 14 failed/514 passed/5 skipped，未伪装为全通过。
使用各自本次直接日志逐条分类为禁用 isisd/pimd 后缺可执行文件及级联失败，
KNOWN=14、UNCLASSIFIED=0；未做启用这些模块的对照构建。

- RHEL：[make-check](rhel-make-check.log)、[分类](rhel-known-failures.md)、[指纹](rhel-fingerprint.txt)、[RPM](rhel-build.log)。
- Fedora 最终 V3：[make-check](fedora-make-check.log)、[分类](fedora-known-failures.md)、[指纹](fedora-fingerprint.txt)、[RPM](fedora-build.log)。
- Debian：[make-check](deb-make-check.log)、[分类](deb-known-failures.md)、[指纹](deb-fingerprint.txt)、[构建](deb-build.log)、[lintian](deb-lintian.log)。
- [验收驱动回归](driver-regressions.log)与[快速协议/哈希检查](quick-tests.log)通过。

公开日志脱敏私有路径/宿主名并规范行尾空白，原始记录留在执行环境；SHA256SUMS 覆盖本目录。
本轮未进行历史实现互通、长期丢包/乱序、多邻居压力，#16 在后续独立推进。
仍保持实验性/预发布；跨 x86、完整 Debian 宿主与更多 SELinux 发行版未验收。
