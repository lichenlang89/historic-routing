# 合并后的安装包服务验收

起点：PR #15 已合入，merge b22d0e8，已复核实现 179005d。Issue #14 保持开放。
本任务不再修改 PR #15，使用独立分支 codex/package-service-acceptance。

## 顺序与边界

1. 优先：实际重建、安装匹配 runtime + egp 包，验证原安装 unit 的 systemctl reload：
   network 增删/幂等、全量清空、AS/timers 变更、语法/语义错误和恢复。
2. 发布前：成对升级/回退、配置保护与依赖、起停/路由恢复、SELinux；此前保持实验性/预发布。
3. 以上完成后，历史实现互通、长期丢包/乱序、多邻居压力另开任务；本任务不推进协议扩展。

用户将执行环境限定为两台现有 aarch64 主机（RHEL 10.2 与 Fedora 42），
暂缓原 RHEL x86_64 / Debian amd64 要求；不能将本轮结果声称为 x86 验收。
DEB 在允许主机内的 Debian arm64 隔离环境构建和安装，按实际用户态/宿主内核记录。

## 实施约束

- 初始确认两台均运行系统 FRR，不停止/替换它；Zebra 服务和对端放在独占网络命名空间/容器。
- 从干净的确定提交构建，各发行版 runtime/egp 同源同次构建；正常包管理器解析依赖，
  不使用 --nodeps 或复制旧安装前缀冒充新包。
- RPM spec 原来固定 BuildArch x86_64；移除此限制让 rpmbuild 使用本机架构，ABI 绑定保留。
- 使用安装后的原始 ExecStart/ExecReload；测试所需 namespace drop-in 与业务配置明确记录，
  不把等价 kill、手动执行 reload 脚本或重启后恢复记作 systemctl reload 成功。
- 保存 PID、邻接、RIB/内核、退出码与 journal；错误配置应明确失败，语义失败可部分应用需恢复。
- 保存并恢复本任务配置、unit drop-in 和网络资源；不全局 prune，不关闭全局 SELinux。

## 初始状态

- 原宿主服务/容器/路由快照已保存到执行环境。
- RHEL 原生编译工具缺失；依赖预检发现 pytest 和 libyang-devel 不在当前启用仓库，待核对 CRB。
- Fedora 主机通过现有 RHEL 主机的 SSH 身份访问；尚无 Debian 系环境，正在获取原始 Debian 镜像。

## 第一阶段进度

- RHEL 10.2/aarch64 已从 00dcc4f 原生构建 RPM，并以正常 dnf 依赖解析安装匹配包。
  两个安装 unit 仅添加独占 NetworkNamespacePath drop-in，ExecStart/ExecReload 保持原样。
  实际 systemctl reload 已通过 network 增删/幂等、清空/重复清空、AS/timers、两类错误和恢复，
  PID 不变、原配置字节恢复。未停止原系统 FRR；SELinux 未关闭。
- Debian 首次构建因缺 libtool 失败，补齐 Build-Depends libtool-bin，日志保留。
- Debian 在线取固定 FRR 提交遇到 TLS 中断；改用校验过的离线镜像，复现 package-deb.sh
  仅复制 tar 而遗漏 SHA256SUMS/VENDOR.txt 的错误；补齐配套元数据后继续验证。

- Debian 13.7/arm64 已构建并正常 apt 安装匹配包，实际两容器 systemd reload 全部用例通过。
  首次容器 setup 因 /proc/sys 只读失败，改在 podman run 时设置 sysctl，保留首次环境日志。
- RHEL 默认配置启动时服务虽 active，但 journal 提示旧 prefix/run/egpd.log 不存在。
  RPM 默认配置改为 log stdout；DEB 也显式选择 stdout，由 systemd journal 收集。
  接下来用新开发包验证升级与回退。
- 本轮 Debian 第一版 lintian 的 3 条长行警告逐条保留；格式修正随新包重新验证。

## 本轮交接结果

- RHEL 与 Debian 已正常构建、安装匹配开发包，实际安装 unit 全部 reload 用例通过。
- 两端成对升级/回退/再升级、配置保留、依赖拒绝、服务起停与双向路由恢复通过。
- RHEL 默认进程域是 unconfined_service_t；Enforcing 下另以可选 frr_t 手动配置通过
  全量 reload/生命周期。最小 node_bind 扩展、目录标签与环境设置均有失败前证据。
  公共 .te/.fc 已编译、加载、复验；临时模块/标签规则与测试资源已恢复清理。
- Debian --keep 原先仍被 -tc 清掉原始构建日志，已修正；d098a0d 重建及安装复验通过。
- 两宿主所有 route table 快照与初始逐字节一致，容器清单恢复；原系统 FRR 保持运行。
- 当前详细证据、首次失败、具体版本、复测入口和限制见
  [本轮报告](../evidence/package-service-20261031/README.md)。
- 保持实验性/预发布：SELinux 策略尚未自动集成到 RPM 包的依赖/安装/卸载；Debian SELinux、
  完整 Debian 宿主及暂缓的 x86 架构不在已验收范围。互通/长期压力另开任务。

互通/长期压力后续任务：[Issue #16](https://github.com/lichenlang89/historic-routing/issues/16)，尚未执行。

## PR #17 审查修复（9d63c94 后续）

两个 P2 已核对成立：文本模式备份会规范化 CRLF，两个驱动均无法保证原始配置字节；
lifecycle 的事务后检查只查询 egpd，可能漏掉 Zebra 提前启动。

范围仅限两个验收驱动及其回归：增加二进制配置读写与原始字节/SHA256 校验，
逐个检查 egpd、Zebra 的 ActiveState/MainPID；不修改协议或安装包内容。
先在旧 head 上运行合法 CRLF 恢复及自动启动故障注入负例，再验证修复后通过；
使用现有包在原两台 aarch64 主机的独占资源内复测真实 reload/升级/回退，
保留首次失败，恢复配置、原 FRR、宿主路由和测试资源，再推送并回复两条审查。

审查修复执行结果：f33ce89 上两个 main 的真实文件/受控故障回归全部通过；
RHEL/DEB 的 CRLF 实际安装包 reload、成对升级/回退及独立 SHA256 一致。
Debian 私有脚本的 setup 和清理失败保留，按完整创建 ID 补清理后宿主状态恢复；
详见[本轮证据](../evidence/package-driver-review-20261031/README.md)。
