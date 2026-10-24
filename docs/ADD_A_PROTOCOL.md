# 加一个新协议（模板手册）

> 状态：**可用**。本文描述的流程已经用 EGP 完整走通（S0–S6：冻结、拆补丁、迁源码、
> 构建、容器实验、统一验证）；S7 会用一个空壳协议再实跑一遍以确认"照抄即可"。
> 目前还没有第二个协议的代码，**不要**在没有登记资源的情况下直接开工。

## 一个协议 = 1 个目录 + 4 个补丁（+ 可选能力补丁）

```
protocols/<proto>/
├── README.md                使用者视角：怎么配、怎么验
├── PROTOCOL.md              规范摘要、状态机、报文格式、忠实度（对应 docs/FIDELITY.md 的条目）
├── src/
│   ├── <proto>d.c           daemon 主体
│   ├── <proto>_packet.c     编解码
│   └── <proto>_packet.h
├── build/
│   └── <proto>d.subdir.am   automake 片段（构建时复制为 $FRR/<proto>d/subdir.am）
└── tests/
    └── test_packet.c        单元测试（不依赖 lab）

patches/frr/
├── 0001-lib-<proto>-route-type.patch      lib/route_types.txt + lib/subdir.am + lib/command.h
├── 0002-zebra-<proto>.patch               zebra/zebra_rib.c + zebra/rt_netlink.c
├── 0003-vtysh-<proto>.patch               vtysh/vtysh.c + vtysh/vtysh.h
├── 0004-build-<proto>.patch               configure.ac + Makefile.am + tests/subdir.am
│                                          + tools/etc/frr/daemons + tools/frrcommon.sh.in
└── 0005-lib-redistribute-<proto>.patch    （可选，默认不启用）
```

## 步骤

1. **先登记资源**：在 `docs/FIDELITY.md` 占用路由类型编号、显示码、`VTYSH_*` 位。
   这三样是不可再生资源，冲突代价很高。
2. **写协议源码**，放进 `protocols/<proto>/src/`；只依赖 libfrr，不依赖其它协议目录。
3. **写 automake 片段** `build/<proto>d.subdir.am`，路径前缀用 `<proto>d/`（对应复制后的 FRR 目录名）。
4. **按四层拆补丁**，顺序固定 `0001 → 0002/0003 → 0004`；`0002`、`0003` 依赖 `0001` 的枚举，
   不要求它们单独在原始基线上可编译。
5. **注册测试**：`0004` 里的 `tests/subdir.am` 必须用 `TESTS +=`（不要用 `=`，会覆盖其它测试）。
6. **lab**：新建 `lab/<proto>/`，复用 `lab/egp/` 的 Containerfile 与地址规划习惯，换地址段。
7. **验证**：
   - 构建：`./scripts/build.sh --jobs N --prefix DIR`（源码目录由 `integrate-sources.sh` 按
     `protocols/*/` 自动收集，新增协议不需要改 build.sh）。
   - 统一验证：`./scripts/verify.sh --all --build-root DIR`。新协议必须在 `verify.sh` 里
     至少增加：该协议的单元测试（B 段）、该协议的容器实验（C 段）、以及
     `protocols/<proto>/evidence/SOURCES.sha256`（A 段）。
   - 要求多协议可同时启停、互不影响；EGP 的 13 项集成测试必须仍然全绿。

## 新协议的最小验收清单

| 项 | 要求 |
| --- | --- |
| 资源登记 | `docs/FIDELITY.md` 里登记路由类型编号、显示码、管理距离、vtysh 位 |
| 源码不动 | 从已验证实现迁移时逐字节比对（`sha256sum` + `git hash-object`），证据进 `evidence/` |
| 补丁 | 0001–0004 顺序可应用；`git apply --check` 通过；不含整份协议源码 |
| 构建 | `--enable-<proto>` 生效、`HAVE_<PROTO>` 生成、`make check-TESTS` 含该协议测试 |
| 单测 | 编解码金样本/边界/非对齐；有独立可执行文件 |
| 实验 | 独立 `lab/<proto>/`，自己的容器/网络/参数，`down` 后无残留 |
| 验证 | `verify.sh --all` 通过（允许 KNOWN-FAIL，但必须有逐条证据） |
| 文档 | `protocols/<proto>/README.md` 写清用法，`docs/FIDELITY.md` 写清简化与未实现 |

## 反例（不要做）

- 不要在 `protocols/<a>/` 里引用 `protocols/<b>/` 的文件。
- 不要把源码塞进补丁里"图方便"。
- 不要改 EGP 的既有文件来实现新协议。
- 不要为了省一个补丁把四个层次混在一起：层次混了，rebase 冲突就无法定位。
