# 忠实度矩阵（RFC 904 / EGP）

本文是账本：**我们到底实现了 RFC 904 的哪一部分、哪些是实验性简化、哪些根本没做**。
EGP 在 IETF 的状态是 **Historic**；这里的实现是实验性的 **stub gateway**，
**不是** RFC 904 意义上的 core gateway，也不是生产可用的路由协议。

新增历史协议前，必须先在本文登记它占用的**不可再生资源**（路由类型编号、显示码、vtysh 位）。

---

## 1. 报文覆盖

线格式按 [RFC 904 附录 A](https://www.rfc-editor.org/rfc/rfc904.html#appendix-A)；
版本号 2，固定 10 字节头，校验和覆盖整个报文（含非对齐访问，单元测试有金样本）。

| 类型 | 编号 | 发送 | 接收 | 说明 |
| --- | --- | --- | --- | --- |
| Update | 1 | 是 | 是 | 携带 `(网络, 网关, distance)`；255 立即撤路，连续三次遗漏后老化 |
| Poll | 2 | 是 | 是 | 双方在 Up 时按 `poll` 间隔询问；收到 Poll 用 Update 回答 |
| Acquisition | 3 | 是（code 0/1/3/4） | 是 | 邻居获取：Request/Confirm/Cease/Cease-ack；**code 2 = Refuse 能解码但从不发送** |
| Reachability | 5 | 是（code 0/1） | 是 | 本实现用作邻居存活探询（code 0）与确认（code 1） |
| Error | 8 | **否** | 是 | 只解码并拒绝，不生成；EGP 的 Error 语义未实现 |

### 报文级简化

- 每条 `struct egp_route` 只带**有类网络号**（A/B/C 首字节判定），不支持 CIDR、超网、默认路由。
- `distance == 255` 视为"不可达"，用于表达撤路。
- Update 编码按实际 distance 分组（RFC 904 附录 A.4）；本机配置的 network 使用
  distance 1。接收端按 RFC 888 第 5 节合并新通告并保留尚未达到遗漏次数的旧网络；
  一份报文可以同时撤销 distance 255 的网络并学习其它可达网络；0–254 均视为可达。
- 按 RFC 888 §5，连续遗漏需要多次确认；本实现选择三次有效 Update（RFC 未指定次数）。
  第一次、第二次遗漏保留路由，第三次移除；网络重新出现会清零其遗漏次数。
  空 Update 同样计入遗漏，显式 255 不等待老化。重复网络或超过 255 条保留容量的
  更新被原子拒绝，不改变现有路由和遗漏次数。
- 单包上限 `EGP_MAX_PKT = 1500`，单包路由上限 `EGP_MAX_ROUTES = 255`。
- 只接受 `gateway == 邻居地址` 的路由；任一第三方下一跳会导致整份 Update 被拒绝，
  包括其中由对端自身宣告的路由。RFC 888 第 5/8 节中的 stub 也需要接收 core 的
  多网关通告以学习间接邻居；这是本实现的互通限制，不是 stub/core 的定义分界。

## 2. 邻居状态机

CLI 里可见的五个状态（`show ip egp neighbors`）：

| 状态 | 进入条件 | 离开条件 |
| --- | --- | --- |
| Idle | 配置了邻居但还没发过请求 | 发送 Acquisition Request |
| Acquisition | 已发 Request，等 Confirm | 收到 Confirm → Down/Up；超时重试 |
| Down | 邻居确认但可达性不足 | active 窗口内 3 次有效指示、passive 1 次有效 Up 指示 → Up |
| Up | 双方就 AS、timers 达成一致 | 对端 Cease、连续无响应、配置删除 |
| Cease | 在 Down/Up 收到本地 Stop（删邻居或 SIGTERM） | 匹配 Cease-ack、对端 Cease、第二次 Stop 或 P5 到期 → Idle |

- **active / passive** 由 AS 号决定（`local_as < peer_as` 的一方为 active），
  也接受对端在报文中声明的角色。
- Refuse 将 Acquisition 变为 Idle，停止获取；用 `clear ip egp neighbor <ip>` 显式重新 Start。
- 删除邻居时先撤路，保留 socket 等待 Cease-ack；每 P3=30s 重发相同序列号 Cease，
  P5=120s 无确认则释放资源。收到 Cease 总是回 Cease-ack 并进入 Idle，Idle 也能确认重复 Cease。
- Acquisition 同样用 P3=30s 重发 Request、P5=120s 终止。完成获取进入 Down 后，
  初始 abort hold 为 `MAX(P5, 4*T1)`，给慢 Hello 留出完整可达性窗口；Down/Up
  收到有效可达性指示时延至 `MAX(P4, 4*T1)`，其中 P4=3600s。
  Cease 仍使用 P5；默认定时器下的 hold 不变。
- SIGTERM 继续事件循环完成停止握手，第二次信号强制退出；外部服务管理器的退出期限仍适用。
- 对端 AS 与本端一致时不建立邻居；这是本实现的配置限制，RFC 904 也讨论同 AS 邻居。

### 可达性窗口（RFC 904 §3.3 / §4.3）

- active：Confirm、匹配且未消费的 I-H-U/Poll Update 响应计入窗口。
- passive：Hello/Poll 的 Up 状态以及有效 Update 的 Up 状态计入窗口。
- 使用四个 T1 的移动时间窗口，每 T1 最多接受一个指示；active 3 次进入 Up、
  降至 1 次进入 Down；passive 首次进入 Up、四个 T1 无指示后进入 Down。
- 重复 I-H-U、错误序列号和无效 Update 不刷新窗口；延迟的 event-loop tick 不延长旧指示寿命。
- `lab.sh test-protocol` 在 `LAB_TIMERS="1 1"` 的隔离实验中验证只有 Update 或
  Poll 时的存活、错误响应和指示过期；codec 单测包含可控时钟边界。

### 主动 Update（RFC 904 §4.1.1 / §4.4）

- 进入 Up 或本地 network 改变时标记更新；在发送预算允许时发送带 128 位的 Update。
  相同内容已由普通 Poll 响应发送后，不额外补发主动更新。
- 发送端记录最后一个有效命令的序列号 R，主动更新使用 R；两个不同 Poll 之间
  最多发送一次额外 Update。重复相同序列号 Poll 的第二次回复也消费此预算，
  与主动 Update 共用；预算已用时忽略后续重复 Poll，新 Poll 才重置预算。
- 接收端检查当前发送序列号 S、共享网络、报文格式、网关与容量；每个发出的 Poll
  区间最多接收一次主动更新。主动更新不消费仍未收到的普通 Poll 响应。
- Hello 复用当前 S，发送新 Poll 时递增 S（包括 16 位回绕），与 RFC 建议一致。
- Down 状态不处理主动 Update（RFC 允许此项可选）；无认证、第三方网关和 Error 生成的限制仍在。

## 3. 定时器

| 参数 | 默认 | 实验值 | 行为 |
| --- | --- | --- | --- |
| Hello（`egp timers <hello> <poll>` 的第一个） | 30s | 2s | active 方周期发 Reachability 探询 |
| Poll | 120s | 6s | 双方在 Up 时周期发 Poll 拉取完整 Update |
| 邻居协商 | — | — | 收到对方 timers 时取 `MAX(本端, 对端)` |

Hello/Poll 最小间隔独立验证、协商，不要求 Poll 大于等于 Hello。

## 4. 已支持 / 简化 / 未实现

**已支持**

- `egp local-as`、`egp timers`、`egp network`、`egp neighbor <ip> local-address <ip> remote-as <as>`
- 路由学习与撤销（空 Update、distance=255、删除 network、删除邻居、进程退出）
- ZAPI 下发（类型 `ZEBRA_ROUTE_EGP`=32、显示码 `G`、管理距离 **140**），由 zebra 装内核
- zebra 重连后重放路由；egpd 重启后邻居与路由重建
- `show ip egp neighbors`；配置持久化（`write memory` 到集成 `frr.conf`）
- `show ip route egp` 与 `redistribute egp`（`lib/log.c` 的 `proto_redistnum` 映射随 `0001` 应用，
  默认构建即生效）
- vtysh 集成（`VTYSH_EGPD = 0x400000`）

**实验性简化（有意为之，改动需单独提交）**

- 只支持**默认 VRF**、IPv4、**有类网络**；无 IPv6、无 CIDR、无 VRF 感知
- 每进程最多 **16 个邻居**（`MAX_PEERS`），每邻居最多 255 条网络
- 同前缀多邻居时不做 metric 比较，取第一个仍存活邻居的宣告
- 无认证、无 route-map（`redistribute egp` 自 S9 起默认可用，不再依赖可选补丁）
- Request/Cease 有重传及 abort timer；Poll 丢失后等待下一个周期，未实现可选的 T1 快速重试
- 日志走文件/stdout，未接 FRR 的结构化日志与 YANG northbound

**未实现**

- core gateway 行为：第三方路由的中继、EGP 邻居之间的路由再分发、距离/度量比较
- Error 报文生成；正式的错误码语义
- 与系统 FRR 服务（`frrinit`/systemd/`watchfrr`）的集成：`daemons` 文件里有条目，
  但本项目**不启动系统服务**，实验一律显式跑二进制
- SELinux `frr_t` 域下运行

## 5. 验证状态（截至 S6）

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 报文编解码 + 校验和（金样本/边界/非对齐） | 通过（现场执行） | `egpd/test_packet`：`verify.sh` B5/B6 |
| 双路由器邻接、双向学习、类型 G、距离 140 | 通过（容器实跑） | `protocols/egp/evidence/lab-test-20261024.log`（13/13） |
| 内核路由、Stub 间 UDP 双向通信 | 通过 | 同上（检查 05/06） |
| 撤宣告/重宣告、egpd 异常退出、egpd 重启、zebra 重启、删邻居 | 通过 | 同上（检查 07–12） |
| 完整 `make check` | 14 项失败，逐条证据为"被 `--disable` 的模块缺少可执行文件" | `docs/known-failures.md` |
| 跨发行版 / 全新机器 | **未验证** | 只有一台 RHEL 10.1 机器可用；不声称跨发行版兼容 |
| 系统服务 / SELinux 域 | **未验证** | 见上节"未实现" |

### RFC Update 回归入口

在 `lab/egp` 下执行 `./lab.sh up` 后，运行 `./lab.sh test-updates`。
测试临时暂停实验 R2 的 egpd，用独立 Python 原始报文对端响应 Hello/Poll，
检查非默认 distance、混合可达/不可达、全不可达、distance 0 与空 Update 的 RIB/内核结果；
finally 恢复原 daemon 并确认双向路由恢复。显式撤路断言在两个 Poll 周期内完成，
小于三个 Poll 周期的旧路由过期时间，避免把超时撤路当成显式撤路成功。
`test-protocol` 另逐包检查首次/二次遗漏保留、重新出现复位、第三次遗漏撤路。
同时检查重复 Poll 回复与主动 Update 两种次序共享额度，以及 Hello=3/Poll=1 的获取。
单元测试覆盖慢 Hello 的 abort hold 下界和最大 16 位 Hello 值。
`./lab.sh test-timers` 另外实跑两端 `3/1` 和 `90/120`，检查超过旧 120 秒期限仍保持
获取状态、最终双端 Up 与路由交换，以及原定时器恢复；该项约需 5 分钟。
使用快速实验 timers（默认 `2 6`），结束后执行 `./lab.sh down`。

含第三方网关的 Update 仍整包拒绝，
普通响应须匹配未决 Poll，主动更新须匹配当前 S 并满足上述次数限制。

## 6. 已占用的不可再生资源

登记处是 `protocols/<name>/PROTOCOL.meta`（机器可读，`scripts/check-allocations.sh` 校验）；
分配规则见 `docs/ARCHITECTURE.md`「多协议」。

| 资源 | EGP 占用 | 下一个可用的值 | 说明 |
| --- | --- | --- | --- |
| 路由类型编号 | **32**（`ZEBRA_ROUTE_ALL`=33、`MAX`=34） | 33（`ALL`/`MAX` 随之后移） | 编号由 `lib/route_types.txt` 的**插入位置**决定；只能追加在已发布协议之后 |
| 路由类型名字串 | `egp` | 自定，需唯一 | `show ip route <name>` / `proto_redistnum` 用它 |
| 显示码 | `G` | 任意未被基线占用的字母 | `show ip route` 里的单字母 |
| 管理距离 | 140 | 141、142…（建议按协议递增） | zebra 选路优先级 |
| vtysh 位 | `0x400000` | `0x800000` | 保留区间 `0x400000`..`0x3FFFFFF`；上游每加 daemon 都可能抢用 |
| CLI 节点 | `EGP_NODE` | 任意唯一名 | `lib/command.h`，插在 `NODE_TYPE_MAX` 之前 |
| daemon 名 | `egpd` | 任意唯一名 | 也是源码目录与可执行文件名 |

## 7. 后续协议

| 协议 | 状态 | 备注 |
| --- | --- | --- |
| GGP（RFC 823） | 规划中，无代码 | 加入前必须在此登记新的路由类型编号/显示码/vtysh 位 |
| HELLO（RFC 891） | 规划中，无代码 | 同上 |
