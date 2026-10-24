# 忠实度矩阵

对每个协议，记录「规范要求 / 已实现 / 简化 / 未实现」，以及它在 FRR 里占用的
**不可再生资源**（路由类型编号、显示码、vtysh 位）。加新协议前必须先在此登记。

---

## EGP（RFC 904）

| 项 | 内容 |
| --- | --- |
| 规范 | RFC 904《Exterior Gateway Protocol Formal Specification》，IETF 状态 **Historic** |
| 实现来源 | `lichenlang89/frr` tag `egp-verified-20261024` |
| 报文 | 版本 2；Acquisition(3) / Poll(2) / Update(1) / Reachability(5) / Error(8)；线格式按 RFC 904 附录 A |
| 路由类型 | `ZEBRA_ROUTE_EGP` = **32**，显示码 **`G`**，管理距离 **140** |
| vtysh 位 | `VTYSH_EGPD` = `0x400000` |
| 与 zebra 的交互 | 经 ZAPI 下发/撤销；zebra 解析下一跳并写内核（内核显示 `proto zebra`） |
| 默认计时器 | Hello 30s / Poll 120s（实验时用 2/6） |

### 已实现

- 报文编解码 + 校验和（含非对齐访问），单元测试含金样本/边界
- 邻居状态机：Idle / Acquisition / Down / Up / Cease；同一时刻支持 active 与 passive 两种模式
- 邻居级 raw socket（每邻居一个 `SOCK_RAW`，协议号 8），绑定 `local-address`
- `egp local-as` / `egp timers` / `egp network` / `egp neighbor`
- 路由学习、撤路（空 Update）、zebra 重连后重放、egpd 重启后恢复
- `show ip egp neighbors`、`show ip route egp`
- 配置持久化（集成配置 `frr.conf` + `write memory`）

### 简化 / 未实现（有意为之）

- 仅支持**默认 VRF**、**IPv4 有类网络**（A/B/C）；不支持 CIDR、IPv6、默认路由、同 AS 邻接
- 只接受配置邻居自己的网关，不导入第三方/core 路由（stub-gateway，不是 core gateway）
- 无认证、无 route-map、无重分发（`redistribute egp` 是可选补丁 0005，默认不启用）
- 最多 16 邻居、每邻居最多 255 条宣告或学习网络
- 跨 AS 不比较 metric：多邻居宣告同一前缀时取第一个仍存活的邻居
- 删除/关闭时尽力发送 Cease，无重传状态；Error 报文只校验不生成

### 验证状态

已真机验证：双向邻接、双向路由、内核下发、撤路/重宣告、重启恢复、配置持久化、pcap 逐包解码。
未验证：完整 `make check`、`frrinit/systemd` 启动、`frr_t` SELinux 域运行。

---

## GGP（RFC 823）

状态：**规划中，无代码**。加之前需要在此登记路由类型编号、显示码、vtysh 位。

## HELLO（RFC 891）

状态：**规划中，无代码**。同上。

---

## 已占用的不可再生资源

| 资源 | 已占用 | 说明 |
| --- | --- | --- |
| 路由类型编号 | 32 = EGP | 由 `lib/route_types.txt` 插入位置决定；上游若在该位置新增类型会导致编号漂移 |
| 显示码 | `G` | `show ip route` 里的单字母 |
| vtysh 位 | `0x400000` | 上游每加一个 daemon 就可能抢用，rebase 时必须检查 |
