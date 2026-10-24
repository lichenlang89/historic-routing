# scripts/

构建与验证编排。S4 的构建脚本、S6 的统一验证脚本都已在 RHEL 10.1 上真实跑通
（2026-10-24，见 `docs/HISTORY.md` 与 `docs/build-fingerprint-20261024.txt`）。
`rebase.sh`（基线升级）仍未实现。

## 一条命令验证全部

```sh
./scripts/verify.sh --all --build-root /root/hr-build
```

三种模式：`--build-only`（A+B）、`--lab-only`（A+C）、`--all`（默认）；
`--protocols egp,ggp` 可指定协议集合（默认 `egp`）。
每行结果是四种状态之一：`PASS` / `FAIL` / `SKIP`（写明原因）/ `KNOWN-FAIL`（写明逐条证据）。
退出码：`0` 通过、`1` 有 FAIL、`2` 用法/环境错误、`3` 有 SKIP（= 验证不完整）。

| 段 | 检查 | 判定依据 |
| --- | --- | --- |
| A1 | BASELINE 可读、提交是 40 位 SHA | `patches/frr/BASELINE` |
| A2 | 补丁 SHA256 | `patches/frr/SHA256SUMS` |
| A3 | 协议源码 SHA256 | `protocols/egp/evidence/SOURCES.sha256` |
| A4 | 补丁在固定基线上顺序可应用 | 在一次性 `git worktree` 里真打 0001–0004，不动 `frr-src` |
| A5 | 敏感信息扫描 | 私钥/令牌/口令赋值 |
| A6 | 多协议资源分配 | `scripts/check-allocations.sh`：路由类型/显示码/vtysh 位/daemon 名不重复，且补丁与 `PROTOCOL.meta` 一致 |
| B1 | 构建 | 指纹与当前基线/补丁/核心源码一致则**复用、不重复编译**，否则调 `build.sh` |
| B2 | 产物与依赖 | 三个二进制 + `libfrr.so.0` 存在，`ldd` 无 `not found` |
| B3 | 产物与指纹一致 | 二进制 SHA256 与 `fingerprint.txt` 相符（证明用的就是这次构建） |
| B4 | 路由类型 | `ZEBRA_ROUTE_EGP=32`、`ZEBRA_ROUTE_MAX=34` |
| B5 | EGP 单元测试 | 现场执行 `egpd/test_packet` |
| B6 | `make check-TESTS` | 必须有 `PASS: egpd/test_packet` 且 FAIL=0 |
| B7 | 完整 `make check` | 保留原始 rc；逐条失败按**异常文本**分类并写 `docs/known-failures.md` |
| B8 | `make dist` | 包内必须有 `egpd/` 源码与 automake 片段 |
| C0 | 实验前置 | podman 可用、镜像存在（否则现场构建） |
| C0b | 最小权限 A/B | 不给 `SYS_ADMIN` 时 zebra 必须 `cap_set_proc` 失败，给了必须能起 |
| C1 | 实验启动 | `lab.sh up` 且两端邻居 Up |
| C2 | 重复 `up` | 必须被拒绝（命名冲突保护） |
| C3 | 集成测试 | `lab.sh test` 的 13 项（12 + 收尾校验）全通过 |
| C4 | 异常中断后清理 | 先 `podman kill` 掉一台容器，`down` 仍成功 |
| C5 | 清理验证 | 无残留容器/网络/进程/宿主机路由 |
| C6 | 重复 `down` 幂等 | 资源不存在时仍返回 0 |

## 多协议资源检查

```sh
./scripts/check-allocations.sh            # 只查登记与补丁的一致性
./scripts/check-allocations.sh --frr DIR  # 再与固定基线比对（显示码/类型/vtysh 位是否被上游占用）
```

它读 `protocols/*/PROTOCOL.meta`，检查 12 类资源跨协议唯一、vtysh 位在保留区间且是 2 的幂、
补丁内容与登记一致、源码/automake/测试文件齐全；有 `--frr` 时还能发现上游抢用。

产出：`<build-root>/logs/verify.log`（全量日志）、`logs/allocations.log`、`known-failures.tsv`、
`docs/known-failures.md`（自动生成，逐条失败证据）、`docs/evidence/sys-admin-ab.txt`（能力 A/B 原始输出）；
`--json FILE` 另存机器可读结果。

选项：`--build-root`、`--prefix`、`--jobs`、`--force-build`、`--skip-full-check`、
`--skip-dist`、`--keep-lab`、`--no-cap-audit`。

## 构建：一条命令

```sh
./scripts/build.sh --jobs 4 \
  --build-root /root/hr-build \
  --prefix /opt/historic-routing/egp-27f287be9
```

动作顺序（每步失败即非零退出；日志在 `<build-root>/logs/`）：

