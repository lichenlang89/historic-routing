# Issue #16 / S-A 互通记录：GateD 3.6 ↔ egpd

日期：2026-11-01（Asia/Shanghai）。基线 `main` = `4b81f2a`。
平台：RHEL 10.2 aarch64 独占实验主机（2 vCPU，SELinux Enforcing，rootful Podman 5.8.2）。
本文件只记录**实际执行**的结果；未验证的部分不写成通过。

## 1. 结论摘要

| 项 | 状态 |
| --- | --- |
| 独立历史实现可获取、许可可查 | 通过（GateD 3.6，见 §2） |
| 在现代工具链构建并运行 | 通过（7 个文件的移植补丁，见 §3） |
| gated ↔ egpd 邻居 Up（双向） | **通过**（2026-11-01 23:50–23:52） |
| Acquire / Hello / Poll / Update 双向交换 | 通过（抓包可逐字段解码，见 §5） |
| gated 通告路由（带路由的 Update） | **通过**：export 加 `metric 1` 后通告 `172.16.0.0/16`，距离 1（见 §5.2） |
| egpd 装表（EGP → Zebra → 内核） | **通过**：`Up active 2`、`G>* 172.16.0.0/16 [140/1]`、内核 `proto zebra` |
| 撤路 / 老化 / Cease / 主动被动 / 定时器协商 | **未验证**（见 §7） |

一句话：**邻居层、报文层与单条路由的装表链路已互通**；剩下的撤路/老化、Cease、角色与定时器矩阵未做。
序列号那一条已按 RFC 904 §4.1.1 判为对端更严格，不构成 egpd 缺陷（§6 P0-1）。

## 2. 独立实现来源

- 来源：`https://bio.nic.funet.fi/pub/mirrors/ftp.gated.merit.edu/research.and.development/gated/gated-3-6.tar.gz`
- 文件：`gated-3-6.tar.gz`，1 135 677 字节，
  `sha256 = 60beeb04349e7061d4f1398ef3dc888ef8934baaa8b7cdda61172d060ce42da5`
- 内容：`gated-public-3_6`，EGP 在 `src/egp/egp.c`、`egp_init.c`、`egp_rt.c`
- 许可：包内 `README` 第 5–36 行为 Merit GateD Consortium 授权条款（允许使用、复制、修改、
  再分发，附免责声明）；`licenses/v3/stamp` 是占位文件。本记录不复述条款全文。
- 该实现与 `protocols/egp/` **没有任何共享代码**，因此是"独立实现"意义上的互通对端。

## 3. 移植改动（全部在第三方源码树内，本仓库不改产品代码）

补丁：[`gated-3.6-port.patch`](gated-3.6-port.patch)（187 行，7 个文件）。
已实测可直接 `patch -p1` 应用到 pristine `gated-public-3_6`。

### 3.1 让 2000 年代码在现代工具链编译

1. 编译参数：`-std=gnu89 -fcommon -D_GNU_SOURCE -DYYDEBUG=1`，关闭旧式 `-Werror` 假设。
2. `src/krt_os/krt_symbols_proc.c:98`：对强转赋值 `resp = (char *) fp = fopen(...)` →
   `resp = (char *)(fp = fopen(...))`。
3. `src/gii/gii.h`：`char [][]` 原型（gcc 2.x 扩展）→ `char [GIITOKENLEN][GIINBMAXTOKENS]`。
4. `src/gated/list.h:89,97,103`：`((list_t *)start) = ...` → `(start) = ...`。
5. `src/gated/lexer.l:181`：`int yylineno = 0;` → `extern int yylineno;`（flex 2.6 自带定义）。
6. `parse.o`/`lexer.o` 需以 `-DYYDEBUG=1` 重编（bison 3 只在 YYDEBUG 下定义 `yydebug`）；
   `make depend` 后再 `make`。

### 3.2 现代 Linux 内核语义差异（决定 EGP 能否建链）

7. `src/krt_os/krt_ifread_netlink.c`：`IFA_ADDRESS` 只在链路是 point-to-point 时才算对端地址。
   现代内核给普通接口同时下发 `IFA_ADDRESS` 与 `IFA_LOCAL`（值相同），原逻辑把每个接口都标成
   P2P，`if_conf_addaddr` 于是按"测试模式重复地址"把整条接口丢弃。
8. 同文件：内核未下发 `IFA_BROADCAST` 时按 `addr | ~mask` 推导；原来填 0.0.0.0，会被判为
   非法广播地址并丢弃整个接口。
