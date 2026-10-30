# AI 协作指南

本文件供参与 historic-routing 的 AI 编码助手使用。`CLAUDE.md` 引用本文件，
项目规则只在这里维护；详细设计和操作步骤继续放在现有文档中。

## 开始工作

- 先运行 `git status --short`、`git branch --show-current`，查看与任务相关的未提交 diff。
  保留已有工作，不自动丢弃、覆盖或混入别人的改动；仅在确有冲突时询问维护者。
- 阅读 [README](README.md) 与任务相关的下表文档，再检查实际源码和脚本。
  历史日志说明某次运行的结果，不能代替当前分支的验证。
- 创建新实现前先搜索已有能力；修改前说明当前行为，并沿接收、状态更新、路由下发
  或构建调用链追踪相关文件，确认改动落在正确层次。
- 在用户已授权的范围内完成实现、检查和必要的文档更新。合理的小决策自行处理，
  遇到影响协议语义、兼容性或不可恢复操作的歧义时说明问题。
- 提交、推送、GitHub 评论、合并和发布按用户授权执行；审查请求本身不授权发布评论或合并。
- 提交前检查 `git status` 和暂存 diff，按明确路径暂存本任务文件；不要用
  `git add -A` 混入无关工作。保留未提交工作，未经授权不做破坏性重置或强制推送。

| 任务 | 优先阅读 |
| --- | --- |
| 协议行为与 RFC 差异 | [docs/FIDELITY.md](docs/FIDELITY.md)、[protocols/egp/README.md](protocols/egp/README.md) |
| FRR 接入、资源编号、新协议 | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、[docs/ADD_A_PROTOCOL.md](docs/ADD_A_PROTOCOL.md)、[patches/frr/README.md](patches/frr/README.md) |
| 构建和验证 | [scripts/README.md](scripts/README.md)、[CI 工作流](.github/workflows/) |
| 容器实验 | [lab/README.md](lab/README.md)、[docs/LAB_SAFETY.md](docs/LAB_SAFETY.md) |
| RPM/DEB、发行产物 | [docs/PACKAGING.md](docs/PACKAGING.md)、[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) |
| Wireshark 插件 | [wireshark/README.md](wireshark/README.md) |

## 复杂任务与中断恢复

跨模块、改变协议行为或需多轮实验的任务，先记录简短方案：当前需保留的行为、
修改原因、涉及文件、验收测试和主要风险。需要跨会话继续时，将方案及进度放在
`docs/plan/<task>.md`；小改动不必创建计划文件，也不要求为常规实现等待额外批准。

进度记录保留关键决定、失败证据、实际验证命令、尚未解决的问题和下一步，
区分计划与已完成事项。恢复工作时先核对分支、diff 和实验资源，不能假定环境仍与记录一致。

同一问题连续修复失败，尤其达到三次时，先停止叠加补丁，复核复现条件、日志和调用链，
总结已尝试的方法及其失败原因，再提出新的可验证假设。只有缺少用户决策或外部条件时
才请求帮助；不要靠放宽断言、删除有效测试或反复重试来制造通过结果。

## 项目边界和修改位置

这是基于 FRRouting 重现历史路由协议的实验项目。目前实现 EGP；GGP 和 HELLO 尚未实现。
`egpd` 通过 ZAPI 将路由交给 Zebra，由 Zebra 修改内核路由。所有协议共用同一次
构建的 Zebra、vtysh 和 libfrr，不为每个协议单独维护一套 FRR。

- 协议逻辑的维护源在 `protocols/<name>/src/`，单元测试在 `protocols/<name>/tests/`。
  EGP 的编解码在 `egp_packet.c`，邻居及 CLI 在 `egpd.c`，状态、可达性、老化与
  Update 窗口辅助逻辑在同目录的头文件中。
- FRR 接入改动维护在 `patches/frr/<name>/`；构建树中的副本由脚本生成。
  不要只修改 `build/frr-src/`、`build/frr-build/` 或安装目录后就交付。
- `patches/frr/BASELINE` 固定 FRR 提交。基线升级应明确列为任务范围，重新验证
  补丁、资源分配和构建，不能为绕过一个构建错误顺手升级上游。
- `protocols/<name>/PROTOCOL.meta` 是集成资源的唯一登记处。新增协议遵循登记顺序，
  保持已发布的 EGP 路由类型编号稳定；补丁默认应用 0001–0004，协议自带 0005 时才需要
  `--with-optional`（EGP 没有 0005，其 `redistribute` 映射已并入 0001）。
- 保持 automake 测试的累加注册，不能用新的 `TESTS =` 覆盖其他模块的测试。
  修改相关补丁前先读 `patches/frr/README.md` 中的注册顺序说明。

## 协议正确性

