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
