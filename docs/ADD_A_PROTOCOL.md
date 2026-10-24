# 加一个新历史协议（操作手册）

> 状态：**可用**。EGP 走完了 S0–S6 全流程（冻结 → 拆补丁 → 迁源码 → 构建 → 容器实验 → 统一验证），
> S7 把"多协议共用一套 FRR"的资源分配与冲突检查自动化了。
> **GGP / HELLO 目前仍然没有代码**，本文是写给"下一个协议"的操作步骤，不是它们的实现计划。

## 0. 先看这条硬约束

所有协议共用**同一棵 FRR、同一个 zebra、同一个 vtysh、同一份 libfrr**。
每个协议只增加：一个 daemon 进程、一个路由类型、一个 vtysh 位、一组补丁。

因此新协议**不能**自己再编译一套 FRR，也**不能**与别的协议抢资源。

## 1. 登记（先做，否则什么都跑不起来）

```sh
cp protocols/egp/PROTOCOL.meta protocols/<新协议>/PROTOCOL.meta
```

逐项填写，规则见 `docs/ARCHITECTURE.md`「多协议」：

| 键 | 填法 | 例子（EGP） |
| --- | --- | --- |
| `NAME` | 必须等于目录名 | `egp` |
| `DAEMON` | daemon 名 = 源码目录 = 可执行文件名 | `egpd` |
| `CONFIGURE_ENABLE` | `--enable-<这个>` | `egpd` |
| `CONDITIONAL` | automake 条件名（大写） | `EGPD` |
| `HAVE_MACRO` | configure 生成的宏 | `HAVE_EGPD` |
| `ROUTE_TYPE` | `ZEBRA_ROUTE_<大写>` | `ZEBRA_ROUTE_EGP` |
| `ROUTE_TYPE_NAME` | 小写，`show ip route <name>` 用它 | `egp` |
| `DISPLAY_CHAR` | 单个大写字母，未被占用 | `G` |
| `DISTANCE` | 1..255；历史协议从 140 起递增 | `140` |
| `VTYSH_SYMBOL` / `VTYSH_BIT` | `VTYSH_<大写>` + 保留区间内 2 的幂 | `VTYSH_EGPD` / `0x400000` |
| `CLI_NODE` | `lib/command.h` 里的枚举名 | `EGP_NODE` |
| `PATCH_DIR` | `patches/frr/<协议>` | `patches/frr/egp` |
| `SOURCES` | `src/` 下的源文件名（空格分隔） | `egpd.c egp_packet.c egp_packet.h` |
| `EXTRAS` | 仅用于满足 EXTRA_DIST 的文件 | `README.md lab.sh test_lab.py` |
| `TEST_BINARY` | `make check-TESTS` 里必须 PASS 的目标 | `egpd/test_packet` |

选资源之前先跑一次 `scripts/check-allocations.sh`，看已经占了哪些：

```
[INFO] 已登记协议: egp
```

**下一步可用的编号**：路由类型 33（EGP 是 32）、显示码任选未被占用的字母、
vtysh 位 `0x800000`。这些不是"预留"，而是**登记顺序推出来的**：登记了就会按顺序分配。

## 2. 写协议本体

```
protocols/<name>/
├── src/<daemon>.c            协议主体（状态机、CLI、ZAPI 交互）
├── src/<proto>_packet.c/.h   报文编解码
├── build/<daemon>.subdir.am  automake 片段（构建时复制为 $FRR/<daemon>/subdir.am）
├── tests/test_packet.c       不依赖容器的单元测试（金样本/边界/非对齐）
├── README.md                 使用者视角
└── PROTOCOL.meta             第 1 步的登记
```

要求：

- 只依赖 libfrr，不引用其它 `protocols/*` 目录；
- 路由一律经 ZAPI 交给 zebra，**不要**自己写内核；
- 单元测试打印 `N tests passed`（`build.sh` 与 `verify.sh` 都检查这一行）。

## 3. 拆补丁（每协议 4 个 + 1 个可选）

```
patches/frr/<name>/
├── 0001-lib-<proto>-route-type.patch     route_types.txt / command.h / subdir.am
├── 0002-zebra-<proto>.patch              rt_netlink.c / zebra_rib.c
├── 0003-vtysh-<proto>.patch              vtysh.c / vtysh.h
├── 0004-build-<proto>.patch              configure.ac / Makefile.am / tests/subdir.am / daemons / frrcommon.sh.in
└── 0005-lib-redistribute-<proto>.patch   可选：让别的 daemon 能 redistribute
```

锚点规则（这几处必须与登记顺序一致，冲突检查会盯着）：

1. `lib/route_types.txt`：插在 `ZEBRA_ROUTE_ALL` **之前**，新协议追加在已有历史协议之后；
2. `lib/command.h`：插在 `NODE_TYPE_MAX` 之前；
3. `vtysh/vtysh.h`：`#define VTYSH_<P> <bit>` 加在历史协议块末尾，`VTYSH_ALL` 掩码**追加在行尾**；
4. `tools/frrcommon.sh.in`：daemon 名追加到 `DAEMONS="..."` 行尾；
5. `Makefile.am`：`TESTS =` 只写一次（EGP 的 0004 已经放了），新协议只加 `include <daemon>/subdir.am`；
6. `tests/subdir.am`：用 `TESTS +=`，不要用 `=`（会覆盖上游 pceplib 的测试）。

补丁里**不要**包含协议源码（源码由 `integrate-sources.sh` 复制）。

## 4. 实验环境

```
lab/<name>/
├── Containerfile      可以复用 lab/egp/ 的（镜像与协议无关）
├── lab.env.example    自己的网段/容器名/端口，不要与 egp 撞
├── lab.sh
└── test_lab.py
```

要求：只创建自己的容器/网络；`down` 幂等；`up` 冲突即拒绝；
集成测试逐项断言真实状态（RIB JSON、内核路由、数据面），不要只看日志里有 PASS。

## 5. 验证（三条命令，缺一不可）

```sh
scripts/check-allocations.sh                 # 资源分配与补丁一致性
scripts/build.sh --protocols egp,<name>      # 一次构建两个协议（真实编译）
scripts/verify.sh --all --protocols egp,<name>
```

通过标准（与 EGP 的 S6 相同）：

- `check-allocations.sh`：0 冲突；
- 构建：每个协议 `HAVE_*`、`<COND>_TRUE`、测试注册、路由类型编号全部对上；
- `verify.sh`：无 FAIL；完整 `make check` 的失败必须逐条有证据（`docs/known-failures.md`）；
- 实验：该协议的集成测试全过；EGP 的 13 项**不能回归**。

## 6. 文档

- `docs/FIDELITY.md`：加一节，写清"已支持 / 简化 / 未实现"，以及它的资源占用；
- 本文件：不需要改，除非流程本身变了；
- `CHANGELOG.md`：Unreleased 里记一条；
- `docs/ARCHITECTURE.md`：只有在"新增了一种集成点"时才需要改（现在的 12 个点已覆盖 EGP 的全部需求）。

## 反例（不要做）

- 不要在 `protocols/<a>/` 里引用 `protocols/<b>/` 的文件；
- 不要把源码塞进补丁里"图方便"；
- 不要改 EGP 的既有文件来实现新协议；
- 不要为了省一个补丁把四个层次混在一起：层次混了，rebase 冲突就无法定位；
- 不要在 `PROTOCOL.meta` 里填别人的资源"先占位"——`check-allocations.sh` 会直接报冲突。
