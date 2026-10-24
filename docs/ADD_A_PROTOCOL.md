# 加一个新协议（模板手册）

> 状态：**骨架**。本文档在 S7 用一个空壳协议（GGP）实跑验证后补全；
> 现在写的是"已验证的 EGP 形状"，照抄可以，但其中的脚本引用要到 S4 才存在。

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
7. **验证**：`scripts/build.sh --protocols egp,<proto>` + `scripts/verify.sh`（S4 实现），
   要求两条协议可同时启停、互不影响。

## 反例（不要做）

- 不要在 `protocols/<a>/` 里引用 `protocols/<b>/` 的文件。
- 不要把源码塞进补丁里"图方便"。
- 不要改 EGP 的既有文件来实现新协议。
- 不要为了省一个补丁把四个层次混在一起：层次混了，rebase 冲突就无法定位。
