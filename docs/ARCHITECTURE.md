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
