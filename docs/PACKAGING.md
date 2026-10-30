# 打包设计（RPM / DEB）

> 状态：RPM 与 DEB 均已实现；既有发行验证见根 README。
> Issue #14 修正独立 egpd unit 的 reload 路径，当前验证边界见 [交接记录](plan/issue-14-handoff.md)。
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

## 7. 构建流水线（设计稿；RPM 已在 S8-A、DEB 已在 S8-B 实现，见 §9）

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

## 8. 当时待解决的问题（现状：1–3 已由 S8-A/S8-B 解决，4–5 仍未做）

1. ~~**`ld.so` 方案未定型**~~ → 已定：打包时用 `patchelf` 写 `RUNPATH=$ORIGIN/../lib`
   （RPM 与 DEB 都这么做），不写 `ld.so.conf.d`。
2. ~~**systemd unit 未验证**~~ → 已在 RPM（RHEL 10.1）与 DEB（Debian 13）上真实起停验证，
   包括 `vtysh -c 'show daemons'` 同时看到 zebra/egpd。
3. ~~**多协议 `daemons` 文件的合并**~~ → 目前只用 systemd unit（不读 `daemons` 文件），
   多协议合并问题暂时不存在；等真的要在一个包里装多个协议时再处理。
4. **SELinux 策略**：`frr_t` 域下 zebra 需要的能力与容器实验不同，未验证。
5. 包签名与仓库托管：未规划（不属于 S7）。

## 9. DEB 实现状态（S8-B，已在 Debian 13 实测）

`packaging/debian/` + `scripts/package-deb.sh`，两个包 `historic-routing-runtime` /
`historic-routing-egp`，版本 `0.1.1~dev<源码短提交>-<revision>`，装到
`/opt/historic-routing/<FRR 短提交>/`。与 RPM 的差异见 `packaging/debian/README.md` §5。

实现过程中被实测推翻/修正的三处（都记在 README 里）：`-ffile-prefix-map` 破坏 FRR 的
vtysh 命令生成、`dh_installsystemd` 在该环境收不到 unit（改为显式安装）、ABI 标识必须以
数字开头（`0.<sha>-<frr>`）。

## 10. 可复用设计①：socket / PID 放到 /run（systemd RuntimeDirectory）

**问题**：RPM（S8-A）把 pid/socket 放在 `<prefix>/run/`，属于"包内目录 + 运行期写入"，
卸载后必然残留（RPM 不删非空目录）。

**设计（已在 DEB 实测通过）**：

1. configure 时 `--runstatedir=/run/historic-routing`（FRR 会在其下再建 `frr/` 子目录，
   并把 `vtysh` 的默认 socket 目录也定到那里）；
2. unit 里：
   ```ini
   RuntimeDirectory=historic-routing/frr
   RuntimeDirectoryMode=0755
   ExecStart=<prefix>/sbin/zebra -f <prefix>/etc/frr/frr.conf              -i /run/historic-routing/frr/zebra.pid              -z /run/historic-routing/frr/zserv.api              --vty_socket /run/historic-routing/frr -u root -g root
   ```
3. 结果（S8-B 实测）：
   - 安装前缀里**没有** `run/` 目录；
   - 服务运行时 `/run/historic-routing/frr/` 里有 `zebra.pid`、`zebra.vty`、`zserv.api`；
   - `systemctl stop` 后 systemd 删掉 `.../frr`（顶层 `/run/historic-routing` 会保留到重启）；
   - `vtysh` 不带参数即可连上（编译期 runstatedir 与 unit 一致）；
   - `dpkg -P` 之后前缀整个消失，没有 socket/pid 残留。

**RPM 侧怎么改（本轮不动，等验证）**：把 `BuildRequires` 不变，`%build` 里给
`scripts/build.sh` 加 `--configure-args "--runstatedir=/run/historic-routing"`，两个 unit 改成
上面的 `RuntimeDirectory=` 形式，`%files` 去掉 `%dir %{prefix}/run{,/frr}`，`%post` 不需要
mkdir。注意 `%dir %{prefix}/var/lib/frr` 仍保留（FRR 的 state 目录）。

## 11. 可复用设计②：自包含的构建源码输入（离线可构建）

**问题**：`%build` / `override_dh_auto_build` 都要从 GitHub 取固定 FRR 提交，正式打包不该依赖
构建时联网；而且"能联网"不是可复现性。

**设计（已实现并验证）**：

```
./scripts/vendor-frr.sh --from /root/frr-mirror.git --out vendor
  → vendor/frr-27f287be9.git.tar.xz   （含固定提交的 bare git 仓库）
  → vendor/VENDOR.txt                 （FRR_COMMIT / TREE / DESCRIBE / REPO_DIRNAME）
  → vendor/SHA256SUMS
./scripts/vendor-frr.sh --verify vendor/frr-27f287be9.git.tar.xz
  → PASS 校验通过: commit=27f287be… tree=514d1289…
```

