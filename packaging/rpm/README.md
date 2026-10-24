# RPM 打包（RHEL 10.1 x86_64）

> 状态：**开发验证构建**。`Version: 0.1.1`、`Release: 0.1.dev<源码短提交>`，
> 文件名里带 `dev` 与提交号，Summary 明确写 "development build, NOT released"。
> 这不是 v0.1.0 的发布包，也不会被当成正式版本。

## 1. 两个包，以及为什么必须绑在一起

| 包 | 内容 | 依赖 |
| --- | --- | --- |
| `historic-routing-runtime` | `libfrr.so*`、`zebra`、`vtysh`、`etc/frr/{daemons,frr.conf}` 骨架、zebra unit | `Provides: historic-routing-abi = <源码短提交>-<FRR短提交>` |
| `historic-routing-egp` | `egpd`、`etc/frr/egpd.conf` 示例、egpd unit | `Requires: historic-routing-runtime(x86-64) = %{version}-%{release}` 且 `Requires: historic-routing-abi = <同一个 ABI>` |

**为什么这样切**：`libfrr`/`zebra`/`vtysh` 是所有协议共享的框架；每个协议只是多一个 daemon。
协议 daemon 与 `libfrr`/`zebra` 之间是编译期约定（ZAPI 枚举、路由类型编号、vtysh 位图），
混用不同构建会解码错误甚至静默丢路由。所以协议包**同时**要求：

1. runtime 的 `version-release` 完全相等（`=` 而不是 `>=`）；
2. 同一个 `historic-routing-abi` 标识（`源码提交短SHA-FRR提交短SHA`）。

只靠 SONAME（`libfrr.so.0`）不够：两个不同构建的 `libfrr.so.0` SONAME 相同、ABI 却可能不同，
所以额外用 `historic-routing-abi` 显式绑定。升级任一包都会因为 version-release 不相等而失败，
必须成对升级。

## 2. 安装布局（与系统 FRR 完全隔离）

```
/opt/historic-routing/27f287be9/          ← 本次 FRR 基线短提交
├── bin/vtysh
├── sbin/{zebra,egpd}
├── lib/libfrr.so.0*                      ← 只给本前缀的服务用
├── etc/frr/{daemons,frr.conf,egpd.conf}  ← %config(noreplace)
├── run/                                  ← pid/socket 目录（本前缀内）
└── RPM-BUILD-INFO.txt                    ← 版本/源码提交/FRR 提交/ABI/指纹
/usr/lib/systemd/system/historic-routing-{zebra,egpd}.service
/usr/share/doc/historic-routing-*/        ← README/CHANGELOG/ARCHITECTURE/FIDELITY/PACKAGING
```

系统 FRR 的路径（`/usr/sbin/*`、`/usr/lib64/frr/libfrr.so.0`、`/etc/frr`、`/run/frr`、
`/var/lib/frr`）**一个都不碰**。

## 3. 动态库：$ORIGIN 相对 RUNPATH，不靠系统搜索路径

`%install` 用 `patchelf --set-rpath '$ORIGIN/../lib'` 把三个可执行文件和模块 `.so`
的 RUNPATH 改成相对路径（模块在 `lib/frr/modules/`，用 `$ORIGIN/../..`）：

- `sbin/zebra`、`sbin/egpd`、`bin/vtysh` 运行期只会在**自己所在前缀**的 `lib/` 里找
  `libfrr.so.0`；系统 `libfrr` 在 `/usr/lib64/frr/`，不在搜索路径上，**不可能被误加载**；
- `lib/frr/modules/*.so`（bgpd_bmp、dplane_fpm_nl、zebra_cumulus_mlag）**不打包**：它们与
  本项目的 zebra/egpd 无关，且会把 `libfrrcares.so.0` 这类系统 frr 的 soname 拖进依赖；
- 没有 `/opt/...` 这种"非标准绝对 rpath"，`rpm` 的 `check-rpaths` 与 `rpmlint` 都干净
  （绝对 `/opt` rpath 会被判 ERROR 0002；本机 rpm 4.19 的 `check-rpaths-worker`
  实测**不再读** `QA_RPATHS`，所以不是靠豁免，而是根本不产生问题 rpath）；
