# 架构

三层结构，边界必须清晰，否则以后加第二个协议就会变成第二个 mega-fork。

```
┌──────────────────────────────────────────────────────────────┐
│ protocols/<proto>/     协议自身：状态机、报文编解码、CLI、测试   │
│                        不依赖兄弟协议，不依赖本仓库其它目录      │
├──────────────────────────────────────────────────────────────┤
│ patches/frr/           让 FRR「认得」这条协议的最小改动          │
│                        lib / zebra / vtysh / 构建 四层各一个补丁 │
├──────────────────────────────────────────────────────────────┤
│ scripts/               编排：拉 FRR@BASELINE → 打补丁 → 复制源码  │
│                        → bootstrap/configure/make → 验证         │
│                        verify.sh = 统一验证入口（A/B/C 三段）    │
├──────────────────────────────────────────────────────────────┤
│ lab/<proto>/           实验环境：容器镜像、参数、端到端集成检查    │
└──────────────────────────────────────────────────────────────┘
```

## 为什么补丁里没有协议源码

协议源码由 `scripts/integrate-sources.sh`（S4 实现）在构建时复制进 FRR 树：

```
protocols/egp/src/*.c|h        →  $FRR/egpd/*.c|h
protocols/egp/build/egpd.subdir.am →  $FRR/egpd/subdir.am
protocols/egp/tests/test_packet.c  →  $FRR/egpd/test_packet.c
```

理由：

1. 加一个源文件不需要改补丁，补丁数量恒定（每个协议 4 个）。
2. 补丁只描述"FRR 原生文件怎么变"，`git apply` 冲突面最小。
3. 协议源码可以用 `sha256sum` 直接对照上游 fork，证明迁移没有改逻辑。

代价：复制前必须清空目标目录（`rm -rf $FRR/egpd`），否则删掉的文件会残留在树里造成假通过。

## FRR 集成点（EGP 的实例，后续协议照抄）

| 层 | 需要改什么 | 补丁 |
| --- | --- | --- |
| lib | 注册路由类型（`route_types.txt` + `rt_enabled`）、CLI 节点枚举 | 0001 |
| zebra | RIB 管理距离 + 内核协议号映射 | 0002 |
| vtysh | client 表项 + `VTYSH_*` 位 + 节点注册 | 0003 |
| build | `--enable-<proto>`、`include <proto>/subdir.am`、daemons 文件、DAEMONS 顺序、测试注册 | 0004 |
| 可选 | 让别的 daemon 能 `redistribute <proto>` | 0005 |

## 数据流（以 EGP 为例）

```
内核      ← zebra ← ZAPI ← egpd ← raw socket (IP proto 8) ← 对端 egpd
   ↑                                    ↓
   └──────────── 路由/下一跳由 zebra 解析，egpd 从不直接写内核 ────────┘
vtysh ── vty socket ── egpd / zebra
```

- 路由类型 `ZEBRA_ROUTE_EGP`（显示码 `G`，管理距离 140）是 egpd 与 zebra 之间的契约。
- 该常量随 `lib/route_types.txt` 生成，数值固定（EGP=32、ALL=33、MAX=34）。
  一旦上游改动插入位置，编号会漂移，历史 pcap 和日志里的类型编号就对不上——
  所以 `BASELINE` 必须钉死，`rebase` 必须单独做。

## 验证层（S6）

`scripts/verify.sh` 把"能不能重复构建、测试结果能不能信、实验安全不安全"变成一条命令，
并且**拒绝把人眼看到的失败说成通过**：

| 段 | 内容 | 状态取值 |
| --- | --- | --- |
| A 仓库完整性 | BASELINE 提交、补丁 SHA256、补丁顺序可应用、协议源码哈希、敏感信息扫描 | PASS / FAIL / SKIP |
| B 构建与产物 | 构建（指纹匹配则复用）、产物与 ldd、二进制 SHA、路由类型、单测、`make check-TESTS`、完整 `make check`、`make dist` | PASS / FAIL / SKIP / KNOWN-FAIL |
| C 实验 | podman/镜像、最小权限 A/B、`up`、重复 `up`、集成测试、异常中断后清理、清理校验、重复 `down` | PASS / FAIL / SKIP |

三条设计规则：

1. **KNOWN-FAIL 必须有逐条证据**。完整 `make check` 的失败不看目录，而是取每个测试自己的
   `E` 行；只有当异常文本指向被 `--disable` 模块的可执行文件时才认（`scripts/parse-make-check.py`），
   否则就是 FAIL。原始退出码始终保留。
2. **SKIP 必须写原因**，并且让退出码变成 3（"验证不完整"），避免"少跑一半却显示通过"。
3. **能复用就不重编**：指纹（基线 + 补丁 + 协议核心源码哈希）与当前仓库一致时直接复用产物，
   但仍要复核二进制 SHA 与指纹相符，防止拿错前缀。

