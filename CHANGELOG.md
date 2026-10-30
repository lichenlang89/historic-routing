# Changelog

## [Unreleased]

### Changed

- `redistribute egp` 与 `show ip route egp` 在默认构建里可用：`lib/log.c` 的
  `proto_redistnum` 映射由原可选补丁 `0005` 并入必需补丁 `0001`。EGP 补丁集由
  5 个变成 4 个，`--with-optional` 只为未来协议保留。
- 因此 `patches/frr/SHA256SUMS` 与 `0001-0004` 的哈希全部更新；`0001` 现在改
  4 个文件（新增 `lib/log.c`）。

### Added

- `show ip egp neighbors [detail] [json]`、`show ip egp neighbors A.B.C.D [json]`：
  输出每邻居的定时器剩余、tx/rx 计数器，以及每条学到的网络（前缀 / distance /
  gateway / 遗漏次数 / age）。
- `clear ip egp neighbor *`：一次重启所有邻居的获取。
- Error 报文（type 8）：长度/头部错误（reason 1）、数据域错误（reason 2）、Poll 指到未知网络
  （reason 3）、Hello 过快（reason 4）；收到 Error 只计数、不改状态、不回复。
  Refuse 只接收不生成（RFC 904 没有定时器上限，加了会拒绝仍然合法的配置）。
- `lab.sh reload`：frr-reload 重载 egpd 配置的回归（不重启、不抖邻居、可幂等）。

## [0.1.1] - 2026-10-25

首个带安装包的发布版（实验性，非生产用途）。

### Added

- RPM（RHEL 10.1 x86_64）与 DEB（Debian 13 amd64）原生包：`historic-routing-runtime` +
  `historic-routing-egp`，装到 `/opt/historic-routing/27f287be9/`，不覆盖系统 FRR。
- 发布源码包：源码树 + 固定 FRR 提交的离线镜像（`vendor/frr-27f287be9.git.tar.xz`）+
  SHA256 清单，`--network none` 下可完整构建。
- `docs/RELEASE_NOTES_v0.1.1.md`、`docs/LICENSE_AUDIT.md`。

### Changed

- socket/PID 统一到 `/run/historic-routing/frr`，由 systemd `RuntimeDirectory` 管理（RPM 与 DEB 一致）。
- `scripts/package-{rpm,deb}.sh` 新增 `--kind release`：正式包内不再出现 "development build / NOT released" 文案。

### Known issues

- `make check` 14 项已知失败（isisd/pimd，编译期已 `--disable`）。
- DEB 仅在 Debian 13 用户态容器验证（宿主机内核为 RHEL 10.1）；未在独立 Debian 机器验证。

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的写法，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 0.x 阶段：任何一次发布都可能改变 CLI 与实验参数，破坏性变更会在本文件里显式标注。

## [Unreleased]

### Wireshark

- 纳入 EGP Lua 解析器及安装、压缩包分发说明；按 RFC 904 区分 Acquisition
  状态语义、解析 Error 的 12 字节引用、标记 unsolicited 与不可达距离。
- 新增真实 TShark 离线报文回归和独立 CI，检查校验和及截断边界。

### Fixed

- EGP Update 按实际 distance 分组编码；distance 255 只撤销相应网络，不再拒绝整份
  Update。保留其它可达网络及 distance 0 的处理；本地宣告仍使用 distance 1。
- 新增距离分组金样本、255 路由边界测试和 `lab.sh test-updates` 原始报文回归。

### Added

- **S8-C：RPM/DEB 统一 + v0.1.1 发布候选（未发布）**
  - RPM 移植 DEB 的 `RuntimeDirectory` 设计：socket/PID 移到 `/run/historic-routing/frr`，
    安装前缀里不再有 `run/`；卸载后无残留（实测）。
  - `scripts/release-source.sh`：产出带离线 FRR 镜像（SHA256 + commit/tree 校验）的发布源码包；
    DEB 已在 `--network none` 容器里用它构建成功。
  - `build.sh` 指纹记录离线镜像与其 SHA256；`--runstatedir` 覆盖不再重复出现。
  - 候选清单：`docs/RELEASE_CANDIDATE_v0.1.1.md`（单一源码提交 `cb8336c`，RPM/DEB 同源）。
- Debian 原生打包（S8-B，Debian 13 amd64 用户态实测，**开发验证构建，未发布**）：
  `packaging/debian/`（control/rules/changelog/copyright/conffiles/install/units/postinst 等）、
  `scripts/package-deb.sh`；两个包 `historic-routing-runtime` 与 `historic-routing-egp`，
  版本 `0.1.1~dev<源码短提交>-<revision>`，装到 `/opt/historic-routing/27f287be9`；
  socket/PID 改由 systemd `RuntimeDirectory=/run/historic-routing/frr` 管理。
- `scripts/vendor-frr.sh` + `fetch-frr.sh` 的 `HR_FRR_MIRROR_TARBALL`：把固定 FRR 提交做成
  带 SHA256 与 commit/tree 校验的离线构建输入，正式打包不再依赖构建时联网。
- `docs/PACKAGING.md` §9–§11：DEB 实现状态、RuntimeDirectory 设计（含 RPM 侧改法）、
  离线构建输入设计。
