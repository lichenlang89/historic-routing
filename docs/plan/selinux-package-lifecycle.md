# SELinux 包管理集成（Issue #14 后续）

起点 main 3b09a58（PR #17 已合并，head 2a7e874，CI 6/6）。独立分支
codex/selinux-package-lifecycle；协议与 FRR 基线不变，继续开发/预发布。

## 设计

- 在现有 RPM spec 增加可选 noarch historic-routing-selinux 子包。显式安装该包才是
  受限部署；runtime/egp 不带策略时的 unconfined_service_t 不算受限验收。
- 子包严格依赖同版 runtime、发行版 frr-selinux、targeted 策略和 SELinux 工具；
  复用已验证 frr_t/node_bind 与文件标签，不扩展为新协议或独立域。
- 自己管理 priority 200 的 historic_routing_egp，安装/升级载入、定向重标本前缀及运行目录，
  vendor drop-in 管理 HOME/PYTHONNOUSERSITE 和每次启动的标签准备。
- 不使用本机会删除 400/extra_varrun 的宏：该模块在测试前已存在，必须保持不变。
  使用严格退出码的 semodule 仅管理本模块、restorecon 仅处理本项目前缀；不更改 frr 模块、
  本地 fcontext、布尔值或全局 Enforcing。已有手工同名模块拒绝自动覆盖。
- 首次安装 profile 前要求本项目两个服务已停止；不自动启动、重启或 enable。
  升级/回退不移除新版本模块；最终卸载先停自己的两个 unit，再移除本优先级模块并恢复标签。
- 修正 core RPM runtime/egp 各自的卸载 stop，防止运行的已删除 daemon 留存。
- RPM CI 补齐策略构建工具，安装使用正常 dnf 依赖解析，取消既有 --nodeps 路径。

## 验证与边界

仅原两台 aarch64 主机。RHEL 10.2 Enforcing 做真实域、reload、升级/回退、目录重建、
策略单独卸载与重装、整套卸载/配置保留/重装及路由恢复；只在独占 netns 中启动 Zebra。
Fedora 42 Disabled 验证本地同源匹配 RPM 与离线策略 store 生命周期，不冒充 MAC 受限验证。
配置按原始 bytes/SHA256 比对，两 unit 的 ActiveState/MainPID 单独核对。
保留首次失败和原始 make check；与任务前 route table、容器、原 FRR PID/SELinux 状态比对。
不安装 RHEL 包到 Fedora 伪造跨发行版兼容；不重跑未受影响的 Debian 构建来替代 RPM 验证。

## 当前状态

- 本机原有 400/extra_varrun、200/frr 和 /home/pxe 本地规则已确认，不覆盖。
- RHEL 旧本任务构建缓存约 929MB，root 剩约 2.1GB；归档日志/指纹后仅清理该旧 BUILD 缓存。
- Fedora 原 FRR/策略存在，SELinux Disabled；正在预检本机构建依赖。

## 首次实测与新增直接证据

- 首次三包构建成功，但新增说明长行/ghost 权限/重复 drop-in 触发 rpmlint 3 errors/2 warnings；
  逐条修复并让 package-rpm.sh 在 lint 失败时非零退出，首次日志保留。
- 两台首轮脚本因 RPM 目录层级参数错误在读包前失败，修正后独占实验继续。
- 策略首次活跃安装拒绝、实际 frr_t reload、目录根删除重建、在线 profile 重装、
  profile 单独卸载/重装均通过；未触碰原系统 FRR。
- EGP 单独卸载/重装后路由未恢复。独立复现：Zebra PID 保持 active，但停止 EGP 后
  zserv.api 消失，EGP 重启报告 zebra disconnected。原因是两个 unit 同时声明共享
  RuntimeDirectory；修正为仅 Zebra 管理（RPM/DEB 同步），不是延长超时或重启 Zebra 绕过。

## V2 验证进展

- fd0c3ed 在两台原生主机重建三包，rpmlint 均 0 errors/0 warnings；同源 DEB 构建完成。
- RHEL 首次 V2 刚 start 就读取 domain 得到 init_t；同包在真实邻接/RIB/内核就绪后
  两进程为 frr_t。测试等待真实就绪再查 domain，保留原始失败，不改变 frr_t 断言。
- 增加缺失模块的启动阻断和包重装恢复、手工 priority-400 模块碰撞拒绝负例。
  缺失模块能阻止启动；清理 stop 后 unit 可能 GC，改为核对 inactive/0，避免对
  已卸载缓存的 unit 调 reset-failed 导致测试误失败。
- 共享 socket 前后对照已通过；Debian 新包实际 egpd stop/start、完整 reload、CRLF
  字节比较通过；Fedora 完整 profile/EGP/整套移除重装矩阵通过。


完整矩阵与三包升级/回退均通过，宿主已恢复。归档发现 Fedora RPM 4.20 会在成功后
自动 rmbuild，导致原 build.sh 的完整 make-check 子日志丢失（顶层 stdout 与 rc 仍在）。
新增在 %build 成功时保存 logs/fingerprint 到 topdir/evidence，Fedora 再构建并验证保留；
旧记录不伪装为已有完整原始日志。将以 V2 → V3 三包实测覆盖该最终 Fedora 产物。
