# FRR 适配补丁

补丁只描述 **FRR 原生文件的改动**，不包含任何协议源码。协议源码由
`scripts/integrate-sources.sh` 在构建时复制进 FRR 树。

## 目录：每个协议一组

```
patches/frr/
├── BASELINE     钉死的 FRR 提交
├── SHA256SUMS   所有补丁的哈希基线（verify.sh 的 A2 检查读它）
├── egp/         0001..0005（EGP）
└── <下一个协议>/ 0001..0005
```

**应用顺序 = `protocols/<name>/PROTOCOL.meta` 的登记顺序**，不是字母序：
`lib/route_types.txt` 的路由类型编号由插入位置决定，EGP 已经是 32（v0.1.0 已发布），
新协议必须排在它之后（见 `docs/ARCHITECTURE.md`「多协议」）。
下面这一节的清单与冲突点，对每个协议各自成立；跨协议的资源冲突由
`scripts/check-allocations.sh` 检查。

- 基线：见同目录 `BASELINE`（`FRR_COMMIT=27f287be9…`）
- 全部补丁由 `git format-patch` 生成，用 `git apply` 应用；**顺序固定**（文件名已编号）
- 已在干净基线上按 0001→0005 顺序实测全部应用成功，结果与已验证树
  `3ab0ca7470` 逐文件一致，唯一差异是 `tests/subdir.am` 里刻意的
  `TESTS =` → `TESTS +=` 修正（见下）

## 清单

| 补丁 | 层 | 触及文件 | 是否必需 |
| --- | --- | --- | --- |
| `0001-lib-add-egp-route-type.patch` | lib | `lib/route_types.txt`、`lib/subdir.am`、`lib/command.h` | **必需** |
| `0002-zebra-install-egp-routes-with-distance-140.patch` | zebra | `zebra/zebra_rib.c`、`zebra/rt_netlink.c` | **必需** |
| `0003-vtysh-add-egpd-client-and-node.patch` | vtysh | `vtysh/vtysh.c`、`vtysh/vtysh.h` | **必需** |
| `0004-build-enable-egpd-and-keep-existing-tests.patch` | build | `configure.ac`、`Makefile.am`、`tests/subdir.am`、`tools/etc/frr/daemons`、`tools/frrcommon.sh.in` | **必需** |
| `0005-lib-allow-redistribute-egp-optional.patch` | lib（可选能力） | `lib/log.c` | 可选，默认不启用 |

### 依赖关系

- `0002`、`0003` 在语义上依赖 `0001`（需要 `ZEBRA_ROUTE_EGP` / `EGP_NODE` 枚举）。
- `0004` 提供 `EGPD` 条件，`0001` 里的 `if EGPD` 只有配上它才有意义。
- 文本层面五个补丁互不重叠，所以单独也能 `git apply --check` 通过；
  **但只有当 0001–0004 全部应用后，代码才是可编译的**（S4 验证）。

### 0004 里的关键修正

原 fork 的 `tests/subdir.am` 写的是：

```
if EGPD
check_PROGRAMS += egpd/test_packet
TESTS = egpd/test_packet        ← 覆盖式赋值
endif
```

autotools 的 `TESTS` 是累加语义，而 `Makefile.am` 里 `include pceplib/test/subdir.am`
（第 221 行）在 `include tests/subdir.am`（第 225 行）之前，所以这个 `=`
会把 pceplib 的测试列表覆盖掉，启用 egpd 后 `make check` 静默只剩一个测试。

**但只把 `=` 改成 `+=` 是不行的**——S4 首次真实 `bootstrap` 就报错：

```
tests/subdir.am:84: error: cannot apply '+=' because 'TESTS' is not defined in
the following conditions: EGPD and !PATHD_PCEP / EGPD and !PATHD_PCEP_TEST
```

automake 要求 `+=` 所在的条件上下文里必须已经有同名的定义，而 `TESTS` 只在
`pceplib` 的条件块里被定义过。所以本补丁做两件事：

1. `Makefile.am`：在 `include egpd/subdir.am` 之前加一条**无条件**的 `TESTS =`，
   位置在 `include pceplib/subdir.am` 之前，这样 pceplib 的赋值不会被它覆盖；
2. `tests/subdir.am`：`if EGPD` 里用 `TESTS += egpd/test_packet`（在 pceplib
   赋值之后，因此不会丢测试）。

修改后的 make 展开顺序（pceplib 启用时）：

```
Makefile.am:211-ish   TESTS =                               （空）
pceplib/subdir.am:9   TESTS = $(check_SCRIPTS)              （pcep 测试）
tests/subdir.am:84    TESTS += egpd/test_packet             （追加，两者都在）
```

只有 egpd、不启 pceplib 时结果就是 `TESTS=egpd/test_packet`。
用 GNU make 复刻真实 include 顺序的对照结果：

```
旧写法（fork 原样）  TESTS = egpd/test_packet    →  TESTS=egpd/test_packet
                                                      （pcep 测试被覆盖，消失）
新写法（本补丁）     见上面三步               →  TESTS=pcep_msg_tests pcep_pcc_api_tests egpd/test_packet
```

## 已知冲突点（rebase 到新基线时先看这里）

| 位置 | 风险 | 处理 |
| --- | --- | --- |
| `lib/route_types.txt` 的 `ZEBRA_ROUTE_TABLE_DIRECT` 之后 | 上游若在此插入新类型，EGP 编号会从 32 漂移，`ROUTE_ALL`/`ROUTE_MAX` 跟着变 | 重新确认编号并更新 `docs/FIDELITY.md`；历史 pcap/日志里的编号将不再对应 |
| `lib/command.h` 的 `PIM6_NODE` 之后 | 新增 CLI 节点 | 位置可调整，只需在 `NODE_TYPE_MAX` 之前 |
| `vtysh/vtysh.h` 的 `VTYSH_MGMTD 0x200000` 之后（`0x400000`） | **位值是全局稀缺资源**，上游新增 daemon 会抢用 | rebase 时必须检查位图，冲突时改用空闲位 |
| `tools/frrcommon.sh.in` 的 `DAEMONS` 串 | 顺序被 topotests 镜像 | 插在 `sharpd` 与 `pbrd` 之间；改顺序要同步确认 topotests |
| `tests/subdir.am` + `Makefile.am` 的 `TESTS =` | automake 要求 `+=` 所在条件里已有同名定义，且空定义必须在 pceplib 赋值之前 | 空定义与 `+=` 必须成对出现；位置顺序不能调换 |
| `configure.ac` | 三个 hunk 分布在不同段（AC_ARG_ENABLE 列表、HAVE_* 段、AM_CONDITIONAL 段） | 按字母序靠近 `sharpd` 相关行，减少漂移 |

## 应用方法

```sh
cd <frr-source-at-BASELINE>
for p in /path/to/repo/patches/frr/<proto>/000[1-4]-*.patch; do
  git apply --check "$p" && git apply "$p" || { echo "失败: $p"; exit 1; }
done
```

多协议时按登记顺序逐协议应用（`hr_patch_list` 就是这么实现的）。

**不要**用 `git am` 直接串起来（补丁带 `From` 头，`git am` 会尝试创建提交，需要干净的
提交身份与基线分支）；构建脚本用 `git apply`。