| # | 步骤 | 实现 | 日志 |
| --- | --- | --- | --- |
| 0 | 前置检查（命令、pkg-config libyang/json-c、gcc、pytest） | 内联 | `build.log` |
| 1 | 拉取固定基线 FRR | `fetch-frr.sh` | `build.log` |
| 2 | 应用补丁 0001-0004（0005 需 `--with-optional`） | `apply-patches.sh` | `patches-applied.txt` |
| 3 | 集成 `protocols/egp/` 源码（清空后复制 + SHA256 对照） | `integrate-sources.sh` | `integration-manifest.txt` |
| 4 | `bootstrap.sh` | 内联 | `bootstrap.log` |
| 5 | `configure --enable-egpd …` | 内联 | `configure.log`、`configure-args.txt` |
| 5b | 路由类型编号 / TESTS 注册校验（含 `=` vs `+=` 的 A/B 对照） | 内联 | `tests-registration-ab.txt` |
| 6 | `make -jN` | 内联 | `make.log` |
| 7 | `egpd/test_packet` | 内联 | `unit-test.log` |
| 8a | `make check-TESTS`（**硬门禁**：必须 `PASS: egpd/test_packet`） | 内联 | `make-check-tests.log` |
| 8b | `make check`（完整套件；失败按证据归因） | 内联 | `make-check.log` |
| 8c | `make dist` + 包内容校验 | 内联 | `make-dist.log`、`make-dist-contents.txt` |
| 9 | `make install` + 产物与 ldd 校验 | `install.sh` | `install-manifest.txt` |
| 10 | 构建指纹 | 内联 | `fingerprint.txt` |

## build.sh 选项

| 选项 | 说明 |
| --- | --- |
| `--jobs N` | 并行度，默认 `nproc` |
| `--build-root DIR` | 构建根目录，默认 `<repo>/build`；`frr-src/`、`frr-build/`、`logs/` 都在其下 |
| `--prefix DIR` | 安装前缀，默认 `<build-root>/prefix` |
| `--protocols LIST` | 要构建的协议（逗号分隔），默认 `egp`；每个协议按登记顺序应用 `patches/frr/<name>/` |
| `--with-optional` | 额外应用每个协议的 `0005`（`redistribute <proto>`），默认不启用 |
| `--reuse-source` | 复用 `<build-root>/frr-src`；提交不符或工作树脏则报错（不自动删） |
| `--skip-checks` | 跳过 make check（会写进指纹，不推荐） |
| `--skip-dist` | 跳过 make dist |
| `--configure-args "..."` | 追加 configure 参数 |

## 单独使用

```sh
scripts/check-allocations.sh [--frr /root/hr-build/frr-src]
scripts/fetch-frr.sh         --dir /root/hr-build/frr-src [--force]
scripts/apply-patches.sh     --frr /root/hr-build/frr-src [--with-optional] [--record FILE]
scripts/integrate-sources.sh --frr /root/hr-build/frr-src [--protocols egp] [--manifest FILE]
scripts/install.sh           --build-dir /root/hr-build/frr-build --prefix DIR [--manifest FILE]
scripts/parse-make-check.py  <make-check.log> <out.tsv> <out.md> [disabled-daemon ...]
```

`fetch-frr.sh --force` 与 `integrate-sources.sh` 会删除目录，因此要求
`HR_BUILD_ROOT` 已设置、目标在其之内、末级目录名精确匹配——不要在别的路径上试。

## 已知限制（不是脚本 bug）

1. **完整 `make check` 不是全绿**：FRR 的 `make check` 会跑 `tests/runtests.py`，
   其中 `tests/isisd/*`、`tests/pimd/*` 的用例需要执行 `isisd/test_*`、`pimd/test_pim_jp_encode`
   这类产物，而本项目沿用已验证的 configure 集合禁用了这两个 daemon。
   实测 `14 failed, 514 passed, 5 skipped`（rc=2）。
   **归因方式**：`parse-make-check.py` 逐条取该测试自己的 `E` 行，
   只有当异常文本本身指向被 `--disable` 模块的可执行文件（或由此产生的 setup 级联）时
   才判 `KNOWN`；不按目录推断。逐条证据见 `docs/known-failures.md`。
   **未完成**：没有做"启用 isisd/pimd 的对照构建"，所以是"证据支持"而不是"已证无关"。
   EGP 自己的门禁是 `make check-TESTS`（`PASS: egpd/test_packet`）。
2. **只写 `--prefix` 之内的路径**：`sysconfdir`/`localstatedir`/`runstatedir`
   都指向前缀内，`make install` 不触碰系统 FRR。
3. **同树编译**：`egpd` 必须与同一次构建出的 `zebra`/`libfrr`/`vtysh` 搭配使用
   （ZAPI 常量绑定），不要把它复制到发行版 FRR 旁边。

## 硬性约定

1. 任何一步失败即退出非零，**不做部分应用、不跳过错误**。
2. 复制源码前必须清空目标目录，并校验文件集合恰为预期。
3. 脚本不写死 FRR 路径：一律来自 `patches/frr/BASELINE` 或参数。
4. 日志统一追加到 `<build-root>/logs/build.log`（子步骤另有独立日志）；历史上
   曾用 `>` 重定向导致清空，已改为 `>>`。