构建时：

```sh
HR_FRR_MIRROR_TARBALL=vendor/frr-27f287be9.git.tar.xz ./scripts/package-deb.sh ...
```

`fetch-frr.sh` 的流程是：先 `sha256sum -c SHA256SUMS`，再解包到 `<build-root>/frr-mirror`，
把它当作 `origin` 克隆，最后仍然用 `patches/frr/BASELINE` 的 40 位 `FRR_COMMIT` 强制校验
（`apply-patches.sh` 还会再验一次 HEAD 与工作树干净）。所以**镜像只是传输方式**，内容由
commit + 补丁 SHA256 决定；指纹里 `FRR_REPO_EFFECTIVE` 会写实际来源。

本次 S8-B 的 DEB 就是用这个离线镜像从零构建的（S8-A 的 RPM 阶段用的是同一个仓库的
`file://` 路径）。

**仍然缺的一环**：`vendor/` 目录默认不进 git（体积 14 MB）。正式发布时应把
`vendor/frr-<short>.git.tar.xz` + `SHA256SUMS` + `VENDOR.txt` 一起放进发布源码包
（`dpkg-buildpackage -S` 的 orig tar / RPM 的 SRPM），这样别人拿到源码包即可离线构建。

## 12. RPM / DEB 统一规范（S8-C 之后的唯一标准）

两条打包链现在共用同一套约定；不一致就视为缺陷。

| 维度 | 规范 | RPM 实现 | DEB 实现 |
| --- | --- | --- | --- |
| 安装前缀 | `/opt/historic-routing/<FRR 短提交>/` | `%{hr_prefix}` | `@PREFIX@` |
| 运行目录 | `/run/historic-routing/frr`，systemd `RuntimeDirectory` 管 | unit 里 `RuntimeDirectory=` + `--runstatedir=` | 同 |
| 安装前缀里的 `run/` | **不存在** | `%files` 已删 `%dir %{prefix}/run` | 从来不建 |
| 动态库 | 二进制 `RUNPATH=$ORIGIN/../lib`，不写 `ld.so.conf.d` | `patchelf --set-rpath` | 同 |
| 服务名 | `historic-routing-zebra.service`、`historic-routing-egpd.service` | 同 | 同 |
| 默认不启动 | 只安装，不 enable、不 start | `%post` 只 `daemon-reload`（rpm 宏不做 enable） | `dh_installsystemd --no-start --no-enable` |
| 配置文件 | conffile 语义（保留用户修改） | `%config(noreplace)` | `*.conffiles` + `dpkg-maintscript-helper` 无需 |
| 版本绑定 | egp 精确依赖 runtime 的**同一**版本 + ABI 标识 | `Requires: = %{version}-%{release}` + `historic-routing-abi = <sha>-<frr>` | `(= ${binary:Version})` + `Provides/Depends: historic-routing-abi = 0.<sha>-<frr>` |
| 构建入口 | 同一个 `scripts/build.sh` | `%build` | `override_dh_auto_build` |
| 构建输入 | 固定 FRR 提交 + 补丁 SHA256 + 协议源码 SHA256 | `--frr-repo` / `HR_FRR_REPO` | `HR_FRR_MIRROR_TARBALL` |
| 卸载残留 | 运行期文件一律不落在前缀内 | 无 `run/`，`/run/...` 由 systemd 回收 | 同 |

`historic-routing-abi` 的取值两端相同：`<源码短提交>-<FRR 短提交>`（DEB 侧因为版本号必须
以数字开头，写成 `0.<源码短提交>-<FRR 短提交>`，原始值记录在包内 `BUILD-INFO.txt` / `RPM-BUILD-INFO.txt`）。

### 12.1 发布源码包的受校验构建输入

`scripts/release-source.sh --frr-mirror <bare 仓库> [--out dist]` 产出：

```
dist/historic-routing-<10 位短提交>-src.tar.xz
dist/MANIFEST.txt
```

包内含：该提交的完整源码树（逐文件 `git hash-object` 与索引比对，含可执行位）、
`vendor/frr-<short>.git.tar.xz`、`vendor/VENDOR.txt`、`vendor/SHA256SUMS`、`SOURCE-COMMIT`。
生成后脚本会解开成品，`sha256sum -c vendor/SHA256SUMS` 再验一遍——**网络下载不再是构建前提**。

从发布源码包构建（没有 `.git`）：

```sh
tar xJf historic-routing-<short>-src.tar.xz && cd historic-routing-<short>
./scripts/package-deb.sh --git-sha <完整提交> \
    --work /tmp/build  # 加 HR_FRR_MIRROR_TARBALL=... 或直接用包内 vendor/
./scripts/package-rpm.sh --git-sha <完整提交> --frr-repo file:///path/to/unpacked/mirror
```
