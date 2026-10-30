# Issue #14 交接：EGP reload、配置删除和多网关接收

日期：2026-10-31（Asia/Shanghai）。基线：`8ae604e`。
分支：`codex/issue-14-egp-lifecycle`。关联：[Issue #14](https://github.com/lichenlang89/historic-routing/issues/14)。

## 已完成的修改

1. RPM/DEB 的 `ExecReload` 改用同树 `frr-reload.py --reload --daemon egpd`，显式指定
   bindir、confdir、可写 rundir、日志和 VTY socket，读取服务启动时的 `egpd.conf`。
   协议包包含脚本并依赖 Python 3；unit 留出 150 秒，覆盖 120 秒 Cease abort。
2. `no egp local-as [AS]` 复位到 0；`no egp timers [HELLO POLL]` 复位到 30/120。
   直接修改需无邻居（包括尚在清理的 Cease）；相同配置幂等。reload 遇全局参数变化时，
   先删除旧邻居，等匹配的 Cease-ack 或 abort 释放资源，再应用全局参数和目标邻居。
   纯 network 变化保留 PID、邻接及原路由。完整邻居删除语法不再依赖缩短参数重试。
3. `vtysh -C` 预检语法；语法失败在删除前返回非零。运行期语义错误仍可能部分应用，
   但会输出失败命令并返回非零，修正文件或重载备份配置可以恢复。reload 不是事务。
4. Update 接收内部/外部网关列表，逐候选保留来源标记；公共网络的网络地址、广播地址、
   本端地址等无效下一跳使整包拒绝，已有路由、遗漏计数及接收额度不变。
   同前缀的不同网关各自维护撤路/遗漏历史；按稳定邻居/候选顺序取存活候选，
   不跨 AS 比较距离。255 条上限现在按网络/网关候选计数。
5. 修正文档入口、Error/Refuse 范围及 RIB 导入说明；用户手册和 man 源在
   `protocols/egp/doc/`，集成到 FRR 的 `doc/user/egp.rst` 和
   `doc/manpages/frr-egpd.rst`，已注册 Sphinx、automake 和源码分发。

多网关依据：RFC 904 §4.4/A.4、RFC 888 §5/§8。接收间接网关与 core 路由中继分开；
本次没有实现转告学到的路由。`redistribute egp` 仅提供其它 daemon 的名字映射，
egpd 本身仍只显式宣告 `egp network`，不从本地 RIB 导入其它协议。

## 本次执行的验证

平台：RHEL 系宿主、aarch64、内核 6.12、rootful Podman；匹配的 Fedora 工具链/实验用户态。
测试时为基线加本 PR 工作树修改；提交前核对源码哈希。初次和最终构建的 egpd、zebra、
vtysh、libfrr 及更新后的 reload 脚本逐项比较，避免把旧产物的结果算给新源码。

| 检查 | 结果与边界 |
| --- | --- |
| 修复前对照 | HUP 后非僵尸 egpd 列表为空；完整删除 rc=1 且 AS/timers 残留；混合网关整包拒绝 |
| `scripts/test-egp.sh` | PASS：ASan/UBSan、独立金样本、边界、校验和、非对齐、网关分类/地址及逐候选老化；哈希与资源登记通过 |
| 最终 `verify.sh --build-only` | PASS 13 / KNOWN-FAIL 1 / FAIL 0；完整 fetch、补丁、源码集成、编译、安装、指纹和 `make dist` |
| `make check-TESTS` | PASS：EGP 1/1 |
| 完整 `make check` | 原始 rc=2；14 failed / 514 passed / 5 skipped。逐条直接异常指向已禁用 isisd/pimd 缺可执行文件；见 `docs/known-failures.md` |
| `lab.sh test-updates` | PASS：距离、混合撤路、全不可达、0、遗漏及恢复 |
| `lab.sh test-protocol` | PASS：原状态/窗口/Cease/错误回归，加混合内部/外部列表、无效下一跳整包拒绝、同前缀网关切换、逐候选遗漏老化 |
| `lab.sh reload` | PASS：network 无损/幂等；完整清空和重复应用；默认值、直接 CLI 约束；AS/timers 变更；语法/语义错误返回值、诊断及恢复；PID 不变 |
| 两个模板的真实 `ExecReload` 命令 | PASS：在隔离容器渲染并执行原模板命令，验证路径、增加/清空/幂等/错误/恢复、PID 不变；已接入 `lab.sh reload` |
| `lab.sh test-timers` | PASS：3/1、90/120、超过旧 120 秒期限存活、最终双端 Up、路由与恢复 |
| `lab.sh test` | PASS 13/13：RIB/内核、UDP 双向、撤路、egpd/Zebra 恢复与收尾 |
| HTML 用户手册 | Sphinx 7.4.7 构建成功，EGP 页面生成；19 条警告均在其它协议文档，未将整个上游手册称为零警告 |
| man 页 | Sphinx `-b man -W` 成功，生成 `frr-egpd.8`；两份 RST 均进入 `make dist` 源码包 |
| 格式与语法 | 修改的 C/H `clang-format --dry-run --Werror`、Python 编译与 `git diff --check` 通过 |

日志见 [本轮证据目录](../evidence/issue14/)。首次 reload 语义错误回归曾失败：返回码正确，
终端缺少失败命令；修正错误输出后通过，首次日志保留。Sphinx 在线安装失败后，使用离线
wheel 安装工具，没有改变产品逻辑。证据里的路径已去除个人工作目录。

## 尚未完成的验收与范围

- **没有完成新 RPM/DEB 包的构建、安装/升级后 `systemctl reload` 验收**。
  本机为 aarch64，现有 RPM spec 固定 x86_64；本次没有顺带修改包架构支持。
  模板命令等价测试通过不能代替这项验收。
- 尝试在独占容器根目录/网络命名空间配合宿主 systemd 执行服务测试，但测试适配环境
  先后遇到缺失配置目录、namespace 挂载和 EXEC Permission denied；未得到服务正常启动
  的结果，不能据此声明 systemd 或 SELinux 通过。相关日志保留，测试 unit/容器已清理；
  未关闭宿主 SELinux，也未变更系统 FRR 服务。
- 没有执行独立历史 EGP 实现互通、长时间丢包/乱序及并发压力；没有验证 SELinux `frr_t`。
  本轮没有重新跑 TShark；Lua 解析器未修改。EGP 是有类 IPv4 协议，CIDR/IPv6/认证为范围
  或扩展目标，不能笼统列成 RFC 904 实现缺陷。
- 因上述安装包服务验收与后续互通项目，PR 使用 `Refs #14`，不自动关闭整个跟踪 Issue。

## 接手后的操作

在标准 checkout 中按 `scripts/README.md` 构建，所有 daemon 和库始终使用同一次产物：

```sh
./scripts/test-egp.sh
./scripts/verify.sh --build-only --build-root "$PWD/build" --jobs 2
export LAB_PREFIX="$PWD/build/prefix" LAB_TIMERS="1 1"
cd lab/egp
./lab.sh up
./lab.sh test-updates
./lab.sh test-protocol
./lab.sh reload
./lab.sh test-timers
./lab.sh test
./lab.sh down
```

已有实验时先按实验手册配置独占 `LAB_*`，不要清理别人的资源。正式安装包验证应分别在
支持的 RHEL x86_64 与 Debian amd64 环境，从当前提交重建并安装匹配的 runtime+egp；
按 `packaging/` 手册操作，确认包内脚本、Python 依赖和 unit 的实际安装路径。
在隔离路由环境执行服务 reload，逐次记录 PID、两端邻居、RIB/内核与 journal；
包含 network、完整清空、AS/timers 和无效配置。最后再补升级与 SELinux 策略验收。

变更前保存 `egpd.conf`。语义失败后恢复文件并重新 reload，再检查两端邻接和路由；
若回退软件，runtime 与 egp 也必须成对回退。旧版本 unit 有已知 HUP 缺陷，维护窗口内
使用明确的进程重启流程，不能把重启恢复记为无损 reload。
