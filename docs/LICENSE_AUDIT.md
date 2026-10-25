# 第三方许可与 FRR 源码分发要求（v0.1.1 发布前审计）

审计对象：发布源码包 `historic-routing-<short>-src.tar.xz` 与四个安装包（RPM/DEB × runtime/egp）。

## 1. 本仓库自有代码

| 范围 | 许可 | 说明 |
| --- | --- | --- |
| `scripts/`、`lab/`、`packaging/`、`docs/` | GPL-2.0-or-later | 与 `LICENSE` 一致，文件头带 SPDX |
| `protocols/egp/src/*`、`protocols/egp/tests/*`、`protocols/egp/build/*` | GPL-2.0-or-later | 文件头 `// SPDX-License-Identifier: GPL-2.0-or-later` |
| `patches/frr/egp/*.patch` | GPL-2.0-or-later | 对 FRR（GPL-2.0-or-later）的修改，patch 内保留上游版权与作者信息 |

`LICENSE` 为 GPL-2.0 全文（取自 FRR 的 `doc/licenses/GPL-2.0`），版权行为
"1998-2026 Kunihiro Ishiguro, et al. (FRRouting contributors)"，与上游一致。

## 2. 分发的 FRR 派生二进制

安装包内的 `libfrr.so.0`、`zebra`、`vtysh` 是 **FRR 源码（GPL-2.0-or-later）加上本项目的 4 个补丁**
构建出来的。GPL 要求随二进制提供对应源码，本项目的做法：

1. 发布源码包内含 `vendor/frr-27f287be9.git.tar.xz`——固定 FRR 提交
   `27f287be9210d4024a140486b7b8ddd5eb41fe04` 的完整 bare 仓库（含历史与许可文件），
   并有 `SHA256SUMS` 校验；
2. 补丁本身在 `patches/frr/egp/`，`SHA256SUMS` 记录其哈希；
3. 构建脚本 `scripts/build.sh` 从上述源码 + 补丁重新生成完全相同的源码树，指纹记录
   `FRR_PATCHED_DIFF_SHA256`（打过补丁后的 diff 哈希）。

因此"源码可得"不是口头承诺：**离线、可复现、哈希可核对**（DEB 已在 `--network none` 容器内验证）。

## 3. 运行期依赖（不随包分发）

RPM 与 DEB 都动态链接系统库，**不打包、不再分发**这些库：

| 库 | 许可 | 来源 |
| --- | --- | --- |
| glibc (`libc6`) | LGPL-2.1-or-later | 发行版 |
| libyang 3 | BSD-3-Clause | 发行版 |
| json-c | MIT | 发行版 |
| libcap | BSD-3-Clause 或 GPL-2.0 | 发行版 |
| libcrypt / libcrypt1 | LGPL-2.1-or-later | 发行版 |
| readline | GPL-3.0-or-later | 发行版 |
| libpcre2 / libc-ares / libelf / systemd-libs | BSD-3 / MIT / LGPL-2.1 / LGPL-2.1 | 发行版 |

（DEB 侧由 `dpkg-shlibdeps` 自动写进 `Depends`；RPM 侧由 rpm 的自动依赖分析写进 `Requires`。
两边都不带 `libfrr*`，私有库只在本包前缀内解析。）

## 4. 不打包的内容

- FRR 的 `lib/frr/modules/*.so`（避免与系统 `frr` 的 soname 命名空间纠缠）；
- 任何 `/etc/frr`、`/usr/sbin/frr*`、`frr.service`、系统 `libfrr`；
- 第三方库的副本。

## 5. 结论

- 许可声明齐全（源码 SPDX、`LICENSE`、DEB `copyright`(DEP-5)、RPM `License:` + `%license`）；
- FRR 源码分发要求满足（发布源码包内含固定提交的完整仓库 + 补丁 + 哈希清单）；
- 未发现需要额外授权或与 GPL 冲突的第三方代码。

已知缺口（不隐瞒）：`vendor/` 目录不进 git（14 MB），只随发布源码包分发；如果只拿 git 仓库而
不拿发布源码包，构建时仍需自行提供 FRR 源码镜像（`--frr-repo` / `HR_FRR_MIRROR_TARBALL`）。
