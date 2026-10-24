# scripts/

构建编排。**目前是空的**：脚本在 S4 才实现，这里只固定接口约定，避免 S4 时再讨论。

## 计划中的脚本与约定的接口

| 脚本 | 职责 | 输入 | 输出 / 断言 |
| --- | --- | --- | --- |
| `fetch-frr.sh` | 拉取 `patches/frr/BASELINE` 指定提交的 FRR 源码 | `--dir`（默认 `build/frr`） | 产出目录内 `git rev-parse HEAD` 等于 `FRR_COMMIT` |
| `apply-patches.sh` | 按序应用 `patches/frr/*.patch` | `--frr <dir>` | 先对全部补丁 `git apply --check`，全通过才 apply |
| `integrate-sources.sh` | 把 `protocols/<p>/` 复制进 FRR 树 | `--frr <dir> --protocols egp,…` | 复制前 `rm -rf` 目标目录；复制后文件数一致 |
| `build.sh` | 全流程编排 | `--jobs N --prefix DIR [--frr-src DIR]` | `HAVE_EGPD` 存在、`$FRR/build/egpd/egpd` 存在、`make check` 通过 |
| `install.sh` | `make install` 到指定前缀 | `--prefix DIR` | `$PREFIX/sbin/egpd` 存在 |
| `verify.sh` | 回归清单（见迁移方案 §9） | `--prefix DIR` | 全部检查项通过；产出报告 |
| `rebase.sh` | 升级 FRR 基线时重放补丁 | `--to <commit>` | 冲突报告 + 需要人工确认的位/编号漂移清单 |

## 硬性约定

1. 任何一步失败即退出非零，**不做部分应用、不跳过错误**。
2. 复制源码前必须清空目标目录。
3. `build.sh` 结束时写 `build/fingerprint.txt`：FRR 提交 + 每个补丁的 sha256 + 每个协议源码的 sha256 + 编译器版本。
4. 脚本不在仓库里写死 FRR 路径；路径一律从 `BASELINE` 或参数来。