- 前缀被整体搬到别处（实验容器把前缀只读挂到 `/build/prefix`）也能用，不依赖绝对路径；
- `LD_LIBRARY_PATH` 的优先级仍高于 RUNPATH，实验脚本需要时可覆盖。

`rpm -qR` 里因此没有 `libfrr.so.0()` 之类的自动依赖（它不是系统库），见第 7 节。

## 4. 与系统 FRR 的冲突检查（先验证，再决定约束）

S8 要求"不要未经验证就声明 `Conflicts: frr`"。实测结论：

| 维度 | 检查方法 | 结果 |
| --- | --- | --- |
| 文件级 | `rpm -ql historic-routing-runtime historic-routing-egp` 与 `rpm -ql frr` 求交集 | 真实文件无交集；只有 `/usr/lib/.build-id/*`（build-id 目录/链接，按内容哈希命名，多个包共存是正常现象） |
| 库级（soname 命名空间） | `rpm -qp --provides` + `rpm -q --whatprovides 'libfrr.so.0()(64bit)'` | **第一版有真实冲突**：本包自带的 `libfrr.so.0` 被 rpm 自动 `Provides`，于是 `whatprovides libfrr.so.0()` 同时列出 `frr` 与 `historic-routing-runtime`，dnf 认为两者可互换；同时打包了 `lib/frr/modules/*.so`，把 `Requires: libfrrcares.so.0()(64bit)` 也带进来（只能由系统 `frr` 满足）。已修正：`%global __provides_exclude_from ^%{hr_prefix}/lib/.*\.so.*$` + `__requires_exclude ^libfrr\.so\.0.*$`，并且不打 `lib/frr/modules/`。修正后实测：`whatprovides libfrr.so.0()` 只返回 `frr`，本包 `rpm -qR` 里没有任何 `libfrr*` |
| 库级（运行期解析） | `ldd` + `readelf -d` | 本包二进制按 `RUNPATH=$ORIGIN/../lib` 解析到自己前缀的 `libfrr.so.0`，与 `/usr/lib64/frr/` 无关 |
| 服务级 | `systemctl list-unit-files` | 系统是 `frr.service`，本包是 `historic-routing-{zebra,egpd}.service`；unit 名不同、不 enable、不 mask |
| 运行时控制面 | 两套 `zebra` 都会写内核 RIB | **这是唯一真实冲突**，但它是"运维约束"而非包冲突：同时运行两个 zebra 会互相覆盖路由。README 与 `%description` 明确要求二选一，**不**声明 `Conflicts: frr`（声明了会挡住"只装不用"的合法场景，也用 RPM 的表达能力表达了错误的东西） |

结论：**不加 `Conflicts:`**，改为文档约束 + 运行期不互相干扰（不同 socket/配置/前缀）。

## 5. 服务与权限

| 项 | 设计 |
| --- | --- |
| unit 名 | `historic-routing-zebra.service`、`historic-routing-egpd.service` |
| 是否启用 | **不 enable、不 start**（`%post` 只 `daemon-reload`） |
| 启动方式 | `systemctl start historic-routing-zebra`（手动）；egpd unit `Wants=` zebra |
| 运行用户 | root（configure 用 `--enable-user=root`；本包不创建 `frr` 用户，避免与系统 FRR 争用 `/etc/frr` 属主） |
| 权限 | 二进制 0755、配置 0644（`%config(noreplace)`）、`/opt/.../run` 0755 root:root |
| 网络能力 | zebra 需要 CAP_NET_ADMIN/CAP_NET_RAW（root 直接具备）；未使用 `AmbientCapabilities`，因为还要 `CAP_SYS_ADMIN`（见 `docs/LAB_SAFETY.md` 的 A/B 证据） |
| SELinux | 未做策略；RHEL 10 默认 Enforcing 下 root 运行 `/opt` 下的未标注二进制会被 `init_t` 约束——**本轮未验证**（见"未验证平台"） |

## 6. 构建

```sh
./scripts/package-rpm.sh                     # 默认 0.1.1-0.1.dev<sha7>
./scripts/package-rpm.sh --version 0.1.1 --release 0.1.dev2262b0e --topdir /root/hr-s8-rpm
```

流程：