9. `src/egp/egp.c` `egp_check_packet()`：长度比较改为 `ntohs(ip->ip_len) - hdrlen`。
   Linux 原始套接字返回的 IP 头 `ip_len` 是网络字节序且仍含头长；BSD 的 `ip_input` 已转换并
   减去头长，原代码假设后者。
10. 同函数：分片判断改为 `ntohs(ip->ip_off) & ~IP_DF`；否则带 DF 的正常报文会被判为分片丢弃。
11. `src/egp/egp_init.c` `egp_ngp_ifa_select()`：找不到接口且配置了显式 `lcladdr` 时，
    按该地址合成接口条目。**这是单邻居实验的临时兜底**：它改变接口选择，且对触发兜底的
    所有邻居共享同一个静态条目。本次记录的 bridge 拓扑实际命中真实接口
    （`egp_event_start: ... local interface 198.18.161.2 (br16)`，见
    [`gated-interface-selection.txt`](gated-interface-selection.txt)），因此该分支未被走到；
    保留它只是为了在 veth/lo 场景下继续排查。

## 4. 运行边界（实测得出，不是设计意图）

- gated 必须以 `-n`（不修改内核 RIB）运行。它自带的接口路由安装路径在本实验里会删除内核
  connected 路由，导致随后 `connect()` 返回 `ENETUNREACH`。`-n` 保持内核路由原样；
  代价是 gated **学到的路由不写内核**，只能从其自身 RIB 读取。
- gated 默认启用 RIP，会在实验室网段跑 RIP（不影响 EGP 判定，但正式矩阵应显式关闭）。
- gated 的配置语句**有顺序约束**：`export` 必须在协议语句（`egp yes { ... };`）之后；
  写前面会级联出 `statement out of order at 'egp'` 与 `syntax error at '}'`。
- export 源必须匹配路由来源。本实验里接口/内核路由记为 `Kernel`，因此需要
  `proto kernel { all; }`（`proto direct` 亦可）；`announce` 关键字已废弃，
  `172.16.0.0 mask ...` 这种逐条写法本次解析失败。

## 5. 实测证据（2026-11-01 23:50–23:52）

egpd 侧（[`egpd-neighbors.txt`](egpd-neighbors.txt)）：

```
EGP local AS 65001, zebra connected, 1 network(s) configured
Peer             AS     State        Mode     Prefixes
198.18.161.2 65002 Up active 0
```

gated 侧（[`gated-egp-trace.txt`](gated-egp-trace.txt)）：
`egp_state_down: acquired neighbor 198.18.161.1 AS 65001 in PassiveMode`，随后进入 `state Up`，
`egp_event_hello` / `egp_event_update` / `egp_event_reachability` 在 Up 下持续触发。

线缆：pcap 共 22 条记录，按 `(ip_id, 源, 目的, 载荷)` 去重后是 **11 个唯一报文**
（bridge `br16` 与 veth `hr16b0` 各捕到一次；接口索引 5 / 458）。tcpdump 自带解析器只解出
其中一部分，文本解码 44 行里 18 行是 `[|egp]`；因此下表用本目录的
[`decode_egp_pcap.py`](decode_egp_pcap.py)（按 `protocols/egp/src/egp_packet.c` 的布局解码）
生成，原始输出见 [`interop-neighbors-up.table.txt`](interop-neighbors-up.table.txt)：

| 时间（相对首帧） | 方向 | 类型 | code | status | U | AS | seq | 长度 | 路由（网络 / 网关 / 距离） |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| +0.000 | .1 → .2 | Reach | 0 | 2 | 0 | 65001 | 2 | 10 | — |
| +0.001 | .2 → .1 | Reach | 1 | 2 | 0 | 65002 | 2 | 10 | — |
| +1.001 | .1 → .2 | Poll | 0 | 1 | 0 | 65001 | 3 | 16 | — |
| +1.001 | .1 → .2 | Update | 0 | 1 | **1** | 65001 | **1** | 21 | 10.0.0.0 / 198.18.161.1 / 1 (int) |
| +1.002 | .2 → .1 | Poll | 0 | 1 | 0 | 65002 | 2 | 16 | — |
| +1.002 | .1 → .2 | Update | 0 | 1 | 0 | 65001 | 2 | 21 | 10.0.0.0 / 198.18.161.1 / 1 (int) |
| +1.002 | .2 → .1 | Update | 0 | 1 | 0 | 65002 | 3 | 25 | 172.16.0.0 / 198.18.161.2 / **255** (int)；198.18.161.0 / 198.18.161.2 / **255** (int) |
| +30.034 | .1 → .2 | Reach | 0 | 1 | 0 | 65001 | 3 | 10 | — |
| +30.034 | .2 → .1 | Reach | 1 | 1 | 0 | 65002 | 3 | 10 | — |
| +60.080 | .1 → .2 | Reach | 0 | 1 | 0 | 65001 | 3 | 10 | — |
| +60.081 | .2 → .1 | Reach | 1 | 1 | 0 | 65002 | 3 | 10 | — |

