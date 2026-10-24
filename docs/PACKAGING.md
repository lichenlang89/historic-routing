# 打包设计（RPM / DEB）

> 状态：**RPM 已实现并实测**（S8-A，RHEL 10.1 x86_64）；DEB 仍未实现。
> 实现细节与验收命令见 `packaging/rpm/README.md`。
> 本文件保留"为什么这样划分"的设计推理，并把 S8-A 实测推翻的两条原始假设标注出来
> （见 §3、§6 的"已证伪"段落）。

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

再加一层**构建指纹**，防止"版本号相同但构建不同"（S8-A 实际采用）：

- `Provides: historic-routing-abi = <源码短提交>-<FRR短提交>`，协议包 `Requires` 同一个值；
- 再加 `Requires: historic-routing-runtime = %{version}-%{release}`（精确相等）。

### 已证伪（S8-A 实测）

1. **"协议包对 libfrr.so.0 的 SONAME 依赖由自动依赖生成即可" —— 错。**
   rpm 会把**本包自带**的 `libfrr.so.0` 也写成 `Provides`，于是
   `rpm -q --whatprovides 'libfrr.so.0()(64bit)'` 同时列出系统 `frr` 与本项目 runtime，
   两者在 dnf 眼里变成"可互换"；同时二进制自带的 `Requires: libfrr.so.0()` 会被
   **系统 frr 满足**，等于"依赖系统 FRR 才能装"。正确做法：
   `%global __provides_exclude_from ^<prefix>/lib/.*\.so.*$` 与
   `%global __requires_exclude ^libfrr\.so\.0.*$`，私有库不进系统 soname 命名空间。
2. **"runtime 显式 `Conflicts: frr`" —— 未成立，也不需要。**
   实测文件级无交集（除 `/usr/lib/.build-id`），库级靠 `RUNPATH=$ORIGIN/../lib` 完全隔离，
   unit 名不同且都不 enable；唯一的真实冲突是**运行期控制面**（两套 zebra 都写内核 RIB），
   这是运维约束，用 `Conflicts:` 表达反而会挡住"只装不用"的合法场景。因此最终**不加** `Conflicts:`，
   改为 README/`%description` 明确"不要同时运行"。

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

`libfrr` 的查找（S8-A 实际做法）：**不写 `ld.so.conf.d`**（`libfrr.so.0` 会和系统 frr 抢
ldconfig 缓存），而是在打包时用 `patchelf --set-rpath '$ORIGIN/../lib'` 给
`zebra`/`vtysh`/`egpd` 写成**相对** RUNPATH。好处：

- 绝对 `/opt` rpath 会被 rpm 的 `check-rpaths` 判 ERROR 0002（本机 rpm 4.19 的
  `check-rpaths-worker` 已不读 `QA_RPATHS`，豁免无效），`$ORIGIN` 不触发；
- 前缀整体搬走（实验容器只读挂到 `/build/prefix`）也能用；
- `LD_LIBRARY_PATH` 仍可覆盖，实验脚本需要时照用。

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
- 与发行版 FRR 共存：**允许安装并存，禁止同时运行**（S8-A 结论）。包级不声明
  `Conflicts:`；两套 `zebra` 各自写内核 RIB，同时跑会互相覆盖路由，属于运维约束。
- 卸载实测：`%preun` 只 `stop` 自己的 unit；RPM 删除自己拥有的文件与目录；
  `<prefix>/var/lib/frr`、`<prefix>/run/frr` 里由 daemon 产生的运行期状态（socket/pid）
  不会被删（RPM 不删非空目录），重装会复用——这是刻意选择：宁愿留状态也不做 `rm -rf`。

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
