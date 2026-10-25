# v0.1.1 发布候选清单（S8-C，未发布）

生成时间: 2026-10-25
状态: **候选（release candidate）。未打 tag、未创建 Release、未上传任何仓库、未签名。**

## 1. 唯一冻结的源码提交

| 项 | 值 |
| --- | --- |
| historic-routing 提交 | `cb8336c0bfe991928e53697e07905ab2345838da`（短 `cb8336c`） |
| FRR 基线 | `27f287be9210d4024a140486b7b8ddd5eb41fe04`（`10.9.0-dev`，tree `514d1289…`） |
| ABI 标识 | `cb8336c-27f287be9`（DEB 侧因版本号须以数字开头写作 `0.cb8336c-27f287be9`，原始值在包内 `BUILD-INFO.txt: abi_raw`） |
| 版本号 | `0.1.1`（**未发布**；RPM `0.1.1-0.1.devcb8336c.el10`，DEB `0.1.1~devcb8336c-1`） |

RPM 与 DEB **都由这一个提交构建**，不是各自取历史提交。

## 2. 发布源码包（受校验的构建输入）

| 项 | 值 |
| --- | --- |
| 文件 | `historic-routing-cb8336c0bf-src.tar.xz` |
| 大小 | 14,684,624 B |
| SHA256 | `4499d1331613e2eab495110c864524f9bd731abaf7469a4e23830a84ff67b055` |
| 内含 | 源码树 100 个文件（逐文件 `git hash-object` 与索引一致，含可执行位）+ `vendor/frr-27f287be9.git.tar.xz`（离线 FRR 镜像，SHA256 `c63a99151bac02c272c9b657223ad85c3b2733cbb0390f837fd8a1f812ffb795`）+ `vendor/VENDOR.txt` + `vendor/SHA256SUMS` + `SOURCE-COMMIT` |
| 生成 | `scripts/release-source.sh --frr-mirror /root/frr-mirror.git`（产出后自动解包回读校验） |

**离线构建已实测**：DEB 在 `podman run --network none`（容器无任何网络）里从这份源码包构建成功，
`FRR_REPO_EFFECTIVE=mirror:frr-27f287be9.git.tar.xz`、`FRR_MIRROR_SHA256=c63a9915…`。
网络下载不再是构建前提。

## 3. 候选产物（4 个）

| 包 | 文件 | 大小 | SHA256 |
| --- | --- | --- | --- |
| RPM runtime | `historic-routing-runtime-0.1.1-0.1.devcb8336c.el10.x86_64.rpm` | 1,796,467 B | `dca495ae0495a7ddaa165197e077e6a55c16bebf06345cd34527ce35b6df0cad` |
| RPM egp | `historic-routing-egp-0.1.1-0.1.devcb8336c.el10.x86_64.rpm` | 23,118 B | `7c5e144d91985bb0c48308b79234f831f71fc564a5daed47f470b9e6fb186351` |
| DEB runtime | `historic-routing-runtime_0.1.1~devcb8336c-1_amd64.deb` | 2,237,280 B | `a6ab2c02f2cbb97dbf8cc53826aab63b16d8df1dbe9b46648f91cc07969f90ac` |
| DEB egp | `historic-routing-egp_0.1.1~devcb8336c-1_amd64.deb` | 20,752 B | `40cce2e9b9779c14bb0520800478230ef846b55166f7fb8a479d836f653e3857` |

**仅用于升级/降级测试、不作为产物**：`…-1.0.devcb8336c.el10`（RPM）、`…~devcb8336c-2`（DEB）。

## 4. 编译环境

| | RPM | DEB |
| --- | --- | --- |
| 系统 | RHEL 10.1 x86_64 | Debian 13.7 amd64（podman 容器用户态） |
| 内核 | `6.12.0-124.8.1.el10_1` | 同上（**容器与宿主共内核，不是 Debian 自带内核**） |
| 编译器 | gcc 14.4.1 (Red Hat) | gcc 14.2.0 (Debian) |
| 打包工具 | rpm 4.19.1.1 / rpmlint 2.8.0 | dpkg 1.22.22 / debhelper 13.24.2 / lintian 2.122.0 |
| 构建入口 | `%build` → `scripts/build.sh` | `debian/rules` → `scripts/build.sh`（同一脚本） |
| FRR 输入 | `--frr-repo file:///root/frr-mirror.git` | `vendor/frr-27f287be9.git.tar.xz`（`--network none` 下构建） |