- 修改线上报文或状态机前，查阅原始 RFC，记录具体章节及其适用条件。
  EGP 主要依据 [RFC 904](https://www.rfc-editor.org/rfc/rfc904.html) 和
  [RFC 888](https://www.rfc-editor.org/rfc/rfc888.html)。区分规范要求、建议参数、
  本项目的选择及尚未实现的能力；不要把现有代码或自测结果当作规范。
- 接收路径显式验证长度、校验和、枚举值、地址、序列号和容量；不能用 `assert`
  代替对不可信输入的检查。畸形或超容量 Update 不应部分修改已有路由和老化状态。
- 修改邻居状态或定时器时，检查重传、重复包、序列号回绕、状态重置和上下界。
  同时检查双方的 active/passive 行为，不能只看一个邻居变为 Up。
- 修复协议缺陷时，先让回归在修复前因目标缺陷失败，再验证修复后通过；无法执行
  修复前对照时明确说明，不能把编译错误或环境失败当成成功复现。编解码测试除
  往返外，使用独立字节样本或原始报文对端，避免编码器和解码器共享错误却互相通过。
- EGP 当前是有类 IPv4 网络的实验实现。新增能力或改变拒绝行为时，同步更新
  `docs/FIDELITY.md` 和协议 README；已有第三方下一跳等限制不能写成 RFC 的定义。

## 构建、实验和验证

下面命令在仓库根目录的 Linux Bash 中运行。构建需 FRR 依赖和工具链，实验需
rootful Podman 及匹配的安装产物；以 `scripts/README.md` 和当前 CI 为准。
Windows 上可以编辑和做静态检查，完整构建与实验在合适的 Linux 环境执行。

```bash
# 不构建 FRR 的快速协议测试：编解码/辅助逻辑、ASan/UBSan、哈希、资源登记
./scripts/test-egp.sh

# FRR 接入与产物验证
./scripts/verify.sh --build-only --build-root "$PWD/build" --jobs 4

# 构建与隔离实验的统一验证
./scripts/verify.sh --all --build-root "$PWD/build" --jobs 4

# Wireshark 插件的离线回归（需要 TShark）
python3 wireshark/test_dissector.py --tshark tshark
```

统一验证不替代所有专项回归。协议行为变化还应按当前 `.github/workflows/ci.yml`
运行原始报文测试；已有匹配前缀时，可在独占的实验资源上使用：

```bash
export LAB_PREFIX="$PWD/build/prefix"
export LAB_TIMERS="1 1"
(
    set -euo pipefail
    cd lab/egp
    ./lab.sh build
    # 仅在资源名已确认独占后启用清理，避免误删已有实验。
    trap './lab.sh down' EXIT
    ./lab.sh up
    ./lab.sh test-updates
    ./lab.sh test-protocol
    # 分支提供慢定时器回归时一并运行（约数分钟）。
    if [ -f test_timers.py ]; then ./lab.sh test-timers; fi
    ./lab.sh test
)
```

- 使用 `lab.env.example` 的参数约定。已有实验或并行运行时，给
  `LAB_NAME_PREFIX`、`LAB_NET`、`LAB_SUBNET`、`LAB_IP1/2`、`LAB_RUNDIR`
  配置独占值，并确认 `lab.env` 没有覆盖预期参数。
- 只清理本任务创建的资源；不要使用全局 Podman prune、按进程名批量杀进程，
  或为实验重启系统 FRR。Zebra 会写路由，数据面测试放在隔离容器内。
- 测试应恢复修改过的配置与守护进程，失败时也保留诊断输出并清理本任务资源。
- 根据变更范围选择检查：纯文档改动检查链接、命令和 diff，无需完整重建；
  协议逻辑改动运行快速测试及相关原始对端/容器回归；FRR 接入、构建或打包改动
  还需对应构建、包安装与产物检查。不要用缩减检查冒充完整验证。
- `verify.sh` 的退出码为 0=PASS/KNOWN-FAIL、1=FAIL、2=用法/环境错误、
  3=SKIP。缺少环境时写明未执行项，不宣称通过。
- 完整 FRR `make check` 的已知失败见 [docs/known-failures.md](docs/known-failures.md)。
  必须依据本次失败的直接日志逐条判断，不能仅凭失败数量或目录就全部放行；
  EGP 自己的 `PASS: egpd/test_packet` 门禁应通过。
- 测试偶发失败也要保留首次日志，调查时序、资源冲突或环境原因；重试通过应记录为
  重试结果，不能覆盖失败事实。重构前确认原行为有覆盖，缺失时先补有意义的行为测试。
- 优先复用可执行检查：哈希与资源登记由现有脚本校验，格式及 SPDX 由 CI 检查。
  反复发生的错误再考虑新增自动检查或 hook；先验证其触发与失败行为，说明适用范围，
  不把文档规则或尚未启用的 hook 描述成已生效的门禁。

## 格式、哈希与证据

- 遵循 `.clang-format` 和周围代码；对修改过的 C/H 文件执行
  `clang-format --dry-run --Werror <files>`，对改动执行 `git diff --check`。
  脚本和源码保留对应 SPDX 标识，文本使用 LF。
- `protocols/egp/evidence/SOURCES.sha256` 跟踪当前源码及测试；相关文件变动后，
  用实际文件重新计算受影响的条目并核对差异。补丁变动对应更新
  `patches/frr/SHA256SUMS`。不要通过删校验项或跳过检查来消除失败。
- `MIGRATION.sha256`、历史日志、抓包和已发布清单记录过去的状态，保持其历史含义，
  新验证另存证据。`docs/known-failures.md` 由验证脚本生成，不手改结果。
- 需要保存验证证据时，记录提交/工作树状态、命令、平台、结果和限制；不记录凭据、
  个人 SSH 地址或本机私有路径，不将本地环境参数写进公共示例。

## 交付说明

向维护者说明改了什么、行为为何改变、实际执行了哪些检查及其结果，并列明未验证项。
区分代码审查、本次执行的测试、既有 CI 和历史证据。PR 应让未读过聊天的人也能
理解问题与验证范围；关联 issue 时确认修复范围确实满足其验收要求。

指南随项目演进维护：命令或行为发生变化时更新对应章节，新增详细材料放入现有
`docs/`、`scripts/` 或协议目录，并从这里链接，避免复制出互相矛盾的规则。

协作流程参考 [Thomas Mangin：Claude Code Best Practices](https://thomas.mangin.com/#Claude%20Code%20Best%20Practices)，
结合本仓库的协议实现、现有验证流程及任务授权方式调整。
