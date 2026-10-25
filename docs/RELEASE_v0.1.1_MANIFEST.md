# v0.1.1 正式包清单（发布前最终检查，S8-D）

状态：**已构建并验证完毕，等待批准发布。未推送、未打 tag、未创建 Release。**

## 1. 发布提交与 Tag 指向方案（唯一）

| 项 | 值 |
| --- | --- |
| **发布源码提交（Tag 指向它）** | `81c494688b8ae5335a3613cf5b7748c8ddf8a60f`（短 `81c4946`） |
| 源码 tree | `1bc515e85ddfcf910c9821ca8e50a4811a21f410` |
| FRR 基线 | `27f287be9210d4024a140486b7b8ddd5eb41fe04`（10.9.0-dev，tree `514d1289…`） |
| Tag | `v0.1.1`（annotated，**指向上面这个提交**） |

**规则**（避免"Release 源码"与"安装包来源"不一致）：

1. `v0.1.1` 指向 `81c4946`，四个安装包与发布源码包**全部由该提交构建**（包内 `RPM-BUILD-INFO.txt` /
   `BUILD-INFO.txt` 与源码包 `SOURCE-COMMIT` 都写着它）；
2. 本文件、`SHA256SUMS`、证据日志是**构建之后**才可能有的内容，因此它们在 tag 之后追加的提交里
   （`docs/releases/v0.1.1/`），**不属于 tag 源码**，不参与构建；
3. Tag 的注解（annotated tag message）里写入 `SHA256SUMS` 全文，这样"tag → 五个产物的哈希"是自证的，
   不需要额外查找；
4. Release（若批准）只上传这 5 个文件 + `SHA256SUMS`，不重新打包、不重命名。

## 2. 五个发布文件（4 个安装包 + 1 个源码包）

| 文件 | 大小 | SHA256 |
| --- | --- | --- |
| `historic-routing-runtime-0.1.1-1.el10.x86_64.rpm` | 1,796,797 B | `04bf30acb65415eb87bfb7753ad52c8c05124bdf27e6f1856de49faa1829658e` |
| `historic-routing-egp-0.1.1-1.el10.x86_64.rpm` | 22,980 B | `1ec43df88b319e4afa50cb388f4dcb4b4edf11858c9977324731df0fb7845dcb` |
| `historic-routing-runtime_0.1.1-1_amd64.deb` | 2,232,236 B | `f0469ea32c0ade2c086ff42c734ab86022270a89d3750a60aead5c296f6f3fb1` |
| `historic-routing-egp_0.1.1-1_amd64.deb` | 21,492 B | `9e4b7fe6926e78668bef3ffd239c4aaa48a57e714a13c1fb788bb959101f5e7e` |
| `historic-routing-81c494688b-src.tar.xz` | 14,692,952 B | `4b5d5f5061bcbbb5cc0322a1cc6558c5e99b46c7eded43626283dc72cc5f311a` |

统一清单：`docs/releases/v0.1.1/SHA256SUMS`（`sha256sum -c` 可直接校验）。

**仅用于升级测试、不是发布产物**：RPM `…-0.1.2-1.el10`、DEB `…_0.1.2-1_amd64`（同一提交构建，
故意取更高版本号，只用于验证升级路径）。

## 3. 包内元数据（实测）

| 项 | RPM | DEB |
| --- | --- | --- |
| Version-Release | `0.1.1-1.el10` | `0.1.1-1` |
| Summary/Description | `… (official release 0.1.1)` | `… (official release 0.1.1)` |
| ABI 绑定 | `provides: historic-routing-abi = 81c4946-27f287be9` | `Provides: historic-routing-abi (= 0.81c4946-27f287be9)`，`abi_raw=81c4946-27f287be9` |
| egp → runtime | `Requires: historic-routing-runtime(x86-64) = 0.1.1-1.el10` | `Depends: historic-routing-runtime (= 0.1.1-1)` |
| 私有库 | `rpm -qpR` 无任何 `libfrr*` | `Depends` 无 `libfrr`（shlibs 只喂 `dpkg-shlibdeps`） |
| 运行目录 | `/run/historic-routing/frr`（RuntimeDirectory） | 同 |
| 源码提交 | `RPM-BUILD-INFO.txt: repo_commit=81c4946…` | `BUILD-INFO.txt: repo_commit=81c4946…` |
| FRR 输入 | `FRR_REPO_EFFECTIVE=file:///root/frr-mirror.git` | `FRR_REPO_EFFECTIVE=mirror:frr-27f287be9.git.tar.xz`、`FRR_MIRROR_SHA256=c63a9915…` |

