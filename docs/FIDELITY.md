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
| Update | 1 | 是 | 是 | 携带 `(网络, 网关, distance)` 三元组；**空 Update 表示撤销全部** |
| Poll | 2 | 是 | 是 | 主动方按 `poll` 间隔询问；收到 Poll 用 Update 回答 |
| Acquisition | 3 | 是（code 0/1/3/4） | 是 | 邻居获取：Request/Confirm/Cease/Cease-ack；**code 2 = Refuse 能解码但从不发送** |
| Reachability | 5 | 是（code 0/1） | 是 | 本实现用作邻居存活探询（code 0）与确认（code 1） |
| Error | 8 | **否** | 是 | 只解码并拒绝，不生成；EGP 的 Error 语义未实现 |

### 报文级简化

- 每条 `struct egp_route` 只带**有类网络号**（A/B/C 首字节判定），不支持 CIDR、超网、默认路由。
- `distance == 255` 视为"不可达"，用于表达撤路。
- Update 编码按实际 distance 分组（RFC 904 附录 A.4）；本机配置的 network 使用
  distance 1。接收端按 RFC 888 第 5 节过滤 distance 255 的网络，再整体替换该邻居的
  路由集合，因此一份报文可以同时撤销不可达网络并学习其它可达网络；0–254 均视为可达。
- 单包上限 `EGP_MAX_PKT = 1500`，单包路由上限 `EGP_MAX_ROUTES = 255`。
- 只处理 `gateway == 邻居地址` 的路由，第三方网关（core gateway 的转发路由）一律丢弃：
  这正是 "stub gateway" 与 "core gateway" 的分界。

## 2. 邻居状态机

CLI 里可见的四个状态（`show ip egp neighbors`）：

| 状态 | 进入条件 | 离开条件 |
| --- | --- | --- |
| Idle | 配置了邻居但还没发过请求 | 发送 Acquisition Request |
| Acquisition | 已发 Request，等 Confirm | 收到 Confirm → Down/Up；超时重试 |
| Down | 邻居确认但不可用（刚建立或对端 Cease） | 收到 Reachability/Update → Up |
| Up | 双方就 AS、timers 达成一致 | 对端 Cease、连续无响应、配置删除 |

- **active / passive** 由 AS 号决定（`local_as < peer_as` 的一方为 active），
  也接受对端在报文中声明的角色。
- 关闭或删除邻居时尽力发送 `Acquisition code 3 (Cease)`；**无重传状态机**，
  丢包就只靠对方超时。收到 Cease 回 `code 4 (Cease-ack)`。
- 对端 AS 与本端一致时不建立邻居（RFC 904 要求跨 AS）。

## 3. 定时器

| 参数 | 默认 | 实验值 | 行为 |
| --- | --- | --- | --- |
| Hello（`egp timers <hello> <poll>` 的第一个） | 30s | 2s | active 方周期发 Reachability 探询 |
| Poll | 120s | 6s | active 方周期发 Poll 拉取完整 Update |
| 邻居协商 | — | — | 收到对方 timers 时取 `MAX(本端, 对端)` |

## 4. 已支持 / 简化 / 未实现

**已支持**

- `egp local-as`、`egp timers`、`egp network`、`egp neighbor <ip> local-address <ip> remote-as <as>`
- 路由学习与撤销（空 Update、distance=255、删除 network、删除邻居、进程退出）
- ZAPI 下发（类型 `ZEBRA_ROUTE_EGP`=32、显示码 `G`、管理距离 **140**），由 zebra 装内核
- zebra 重连后重放路由；egpd 重启后邻居与路由重建
- `show ip egp neighbors`；配置持久化（`write memory` 到集成 `frr.conf`）
- vtysh 集成（`VTYSH_EGPD = 0x400000`）

**实验性简化（有意为之，改动需单独提交）**

- 只支持**默认 VRF**、IPv4、**有类网络**；无 IPv6、无 CIDR、无 VRF 感知
- 每进程最多 **16 个邻居**（`MAX_PEERS`），每邻居最多 255 条网络
- 同前缀多邻居时不做 metric 比较，取第一个仍存活邻居的宣告
- 无认证、无 route-map、无 `redistribute egp`（那是可选补丁 0005，默认不启用）
- 主动发送的报文不做重传；超时靠定时器扫表
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
finally 恢复原 daemon 并确认双向路由恢复。撤路断言在两个 Poll 周期内完成，
小于三个 Poll 周期的旧路由过期时间，避免把超时撤路当成显式撤路成功。
使用快速实验 timers（默认 `2 6`），结束后执行 `./lab.sh down`。

这组改进仍保留既有简化：未宣告的网络在下一份完整 Update 中立即删除；
RFC 888 第 5 节描述的连续多次遗漏后老化尚未实现。含第三方网关的 Update 仍整包拒绝，
只接收与未决 Poll 的序列号及共享网络匹配的普通响应，不处理 unsolicited Update。

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