## 5. 测试结果（全部真实执行）

| 项 | 结果 | 证据 |
| --- | --- | --- |
| RPM 构建 + rpmlint | 构建成功；rpmlint **0 errors / 0 warnings** | `s8c-20261025-rpm-rpmlint.log` |
| RPM 安装/启动/升级/降级/卸载 | **34/34 PASS**，`ALL_PASS` | `s8c-20261025-rpm-install-test.log` |
| RPM 卸载残留 | 前缀目录完全删除；无 `.pid/.vty/zserv.api`；`/run/historic-routing` 无残留 | 同上 §10 |
| RPM systemd | 安装后 `disabled/inactive`；`RuntimeDirectory=/run/historic-routing/frr` 生效；`vtysh` 无参数可连，`show daemons` = `zebra egpd` | 同上 §4–§7 |
| RPM EGP 双路由 | **13/13**（邻居 Up、`G>* [140/1]`、内核 `proto zebra`、双向 UDP、撤/宣告、SIGKILL 撤路、重启恢复、zebra 重启重下发、删邻居撤路、收尾） | 见报告 §5 |
| DEB 构建（离线） | `--network none` 下成功；lintian **0 errors / 2 warnings**（changelog 行宽） | `s8c-20261025-deb-offline-build.log` |
| DEB 安装/运行/升级/降级/卸载 | 各步 `rc=0`；`dpkg -V` 无差异；只装 egp 被依赖拒绝（`apt rc=100`） | `s8c-20261025-deb-install-test.log` |
| DEB 与发行版 frr 共存 | 文件交集仅 9 个公共父目录（`/`、`/usr`…），无真实文件冲突；`dpkg -V frr` 无差异 | 同上 §7、§14 |
| DEB EGP 双路由 | **13/13** | 见报告 §6 |
| 跨包指纹一致性 | **33 项输入型字段完全相同**（源码提交、FRR 基线、4 个补丁 SHA256、8 个协议源码 SHA256、资源登记、`MAKE_RESULT`/`EGPD_TEST_PACKET`/`MAKE_CHECK_RC`） | `s8c-20261025-crosscheck.log` |

差异（已解释、非缺陷）：`abi` 前缀 `0.`；三个二进制的 SHA256 不同（编译器/glibc/加固参数不同，
跨发行版不可逐字节一致）；`MAKE_CHECK_SUMMARY` 耗时不同；镜像"传输表示"不同（`file://` vs `mirror:`）。

## 6. 验证限制（不声称的范围）

1. **DEB 只验证了 Debian 13.7 的用户态容器**（systemd 257 在容器里跑），宿主内核是 RHEL 10.1 的
   `6.12.0-…el10_1`。**没有在独立 Debian 机器、也没有在 Debian 自带内核上测过。**
2. 只覆盖 `amd64`；未验证 arm64、Debian 12/testing、RHEL 9/CentOS 9。
3. 容器里跑 zebra 需要 `NET_ADMIN`/`NET_RAW`/`SYS_ADMIN`（与 S5 结论一致；真实主机 root 具备）。
4. `make check` 的 14 项已知失败保持原样（全部落在编译期已 `--disable` 的 isisd/pimd）。
5. 未签名、未上传、未打 tag、未创建 Release；`v0.1.0` 未改动。
6. 升级测试用的是同一提交的更高 release/revision；跨源码提交的升级未测。
7. `vendor/`（14 MB）不进 git，随发布源码包分发。
8. 包内 `doc/` 里的文档是构建提交 `cb8336c` 的版本；本清单与 S8-C 报告是构建之后补写的。

## 7. 相关文档

- 统一规范：`docs/PACKAGING.md` §12（RPM/DEB 目录、运行目录、库路径、服务、conffile、ABI、构建输入）
- RPM 详情：`packaging/rpm/README.md`；DEB 详情：`packaging/debian/README.md`
- 已知失败：`docs/known-failures.md`；实验安全：`docs/LAB_SAFETY.md`
