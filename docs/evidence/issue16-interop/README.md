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
| gated 通告路由（带路由的 Update） | 部分：已发出 25 字节 Update，egpd 未接受 |
| 路由安装 / 撤路 / 老化 / Cease / 主动被动 / 定时器协商 | **未验证**（见 §7） |

一句话：**邻居层与报文层互通成立；路由层未打通**，当前卡在 Update 序列号语义差异（§6 P0-1）。

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
    按该地址合成接口条目（诊断用兜底；最终配置未依赖它）。

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

线缆：22 帧双向，tcpdump 自带 EGP 解析器可逐字段解码
（[`interop-neighbors-up.decode.txt`](interop-neighbors-up.decode.txt)、
[`interop-neighbors-up.pcap`](interop-neighbors-up.pcap)）：

```
EGPv2, length 16 poll state:up net:198.18.161.0                          # 双向都有
EGPv2, length 21 update unsolicited state:up 198.18.161.0 int 1 ext 0 int 1.1.1.0
```

即 Acquire → Confirm 后两侧进入 Up，Poll/Update 双向流动，AS 与状态字段与配置一致。

随后加上 export 策略，gated 的 RIB 里出现 `ADD 172.16 255.255 gw 172.16.16.1 Kernel ...
stub0`，并发出了一次 **25 字节** EGP 报文（带路由的 Update），但 egpd 侧仍是 `Prefixes 0`、
没有 `G>` 路由、内核无 172.16 表项（[`gated-export-and-seq.txt`](gated-export-and-seq.txt)）。

## 6. 当前问题清单（按严重度）

**P0-1 Update 序列号语义不一致（阻塞路由层）**
gated 报 `egp_event_update: neighbor 198.18.161.1 AS 65001: Sequence 1 expected 2`。
两侧对"Update 的 S 何时推进"理解不同：可能是 egpd 未按 gated 期望递增，也可能是 gated
沿用了旧行为。需要按 RFC 904 §4.x 与两侧实现逐报文比对后判定归属，不能直接改 egpd 迁就 gated。

**P0-2 egpd 未安装 gated 通告的路由**
即便 gated 发出 25 字节 Update，egpd `Prefixes` 仍为 0。除 P0-1 外还需确认 egpd 的接收路径
是否因 AS/网关分类把该 Update 判为无效（gated 通告的网关是它自己 172.16.16.1/198.18.161.2）。

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

- 路由内容与双向安装；255 撤路；连续遗漏老化；撤路后恢复。
- Cease / GOINGDOWN 的对称性与邻居重启后的恢复。
- 主动/被动三种组合；定时器协商逐字段比对。
- 规范差异清单（RFC 904/888 vs 本实现 vs gated 行为）。
- 抓包层面逐字段比对（Acquire/Hello/Poll 的 code/status、距离分块、网关列表）尚未整理成表。

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
# 4) 启动（gated 必须 -n）
gated -n -f gated.conf
```

配置样例见 [`gated.conf`](gated.conf)（仅邻居）与
[`gated.conf.export`](gated.conf.export)（含 export 策略，注意语句顺序）。
