# v0.1.0 发布前验收清单

状态：**准备完成，未发布**。本轮（S6）不做 tag、不推送、不创建 GitHub Release。
发布由维护者确认后执行第 5 节的动作。

## 1. 代码与许可

| 项 | 要求 | 状态 |
| --- | --- | --- |
| `LICENSE` | GPL-2.0 全文（与 FRR 一致） | ✅ 18431 字节，GPL-2.0 |
| 源码 SPDX | `.sh/.py/.c/.h` 均有 `SPDX-License-Identifier: GPL-2.0-or-later` | ✅ 全部具备 |
| 补丁文件 | `patches/frr/000*.patch`（5 个）无 SPDX | ⚠️ 不适用：diff 格式，被修改的 FRR 文件自带 SPDX 与版权头，补丁不改许可 |
| automake 片段 | `protocols/egp/build/egpd.subdir.am` 无 SPDX | ⚠️ 有意保留：为维持"逐字节迁移"证明不变更该文件；许可随仓库 LICENSE |
| 来源声明 | README 说明非 FRR 官方、源码来自 `lichenlang89/frr` fork 的 tag `egp-verified-20261024` | ✅ `README.md`「许可」段 |
| 第三方代码 | 仓库内无第三方二进制/大文件 | ✅ 40 个受版本控制文件，最大 20 KB |

## 2. 敏感信息

| 项 | 要求 | 状态 |
| --- | --- | --- |
| 密码/令牌/私钥 | 无 | ✅ `verify.sh` A5 扫描通过；人工复查无 `ghp_`/`AKIA`/私钥块/`sshpass` |
| 个人路径 | 无 `<用户主页>/...`、无 `/home/<name>` | ✅ 已把 S0 记录中的个人路径改为 `<原始 EGP 工作树>`、`<仓库外备份目录>` |
| 内网 IP | 文档中不出现实验机内网地址 | ✅ 已改为"实验机（RHEL 10.1 …）"；实验网段 `198.18.123.0/24` 是文档化参数，保留 |
| 私有镜像 | 不依赖任何私有仓库镜像 | ✅ 只有 `quay.io/centos/centos:stream10`（公开）与本地构建的 `localhost/historic-routing-lab:egp` |
| SSH 配置 | 仓库内无 ssh config/known_hosts/密钥 | ✅ |
| 日志 | 证据日志只含容器内实验数据 | ✅ `protocols/egp/evidence/lab-test-*.log` |

## 3. 构建与测试（必须来自真实执行）

| 项 | 要求 | 状态 |
| --- | --- | --- |
| 干净目录构建 | 新目录 + 新构建根，从源码构建成功 | ✅ `docs/HISTORY.md` S6 记录 |
| 统一验证 | `scripts/verify.sh --all` 无 FAIL | ✅ 见 S6 执行记录（含 KNOWN-FAIL 的逐条证据） |
| EGP 单元测试 | `egpd/test_packet` 通过 | ✅ B5/B6 |
| 集成测试 | 容器内 13/13 | ✅ C3 |
| 完整 `make check` | 原样保留 rc，逐条证据归档 | ✅ `docs/known-failures.md` |
| 清理 | 实验资源全部清理，无残留 | ✅ C5/C6 |
| 指纹 | `fingerprint.txt` 与 `docs/build-fingerprint-20261024.txt` | ✅ |

## 4. 文档

| 文档 | 要求 | 状态 |
| --- | --- | --- |
| `README.md` | 定位、状态、用法、验证边界（已复现 vs 未验证） | ✅ |
| `docs/FIDELITY.md` | RFC 904 已支持 / 简化 / 未实现 + 验证状态 | ✅ |
| `docs/ARCHITECTURE.md` | 三层结构 + 验证层 + 硬约束 | ✅ |
| `docs/ADD_A_PROTOCOL.md` | 加协议流程 + 最小验收清单 | ✅ |
| `docs/LAB_SAFETY.md` | 八项安全审查 + 最小能力集 + 残余风险 | ✅ |
| `docs/HISTORY.md` | S0–S6 执行记录（含失败与修复） | ✅ |
| `docs/known-failures.md` | 自动生成，逐条失败证据 | ✅ |
| `docs/RELEASE_NOTES_v0.1.0.md` | 版本说明草稿 | ✅ 草稿 |
| `CHANGELOG.md` | Keep a Changelog 格式 | ✅ |

## 5. 发布动作（**本轮不执行**）

按顺序，每步失败即停止：

```sh
# 1) 最终确认
git status                      # 必须干净
./scripts/verify.sh --all --build-root /root/hr-build    # 必须无 FAIL

# 2) 打 tag（annotated，指向发布提交）
git tag -a v0.1.0 -m "historic-routing v0.1.0 — Experimental EGP (RFC 904)"
git show --stat v0.1.0

# 3) 推送（需要维护者明确授权）
git push origin main
git push origin v0.1.0

# 4) GitHub Release
#    - 标题：historic-routing v0.1.0 — Experimental EGP (RFC 904)
#    - 正文：docs/RELEASE_NOTES_v0.1.0.md
#    - 附件：构建根 fingerprint.txt、docs/known-failures.md、实验日志
#    - 勾选 pre-release（0.x 实验版本）
```

## 6. 发布后

- 把 `CHANGELOG.md` 的 `[0.1.0] — 待发布` 改成实际发布日期。
- 在 `docs/HISTORY.md` 追加"发布记录"（tag、提交、验证轮次）。
- 保留本轮验证日志（`<build-root>/logs/`），不要覆盖。

## 7. 已知问题（发布说明里必须出现）

1. 完整 `make check` 14 项失败（逐条证据为 isisd/pimd 缺可执行文件；**未做对照构建**）。
2. 只在 RHEL 10.1 x86_64 + podman 5.6 上验证；未验证其他发行版、SELinux 域、系统服务启动。
3. 实验容器需要 `SYS_ADMIN`（zebra 编译期能力集决定）。
4. 无发行包，只支持源码构建。