即 Acquire → Confirm 后两侧进入 Up，Reach/Poll/Update 双向流动，AS 与状态字段与配置一致。

关键点：gated 那条 25 字节 Update 里两条路由的**距离都是 255**。EGP 中 255 表示
"不可达/撤销"，因此 egpd 侧 `Prefixes 0`、无 `G>` 路由、内核无 172.16 表项**是预期行为**，
不能据此判定为接收路径缺陷（见 §6 P0-2 的改写）。

### 5.2 有限距离导出与装表（2026-11-05 02:40，同一次会话）

gated 的 export 加 `metric 1`（见 [`gated.conf.export`](gated.conf.export)），
并在**启动邻居之前**开始抓包，覆盖 Acquire → Up → 装表全过程。
原始证据：[`install-session.pcap`](install-session.pcap)、
[`install-session.table.txt`](install-session.table.txt)。

会话前段（完整 14 帧见 table）：

```
Acquire  .1 -> .2  seq=1 hello/poll=2/6        # egpd Request
Acquire  .2 -> .1  seq=1 hello/poll=30/120     # gated Request
Acquire  .1 -> .2  code=1 seq=1 hello/poll=2/6 # egpd Confirm
Reach    .1 -> .2  code=0 seq=1 ；.2 -> .1 code=1 seq=1   # 每 30s 一次
Poll     .1 -> .2  seq=2
Update   .1 -> .2  U=1 seq=1  route 10.0.0.0 gw .1 distance 1      # 非请求 Update
Poll     .2 -> .1  seq=2
Update   .1 -> .2  U=0 seq=2  route 10.0.0.0 gw .1 distance 1      # 对 Poll 的回复
Update   .2 -> .1  U=0 seq=2  route 172.16.0.0 gw .2 distance 1
                              route 198.18.161.0 gw .2 distance 1
```

同轮状态快照（均为实测输出）：

| 层 | 证据 |
| --- | --- |
| egpd 邻居 | `198.18.161.2  65002  Up  active  2`（[`egpd-neighbors-after-install.txt`](egpd-neighbors-after-install.txt)） |
| Zebra RIB | `G>* 172.16.0.0/16 [140/1] via 198.18.161.2, hr16a0`；`G 198.18.161.0/24 [140/1] ... inactive`（与直连同前缀，未选路） |
| 内核 | `172.16.0.0/16 nhid 18 via 198.18.161.2 dev hr16a0 proto zebra metric 20` |

即「报文到达 → egpd 接收并计数 → Zebra 选路 → 内核安装」四段全通；
`198.18.161.0/24` 被 egpd 收到但安装为 inactive，属于与本机直连前缀冲突，选路正确。

## 6. 当前问题清单（按严重度）

**P0-1 Update 序列号：已定性为对端更严格，不是 egpd 缺陷**
gated 报 `egp_event_update: neighbor 198.18.161.1 AS 65001: Sequence 1 expected 2`。
抓包（§5.2）显示 egpd 的**非请求** Update 带 `U=1, seq=1`，而它此前的 Poll 是 `seq=2`。
RFC 904 §4.1.1 原文：

> The state variable R records the last sequence number received in a **command** from that
> neighbor. The current value of R is used as the sequence number for **all replies and
> indications** sent to the neighbor until a command with a different sequence number is
> received from that neighbor.

而 RFC 904 §3/§4 对消息分类写明：Update 既是 response 也是 indication，
"an unsolicited Update message … is classed as an **indication**"。因此 egpd 在非请求 Update
中使用 R（gated 最后一条**命令**是 `Request seq=1`）符合 §4.1.1；gated 按自己 `S=2` 的期望
判错，属于比 RFC 更严格的实现（RFC 对序号不符只写"不建议规定，推荐丢弃"）。
结论：**不据此改 egpd**；作为互通限制记录，后续在文档/FIDELITY 说明对端这一行为。