1. `git archive` 出 `historic-routing-<version>.tar.gz`（源码快照，含 SPEC 与 unit 源文件）；
2. `rpmbuild -bb`：**`%build` 里真的调用 `scripts/build.sh`**——从固定 FRR 基线
   `27f287be9210d4024a140486b7b8ddd5eb41fe04` 拉源码、打补丁、集成协议源码、configure、
   make、单测、`make check-TESTS`、`make dist`、安装到 `%{_builddir}/hr-build/prefix`；
3. `%install` 从该构建根**挑选**要装的文件（不是把目录整体压包），改写 RUNPATH，并写入
   `RPM-BUILD-INFO.txt`（版本/提交/ABI/完整 fingerprint）；
4. 脚本对生成的 RPM 跑 `rpm -qpR`、`rpm -qpl`、`sha256sum`、`rpmlint`。

**可复现性**：同一提交 + 同一 FRR 基线 → 同一 `%build` 输入（SPEC 在 `%build` 里会断言
`patches/frr/BASELINE` 与打包参数一致，不一致直接失败）。`%build` 需要网络（从 GitHub 取
固定提交），这是当前唯一的外部依赖，已在报告里注明。

### LTO 说明

rpmbuild 会注入 `%{optflags}`（含 `-flto=auto -ffat-lto-objects`）。FRR 的 `libfrr` 在
glibc 2.39+ 与 `FORTIFY_SOURCE=3` 下用 LTO 会报
`inlining failed in call to 'always_inline' 'inet_ntop'`（LTO 与 fortify 的已知冲突）。
SPEC 在 `%build` 里把 `-flto*` 从 `CFLAGS/CXXFLAGS/LDFLAGS` 中去掉，其余加固参数保留。
这不是"为了过编译而放宽测试"——`make check-TESTS`、单元测试、集成测试照常执行。

## 7. 安装后的验收命令

```sh
rpm -q historic-routing-runtime historic-routing-egp
rpm -V  historic-routing-runtime historic-routing-egp

# 库解析（RUNPATH 必须是 $ORIGIN/../lib；实际解析到 /opt 前缀，不得出现 /usr/lib64/frr）
readelf -d /opt/historic-routing/27f287be9/sbin/zebra | grep -E 'RUNPATH|RPATH'
ldd /opt/historic-routing/27f287be9/sbin/zebra | grep frr

# 能跑（不设置 LD_LIBRARY_PATH）
/opt/historic-routing/27f287be9/sbin/zebra --version
/opt/historic-routing/27f287be9/bin/vtysh --version
/opt/historic-routing/27f287be9/sbin/egpd --version

# 服务只装不启
systemctl is-enabled historic-routing-zebra.service historic-routing-egpd.service   # → disabled
systemctl is-active  historic-routing-zebra.service                                  # → inactive

# 系统 FRR 未被改动
rpm -V frr frr-selinux
systemctl is-active frr    # → 保持原状（inactive）

# 端到端：用安装后的前缀跑双路由器 EGP 实验
cd lab/egp && LAB_PREFIX=/opt/historic-routing/27f287be9 ./lab.sh up && ./lab.sh test && ./lab.sh down
```

## 8. 卸载

`rpm -e historic-routing-egp historic-routing-runtime`：

- 只删本包自己的文件（`/opt/historic-routing/27f287be9/...`、两个 unit、`/usr/share/doc/...`）；
- 修改过的配置文件按 `%config(noreplace)` 保留为 `.rpmsave`（或原样保留，视修改情况）；
- `%preun` 只 `stop` 自己的 unit，不碰 `frr.service`；
- 不会删 `/opt/historic-routing` 目录本身（`%dir` 只占 `%{prefix}`，父目录留给其它版本）。

## 9. 已知限制

1. 只在 RHEL 10.1 x86_64 验证；未验证其它发行版、aarch64、SELinux Enforcing 下的服务启动。
2. `%build` 需要访问 GitHub 取固定 FRR 提交（离线构建需要预先准备镜像，尚未实现）。
3. 只打 `runtime` + `egp`；`devel`（头文件）、`lab`、`staticd`/其它 daemon 未打包。
4. 未生成 SRPM 发布物（`rpmbuild -bs` 可用，但本轮不产出）。
5. 二进制经 `brp-strip` 处理，与 `RPM-BUILD-INFO.txt` 里 fingerprint 记录的
   **构建期** SHA256 不同（指纹记录的是 install 后、strip 前；功能不受影响）。