- RPM 原生打包（S8-A，RHEL 10.1 x86_64，**开发验证构建，未发布**）：
  `packaging/rpm/`（SPEC + 两个 systemd unit + `rpmlintrc` + `verify-rpm.sh` + README）、
  `scripts/package-rpm.sh`；一个 SPEC 出 `historic-routing-runtime` 与
  `historic-routing-egp` 两个子包，版本 `0.1.1-<n>.dev<源码短提交>.el10`，
  安装到 `/opt/historic-routing/27f287be9`，与系统 FRR 完全隔离。
- `scripts/build.sh` / `scripts/install.sh` 支持 `--destdir`（打包时的暂存安装），
  `scripts/fetch-frr.sh` 支持 `HR_FRR_REPO`（离线镜像，提交与补丁哈希仍强制校验）。
- RPM 依赖治理：私有 `libfrr.so.0` 不再进入系统 soname 命名空间
  （`__provides_exclude_from` + `__requires_exclude`），二进制 RUNPATH 改为
  `$ORIGIN/../lib`，不打包 `lib/frr/modules/*.so`。
- 多协议架构（S7）：`protocols/<name>/PROTOCOL.meta` 作为唯一资源登记处，
  `scripts/check-allocations.sh` 检查路由类型/显示码/vtysh 位/daemon 名不重复且与补丁一致，
  `build.sh` / `verify.sh` 支持 `--protocols egp,ggp`，路由类型编号按登记顺序自动断言。
- `docs/PACKAGING.md`：RPM/DEB 的公共运行时 + 独立协议包划分设计（未实现）。
- `scripts/verify.sh`：统一验证入口（`--build-only` / `--lab-only` / `--all`），结果分
  `PASS / FAIL / SKIP / KNOWN-FAIL`，退出码 0/1/2/3。
- `scripts/parse-make-check.py`：把 FRR 完整 `make check` 的每个失败测试的**异常文本**
  提取出来分类，生成 `docs/known-failures.md`（不再按失败目录推断）。
- `patches/frr/SHA256SUMS`、`protocols/egp/evidence/SOURCES.sha256`：补丁与协议源码的哈希基线。
- `docs/LAB_SAFETY.md`：实验环境安全审查（八项检查、最小能力集、A/B 证据、残余风险）。
- `docs/evidence/sys-admin-ab.txt`：zebra 需要 `SYS_ADMIN` 的 A/B 实测输出（由 `verify.sh` 现场生成）。
- `docs/RELEASE_NOTES_v0.1.0.md`、`docs/RELEASE_CHECKLIST.md`、本 `CHANGELOG.md`。
- `lab.sh` 新增参数白名单校验（`check_params()`）、`up` 中途失败的清理提示。

### Changed

- 文档按"实际做到了什么"重写：`docs/FIDELITY.md` 明确区分**已支持 / 实验性简化 / 未实现**；
  `README.md` 增加验证边界（已复现的环境 vs 未验证的环境）；`docs/ARCHITECTURE.md` 增加验证层；
  `docs/ADD_A_PROTOCOL.md` 从"骨架"改为"可用"，并附新协议最小验收清单。
- `verify.sh` 在指纹（基线 + 补丁 + 协议核心源码）未变时**复用已有构建**，不重复编译。

### Fixed

- 实验脚本的参数校验缺口：空的 `LAB_NET` 曾可通过 `assert_our_network`，
  非绝对路径的 `LAB_PREFIX` 也没有拦截。

## [0.1.0] — 待发布

首个可验证的实验版本：**Experimental EGP (RFC 904)**。

### Added

- 独立仓库结构：`protocols/`（协议源码）、`patches/frr/`（FRR 适配补丁）、`scripts/`（构建与验证）、
  `lab/`（容器实验）、`docs/`（架构、历史、忠实度、加协议手册）。
- `scripts/build.sh`：从固定基线 FRR `27f287be9210d4024a140486b7b8ddd5eb41fe04`
  一键构建到独立安装前缀（拉取 → 打补丁 → 集成源码 → configure → make → 单测 →
  `make check-TESTS` → 完整 `make check` → `make dist` → 安装 → 指纹）。
- FRR 适配补丁 0001–0004（lib 路由类型、zebra 距离 140、vtysh 集成、构建与测试注册），
  0005（`redistribute egp`）作为可选补丁默认不启用。
- `protocols/egp/`：`egpd` 守护进程、EGP 报文编解码、单元测试（金样本/边界/非对齐）。
- `lab/egp/`：Podman 双路由器实验（两台容器、自建网络、参数集中在 `lab.env.example`），
  集成测试 13 项（邻接、双向学习、类型 G/距离 140、内核路由、Stub 间 UDP、
  撤宣告/重宣告、egpd 异常退出与重启、zebra 重启、删邻居、收尾恢复）。
- 文档：`docs/ARCHITECTURE.md`、`docs/HISTORY.md`（S0–S6 执行记录）、
  `docs/FIDELITY.md`（RFC 904 忠实度矩阵）、`docs/ADD_A_PROTOCOL.md`、
  `docs/LAB_SAFETY.md`、`docs/build-fingerprint-20261024.txt`。

### Known issues

- 完整 `make check` 有 14 项失败：逐条证据表明是被 `--disable` 的 isisd/pimd
  缺少可执行文件所致（见 `docs/known-failures.md`），原始退出码 rc=2 保留。
  **未做**启用这两个 daemon 的对照构建。
- 只在 RHEL 10.1（x86_64）+ podman 5.6 上验证；未验证其他发行版、SELinux 域、
  系统服务（`frrinit`/systemd）启动方式。
- 实验容器需要 `SYS_ADMIN`（zebra 编译期能力集要求），见 `docs/LAB_SAFETY.md`。