## 4. 测试结果（正式包，全部真实执行）

| 项 | 结果 |
| --- | --- |
| RPM 安装/启动/升级(0.1.2)/降级/卸载 | **34/34 PASS**，`ALL_PASS`；卸载后前缀完全删除、`/run` 无残留；`rpm -V frr` 干净 |
| RPM `rpmlint` | **0 error / 0 warning**（56 filtered，逐条理由见 `rpmlintrc`） |
| RPM EGP 双路由 | **13/13** |
| DEB 构建 | 在 `podman run --network none`（无网络）里从发布源码包构建成功；`lintian` 0 error / **3 warning** |
| DEB 安装/运行/升级(0.1.2)/降级/purge | 各步 `rc=0`；`dpkg -V` 无差异；只装 egp 被 `apt` 拒绝（rc=100）；conffile 修改跨升级保留 |
| DEB 与发行版 frr | 无真实文件冲突（交集仅公共父目录）；`dpkg -V frr` 干净；不碰 `/etc/frr` |
| DEB EGP 双路由 | **13/13** |
| 跨包指纹 | 归一化后 **33 项输入字段完全一致**，仅 DEB 多两个附加字段（`abi_raw`、`FRR_MIRROR_SHA256`）；源码提交、FRR 提交、4 个补丁 SHA256、8 个协议源码 SHA256、路由类型/显示码/距离/vtysh 位全部相同 |

`lintian` 的 3 条 warning：`debian-changelog-line-too-long`（两个包各一条，版本行较长）、
`extended-description-line-too-long`（runtime，`Description` 第 13 行由新增的发布说明引入）。
均为格式类，不含语义问题；修法是把该行折成两行后重新构建（本轮不为此再重建一轮）。

## 5. 候选提交到发布提交之间没有代码改动

`cb8336c`（S8-C 候选，已验收）→ `81c4946`（本次发布提交）之间的差异**只有**：

| 文件 | 性质 |
| --- | --- |
| `scripts/package-rpm.sh`、`scripts/package-deb.sh` | 新增 `--kind dev\|release` 开关 |
| `packaging/rpm/historic-routing.spec` | `hr_is_release` 分支，文案不再写 "development build" |
| `packaging/debian/control.in`、`changelog.in` | `@KIND_SHORT@/@KIND_LONG@/@KIND_CHANGELOG@` 占位符 |
| `packaging/{rpm,debian}/*.service*` | Description 统一 `(experimental, non-production)` |
| `packaging/debian/copyright` | 增加 FRR 源码可得性说明 |
| `CHANGELOG.md`、`docs/RELEASE_NOTES_v0.1.1.md`、`docs/LICENSE_AUDIT.md` | 文档 |

**没有**改动 EGP 协议源码、补丁、`build.sh` 的构建逻辑、安装布局。因此正式包与候选包在行为上等价，
只是版本号、文案与文档不同；**但仍然全部重新构建、重新测试**，没有沿用任何 dev 包。

## 6. 已知限制（与原样保留的 14 项）

1. `make check` 14 项已知失败保持原样（全部在编译期已 `--disable` 的 isisd/pimd），`MAKE_CHECK_RC=2` 写入指纹。
2. DEB 仅在 **Debian 13.7 用户态容器**验证，宿主内核是 RHEL 10.1 的 `6.12.0-…el10_1`；**未在独立 Debian 机器 / Debian 内核上验证**。
3. 只覆盖 amd64；未测 arm64、Debian 12、RHEL 9。
4. 容器内运行 zebra 需 `NET_ADMIN/NET_RAW/SYS_ADMIN`；真实主机 root 具备。
5. 升级测试只在同一提交的相邻版本间做（0.1.1 → 0.1.2），跨提交升级未测。
6. `vendor/`（14 MB）不入 git，随发布源码包分发。
7. 三个二进制在 RPM 与 DEB 之间哈希不同（gcc 14.4.1 vs 14.2.0、glibc、加固参数差异），跨发行版无法逐字节一致。

## 7. 敏感信息复查（全历史）

`git grep` 遍历 62 个提交：无 `192.168.` / `10.255.` / `C:\Users\…` / 私钥块 / `ghp_` / `AKIA` / 密码字段命中；
唯一命中 `172.16.0.0/16`、`198.18.x`（RFC 1918 与 RFC 2544 实验网段，实验文档中公开已久）与
`docs/HISTORY.md` 里描述扫描器误报的 "toor" 一词（非凭据）。
