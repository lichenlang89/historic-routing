# 打包设计（RPM / DEB）— 尚未实现，仅设计

> 状态：**设计稿**。S7 只做架构准备，不产出任何包；真正打包是下一阶段的事。
> 目标是先把**包划分与版本约束**定下来，避免以后各协议各带一份 FRR。

## 1. 为什么要分公共运行时与协议包

所有协议共享**同一份** `libfrr`、`zebra`、`vtysh`：

- 路由类型编号、ZAPI 结构体、vtysh 位图都是**编译期**常量；
- 混用不同构建的 `libfrr` 与 daemon 会在 ZAPI 解码时出错，甚至静默丢路由；
- vtysh 只有一个，它按位图找后端；位图冲突 = 命令发错 daemon。

所以包必须把"框架"和"协议"分开，并且**版本强制一致**。

## 2. 包划分

| 包 | 内容 | 说明 |
| --- | --- | --- |
| `historic-routing-runtime` | `libfrr.so.*`、`zebra`、`vtysh`、`staticd`、`mgmtd`、`vtysh.conf`/`daemons` 骨架、共享 `frrcommon.sh` | **唯一**的框架包；所有协议包依赖它 |
| `historic-routing-egp` | `egpd`、`egpd` 的 systemd unit、`protocols/egp` 文档 | 依赖 runtime，版本严格相等 |
| `historic-routing-ggp`（未来） | `ggpd` | 同上 |
| `historic-routing-hello`（未来） | `hellod` | 同上 |
| `historic-routing-lab`（可选） | `lab/` 脚本 + Containerfile | 只给测试机，不进生产 |
| `historic-routing-devel`（可选） | 头文件、`pkg-config`、补丁源码 | 给二次开发者 |

命名沿用发行版习惯：RPM 用 `historic-routing-<part>`，DEB 用 `historic-routing-<part>`（无 `lib` 前缀，因为这不是系统库）。

## 3. 版本与依赖约束

```
# RPM
historic-routing-runtime = %{version}-%{release}
Requires: historic-routing-runtime = %{version}-%{release}

# DEB
Depends: historic-routing-runtime (= ${binary:Version})
```

再加一层**文件级**约束，防止"版本号相同但构建不同"：

- 协议包对 `libfrr.so.0` 的 SONAME 依赖由 `ldd` 自动生成（`Requires: libfrr.so.0()(64bit)` 之类的自动依赖即可）；
- **不要**给 `libfrr` 打 `Provides: frr-libfrr` 之类的别名，避免和发行版 FRR 混装；
- runtime 包显式 `Conflicts: frr, frr-libs`（或 `Conflicts: frr` + `Breaks/Replaces` 视发行版规范），
  因为两套 `zebra` 抢同一批 netlink 端口和 `/var/run/frr`。

版本号策略：`v0.1.0` 这种项目版本 + 内部 `%{release}`；**框架与协议包共用同一个版本号**，
因为它们必须同一次构建产出（同树编译约束）。

## 4. 安装路径

两种取向，建议 **B**：

| 方案 | 路径 | 优点 | 缺点 |
| --- | --- | --- | --- |
| A 系统路径 | `/usr/sbin/zebra`、`/usr/lib64/libfrr.so` | 与其他包一致 | 必然与发行版 FRR 冲突；升级风险转移到全系统 |
| **B 独立前缀** | `/opt/historic-routing/<frr-commit>/...`（`sbin/`、`bin/`、`lib/`、`etc/`） | 与系统 FRR 完全隔离（本项目一直如此：`--prefix` 全在包内） | 需要 `ld.so.conf.d` 或 `rpath` 让 daemon 找到 `libfrr`；systemd unit 要写绝对路径 |

B 的具体做法（与仓库里 `build.sh` 的 `--prefix` 一致）：

```
/opt/historic-routing/<FRR_COMMIT>/sbin/{zebra,staticd,egpd}
/opt/historic-routing/<FRR_COMMIT>/bin/vtysh
/opt/historic-routing/<FRR_COMMIT>/lib/libfrr.so.0*
/opt/historic-routing/<FRR_COMMIT>/etc/frr/{daemons,frr.conf}
```

`libfrr` 的查找：不写 `ld.so.conf.d`（那会影响全系统），而是给 daemon 加
`RPATH=$ORIGIN/../lib` 或由 unit 文件设置 `LD_LIBRARY_PATH`。后者更简单，但要求
unit 不带 `Environment` 被覆盖。

## 5. 包内的服务与配置

| 项 | 归属 | 说明 |
| --- | --- | --- |
| `zebra.service` | runtime | 所有协议共用，**只能有一个实例** |
| `historic-routing-egpd.service`（或 `egpd.service`） | 协议包 | `Requires=zebra.service`、`After=zebra.service` |
| `/etc/.../daemons` | runtime 提供骨架，协议包用 `%config(noreplace)` 追加 `egpd=yes` | 追加而不是覆盖，否则多协议装在一起会互相清掉 |
| `/etc/.../frr.conf` | 用户维护，`%config(noreplace)` | 协议包**不**写配置，只在文档里给示例 |
| SELinux/AppArmor | runtime | 协议包不带策略；若需要 `frr_t` 域，统一在 runtime 里放（未验证） |
| systemd 的 `watchfrr` | runtime（可选） | 本项目目前不依赖它，daemon 崩溃恢复靠自己（见 FIDELITY 的"未实现"） |

## 6. 卸载与共存

- 卸载协议包 → 只删自己的 daemon + unit，**不要**删 `/etc` 里的配置和 `daemons` 里的其它行；
- 卸载 runtime → 所有协议包必须一起走（`Requires` 反向保证：协议包依赖 runtime，
  卸 runtime 时包管理器会先要求卸协议包）；
- 与发行版 FRR 共存：不允许（`Conflicts: frr`），因为两者都要当"控制面"。

## 7. 构建流水线（将来）

```
make dist → 拿到含 egpd/ 的 tarball（已实现）
  ↓
rpmbuild / dpkg-buildpackage：改 --prefix 为 /opt/historic-routing/<commit>
  ↓
拆包：runtime 取 sbin/{zebra,staticd}、bin/vtysh、lib/libfrr*、etc 骨架
      协议包取 sbin/<daemon> + unit + 文档
  ↓
每个包记录 fingerprint.txt 的一行（提交、补丁、源码哈希、二进制 SHA256）
```

## 8. 待解决的问题

1. **`ld.so` 方案未定型**：`RPATH=$ORIGIN/../lib` 需要在 configure 里加 `-Wl,-rpath`，
   当前 `build.sh` 没有；临时用 `LD_LIBRARY_PATH`。
2. **systemd unit 未验证**：`frrinit`/`watchfrr` 路径与参数没在包场景下跑过（S6 的"未实现"项）。
3. **多协议 `daemons` 文件的合并**：`%config(noreplace)` 的追加语义在 RPM 里需要
   `%post` 脚本，DEB 里需要 `ucf`/`dpkg-maintscript-helper`，两种实现都要测。
4. **SELinux 策略**：`frr_t` 域下 zebra 需要的能力与容器实验不同，未验证。
5. 包签名与仓库托管：未规划（不属于 S7）。