## 硬约束

1. **同树编译**：egpd 与 zebra/libfrr/vtysh 必须来自同一次构建（ZAPI 枚举与结构体一致）。
   因此不支持"把 egpd 装进发行版 FRR"。
2. **不跟随 master**：只用 `patches/frr/BASELINE` 指定的提交。
3. **不重写协议逻辑**：迁移阶段要求源码逐字节不变；任何行为改动必须单独提交、单独验证。
4. **每协议独立**：协议之间不 import、不共享全局状态、不共用补丁文件。
5. **验证证据落盘**：每次完整验证都留下日志与指纹（`<build-root>/logs/`、`fingerprint.txt`、
   `docs/known-failures.md`、`docs/evidence/`），结论必须能追溯到某一次真实执行。

---

## 多协议（S7）

目标：**一份 FRR 构建**同时容纳 EGP、GGP、HELLO…，每个协议只是多一个 daemon
+ 一组登记资源；不是每个协议各编译一整套 FRR。

### 1. 一个协议 = 一份登记 + 一个目录 + 一组补丁

```
protocols/<name>/
├── PROTOCOL.meta          机器可读的资源登记（唯一登记处，脚本只读这里）
├── src/                   <daemon>.c / <proto>_packet.c/.h
├── build/<daemon>.subdir.am
├── tests/test_packet.c
└── README.md

patches/frr/<name>/
├── 0001-lib-<proto>-route-type.patch
├── 0002-zebra-<proto>.patch
├── 0003-vtysh-<proto>.patch
├── 0004-build-<proto>.patch
└── 0005-lib-redistribute-<proto>.patch   （可选，默认不应用）
```

`PROTOCOL.meta` 是**唯一登记处**：`DAEMON / CONFIGURE_ENABLE / CONDITIONAL /
HAVE_MACRO / ROUTE_TYPE / ROUTE_TYPE_NAME / DISPLAY_CHAR / DISTANCE /
VTYSH_SYMBOL / VTYSH_BIT / CLI_NODE / PATCH_DIR / SOURCES / EXTRAS / TEST_BINARY`。
脚本里不再硬编码任何协议常量（`scripts/lib.sh` 的 `hr_proto_load`）。

### 2. 不可再生资源的分配规则

| 资源 | 规则 | 谁强制 |
| --- | --- | --- |
| 路由类型编号 | `ZEBRA_ROUTE_<P>` = **32 + 登记顺序**（egp=32, ggp=33, hello=34…）；`ZEBRA_ROUTE_ALL` = 32+n；`ZEBRA_ROUTE_MAX` = ALL+1 | `build.sh` 从生成的 `route_types.h` 反查比对 |
| 路由类型名字串 | 小写、唯一，等于 `show ip route <name>` 的选择器名 | `check-allocations.sh` |
| 显示码 | 单个大写字母，且不在基线 `route_types.txt` 里已用 | `check-allocations.sh --frr` |
| 管理距离 | 1..255；历史协议建议 140 起按协议递增（140/141/142…） | 登记 + 补丁一致性检查 |
| vtysh 位 | **保留区间 `0x400000` .. `0x3FFFFFF`**，必须是 2 的幂，唯一；按登记顺序分配下一个空闲位（egp=`0x400000`，下一个 `0x800000`） | `check-allocations.sh` + 基线比对 |
| daemon 名 | 唯一；同时是源码目录、可执行文件名、`daemons` 文件里的条目 | `check-allocations.sh` |
| CLI 节点 | 唯一（`lib/command.h` 里插在 `NODE_TYPE_MAX` 之前） | `check-allocations.sh` |

**为什么编号必须按登记顺序**：`lib/route_types.txt` 的编号是**位置决定**的。EGP 的 32
已随 v0.1.0 发布（CLI、pcap、指纹里都是 32），所以新协议只能**追加**在它之后；
`verify` 会从 `route_types.h` 反查每个协议的编号并与登记顺序比对，乱了就 FAIL。

### 3. 十二个集成点，以及谁和谁会撞

