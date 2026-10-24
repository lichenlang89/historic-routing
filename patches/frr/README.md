# FRR 适配补丁

补丁只描述 **FRR 原生文件的改动**，不包含任何 EGP 源码。协议源码由
`scripts/integrate-sources.sh`（S4 实现）在构建时复制进 FRR 树。

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

已在本补丁中改为 `TESTS += egpd/test_packet`，并用 GNU make 复刻真实 include
顺序做了对照（`pceplib/test/subdir.am` 第 9 行是 `TESTS = $(check_SCRIPTS)`）：

```
旧写法  TESTS = egpd/test_packet        →  TESTS=egpd/test_packet                （pcep 测试消失）
新写法  TESTS += egpd/test_packet       →  TESTS=pcep_msg_tests pcep_pcc_api_tests egpd/test_packet
```

完整的 `make check` 端到端验证属于 S4（需要在真实 FRR 树上 bootstrap/configure）。

## 已知冲突点（rebase 到新基线时先看这里）

| 位置 | 风险 | 处理 |
| --- | --- | --- |
| `lib/route_types.txt` 的 `ZEBRA_ROUTE_TABLE_DIRECT` 之后 | 上游若在此插入新类型，EGP 编号会从 32 漂移，`ROUTE_ALL`/`ROUTE_MAX` 跟着变 | 重新确认编号并更新 `docs/FIDELITY.md`；历史 pcap/日志里的编号将不再对应 |
| `lib/command.h` 的 `PIM6_NODE` 之后 | 新增 CLI 节点 | 位置可调整，只需在 `NODE_TYPE_MAX` 之前 |
| `vtysh/vtysh.h` 的 `VTYSH_MGMTD 0x200000` 之后（`0x400000`） | **位值是全局稀缺资源**，上游新增 daemon 会抢用 | rebase 时必须检查位图，冲突时改用空闲位 |
| `tools/frrcommon.sh.in` 的 `DAEMONS` 串 | 顺序被 topotests 镜像 | 插在 `sharpd` 与 `pbrd` 之间；改顺序要同步确认 topotests |
| `tests/subdir.am` | 已有的 `TESTS` 使用者（如 `pceplib/test/subdir.am`） | 永远用 `+=` |
| `configure.ac` | 三个 hunk 分布在不同段（AC_ARG_ENABLE 列表、HAVE_* 段、AM_CONDITIONAL 段） | 按字母序靠近 `sharpd` 相关行，减少漂移 |

## 应用方法

```sh
cd <frr-source-at-BASELINE>
for p in patches/frr/00*.patch; do
  git apply --check "$p" && git apply "$p" || { echo "失败: $p"; exit 1; }
done
```

**不要**用 `git am` 直接串起来（补丁带 `From` 头，`git am` 会尝试创建提交，需要干净的
提交身份与基线分支）；构建脚本用 `git apply`。