**P0-2 有限距离通告与装表：已通过（历史问题已定位）**
第一次失败的原因是 gated 的 export 没有设 `metric`，通告距离为 255（=撤路），
所以 `Prefixes 0` 是预期。加 `export proto egp as 65001 metric 1 { … };` 后，
同一会话里 gated 通告 `172.16.0.0` 距离 1，egpd 装表链路全通（§5.2 的表与三层快照）。
注意 export 语句必须写在 `egp` 之后，否则 `gated -C` 会报 `statement out of order`。

**P1-1 gated 无法在内核 RIB 生效（`-n` 的代价）**
路由级"学到→装表→撤路→恢复"只能在 gated 自身 RIB 观察，不能在 gated 侧内核验证。
若要双侧内核都验证，需要修 gated 的接口路由安装路径（本次未做，且已按"连续三次失败先停"规则停止）。

**P1-2 主动/被动角色未覆盖**
本次 gated 以 `PassiveMode` 建立，egpd 侧 `Mode=active`。主动/被动互换、双主动、双被动
三种组合都没有跑过。

**P1-3 定时器协商未比对**
gated 通告 30/120，egpd 侧配置 2/6。Hello/Poll 的取值与协商过程只在抓包里看到，没有逐字段核对。

**P2-1 gated 侧 RIP 噪声**
默认 RIP 在实验网段持续发包，抓包与日志里混有 RIP，正式矩阵需 `rip no;` 关闭。

**P2-2 实验拓扑依赖 bridge**
gated 的 netlink 接口读取在 veth/lo 上表现为只登记 lo；本实验用 bridge 规避。这属于对端侧
历史缺陷，不影响协议结论，但复现时要照做。

## 7. 尚未验证（S-A 剩余）

- 撤路：显式 255 与连续遗漏老化在跨实现场景下的行为；撤路后的恢复。
- 反向安装：gated 学到 egpd 通告的 `10.0.0.0/8` 后是否进入其 RIB/选路（因 `-n` 只在其自身 RIB 可见）。
- Cease / GOINGDOWN 的对称性与邻居重启后的恢复。
- 主动/被动三种组合；定时器协商逐字段比对（gated 通告 30/120，egpd 侧 2/6）。
- 规范差异清单：目前只有第一条（Update 序列号，见 §6 P0-1），其余待整理。
- 抓包逐字段表已覆盖 Acquire/Reach/Poll/Update（§5、§5.2），Hello 与 Error 的 code/status 尚未单独整理。

## 8. 环境状态

netns `hr16a`/`hr16b`、veth、bridge 与 zebra/egpd/gated 进程由本任务创建，记录时仍在运行，
供下一轮继续（序列号比对）；清理方式是停止 gated/egpd/zebra 并删除这两个 netns。
宿主 systemd 的 FRR 全程 `active`，本项目 `historic-routing-*` unit 全程 `inactive`。

## 9. 复现步骤

```sh
# 1) 取独立实现并核对来源
curl -O https://bio.nic.funet.fi/pub/mirrors/ftp.gated.merit.edu/research.and.development/gated/gated-3-6.tar.gz
sha256sum gated-3-6.tar.gz    # 60beeb04349e7061d4f1398ef3dc888ef8934baaa8b7cdda61172d060ce42da5
tar xzf gated-3-6.tar.gz && cd gated-public-3_6
patch -p1 < /path/to/gated-3.6-port.patch

# 2) 构建
CFLAGS="-std=gnu89 -O2 -g -fcommon -D_GNU_SOURCE -DYYDEBUG=1 \
  -Wno-implicit-int -Wno-implicit-function-declaration -Wno-int-conversion \
  -Wno-incompatible-pointer-types -Wno-error" \
  sh ./configure --prefix="$PWD/../inst" --enable-egp --disable-smux
make depend && make -j1 CFLAGS="同上"
# parse.o/lexer.o 需以 -DYYDEBUG=1 重编后才能链接成功（yydebug）

# 3) 拓扑：两个 netns + veth；对端侧用 bridge 挂地址（gated 的 ifread 需要）
#    a: 198.18.161.1/24（zebra+egpd）  b: br16 198.18.161.2/24（gated）
# 4) 启动（gated 必须 -n；export 需 metric，否则通告距离 255）
gated -n -f gated.conf.export
```

配置样例见 [`gated.conf`](gated.conf)（仅邻居）与
[`gated.conf.export`](gated.conf.export)（含 export 策略，注意语句顺序）。