| # | FRR 文件 | 每个协议加什么 | 冲突性质 |
| --- | --- | --- | --- |
| 1 | `lib/route_types.txt` | 一行类型 + 一段描述 | **编号按插入位置**，锚点都是 `ZEBRA_ROUTE_ALL` 之前 → 按登记顺序应用才稳定 |
| 2 | `lib/command.h` | 一个 `*_NODE` 枚举 | 同一锚点（`NODE_TYPE_MAX` 前），顺序无关 |
| 3 | `lib/subdir.am` | `if <COND>` + `rt_enabled += --enabled <daemon>` | 追加块，顺序无关 |
| 4 | `zebra/rt_netlink.c` | 一个 `case ZEBRA_ROUTE_<P>` | 同一 `switch` 首条，文本易冲突 |
| 5 | `zebra/zebra_rib.c` | 一行距离表项 | 数组按类型索引，追加即可 |
| 6 | `vtysh/vtysh.c` | client 表一行 + 节点 + `install_node` | 三处固定锚点 |
| 7 | `vtysh/vtysh.h` | `#define VTYSH_<P>` + `VTYSH_ALL` 掩码 | **掩码是同一行**，多协议必然文本冲突 → 追加在行尾 |
| 8 | `configure.ac` | `AC_ARG_ENABLE` + `AC_DEFINE` + `AM_CONDITIONAL` | 追加块 |
| 9 | `Makefile.am` | `include <daemon>/subdir.am` | 追加行（`TESTS =` 只需一次，已在 EGP 补丁里放好） |
| 10 | `tests/subdir.am` | `if <COND>` + `check_PROGRAMS +=` + `TESTS +=` | 追加块 |
| 11 | `tools/etc/frr/daemons` | `<daemon>=no` | 追加行 |
| 12 | `tools/frrcommon.sh.in` | 把 daemon 加进 `DAEMONS="..."` | **单行字符串**，多协议必然文本冲突 → 追加在行尾 |

其中 4 处（1、4、7、12）是"同锚点/同行"的热点：新协议补丁必须以**前一个协议应用后的
状态**为基线生成，应用顺序 = 登记顺序。`scripts/check-allocations.sh` 会把多协议
共享的文件列出来（`[INFO] 多协议共享的集成点`），提醒审查者注意这几处。

### 4. 构建：一次编译，多协议开关

```sh
./scripts/build.sh --protocols egp                       # 现状（v0.1.0 行为不变）
./scripts/build.sh --protocols egp,ggp                   # 同一棵 FRR，两个 daemon
./scripts/verify.sh --all --protocols egp                # 验证同样接受协议列表
```

流程（与 S4 相同，只是把"egp"换成列表）：

1. `fetch-frr.sh` 取固定基线；
2. `apply-patches.sh` 按 **登记顺序** 逐个协议应用 `0001-0004`（可选 `0005`），
   每个协议应用后立刻做"登记 ↔ 补丁"一致性断言；
3. `integrate-sources.sh` 把每个协议的源码复制到 `$FRR/<daemon>/`（清空后复制 + SHA256 对照）；
4. `configure --enable-<a> --enable-<b> …`，一次 `make` 出 `zebra`、`vtysh`、
   每个协议的 daemon 和单元测试；
5. 逐协议断言 `HAVE_<P>`、`<COND>_TRUE`、测试注册、路由类型编号；
6. 安装到同一前缀，指纹里逐协议记录 id/显示码/距离/vtysh 位/二进制 SHA256。

多协议的运行时形态：**zebra 只有一个**（所有协议经 ZAPI 向它下发路由），
vtysh 也只有一个（用位图区分后端），每个协议各是一个独立 daemon 进程。
所以"共享 libfrr/zebra/vtysh 的版本一致性"是硬约束：所有协议包必须与同一份
`historic-routing-runtime` 绑定（见 `docs/PACKAGING.md`）。

### 5. 冲突检查（自动化）

`scripts/check-allocations.sh`（`verify.sh` 的 A6 调用它）：

1. 每个 `PROTOCOL.meta` 完整合法；
2. 12 类资源跨协议唯一（daemon / configure / 条件 / 宏 / 路由类型符号与名字 /
   显示码 / vtysh 符号与位 / CLI 节点 / 补丁目录 / 测试目标）；
3. vtysh 位是 2 的幂、落在保留区间；
4. 补丁内容与登记一致（改了补丁忘改登记、或反之，都会被抓到）；
5. 源码/automake/测试文件齐全；
6. 给了 `--frr` 时与固定基线比对：显示码、路由类型符号、vtysh 位有没有被上游占用。

### 6. 升级 FRR 基线时必须重新检查的项

1. `ZEBRA_ROUTE_EGP` 是否还是 32（`route_types.h`），`ALL/MAX` 是否仍为 32+n / ALL+1；
2. `vtysh.h` 里上游是否新占了 `0x400000` 起的保留区间（本项目会 FAIL 并指出具体位）；
3. `EGP_NODE` 所在枚举是否仍插在 `NODE_TYPE_MAX` 之前；
4. `zebra_rib.c` 的距离表是否仍是按类型索引的数组（结构变化会导致补丁上下文失效）；
5. `tests/subdir.am` 的 `TESTS` 语义是否仍是"可 `+=`"；
6. 上面 12 个文件的补丁是否仍能按登记顺序 `git apply`（`verify.sh` A4 会真打一遍）。

这 6 项全部由 `verify.sh --all` 覆盖（A2/A4/A6 + B4），不需要人肉记忆。
