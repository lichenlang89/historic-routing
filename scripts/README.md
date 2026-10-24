# scripts/

构建编排。**S4 已实现并在 RHEL 10.1 上真实跑通**（2026-10-24；见 `docs/HISTORY.md`
的 S4 记录与 `docs/build-fingerprint-20261024.txt`）。`verify.sh` / `rebase.sh` 仍待实现。

## 一条命令

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
| 8b | `make check`（完整套件；失败按 `--disable-<daemon>` 归因） | 内联 | `make-check.log` |
| 8c | `make dist` + 包内容校验 | 内联 | `make-dist.log`、`make-dist-contents.txt` |
| 9 | `make install` + 产物与 ldd 校验 | `install.sh` | `install-manifest.txt` |
| 10 | 构建指纹 | 内联 | `fingerprint.txt` |

## 选项

| 选项 | 说明 |
| --- | --- |
| `--jobs N` | 并行度，默认 `nproc` |
| `--build-root DIR` | 构建根目录，默认 `<repo>/build`；`frr-src/`、`frr-build/`、`logs/` 都在其下 |
| `--prefix DIR` | 安装前缀，默认 `<build-root>/prefix` |
| `--with-optional` | 额外应用 `0005`（`redistribute egp`），默认不启用 |
| `--reuse-source` | 复用 `<build-root>/frr-src`；提交不符或工作树脏则报错（不自动删） |
| `--skip-checks` | 跳过 make check（会写进指纹，不推荐） |
| `--skip-dist` | 跳过 make dist |
| `--configure-args "..."` | 追加 configure 参数 |

## 单独使用

```sh
scripts/fetch-frr.sh         --dir /root/hr-build/frr-src [--force]
scripts/apply-patches.sh     --frr /root/hr-build/frr-src [--with-optional] [--record FILE]
scripts/integrate-sources.sh --frr /root/hr-build/frr-src [--protocols egp] [--manifest FILE]
scripts/install.sh           --build-dir /root/hr-build/frr-build --prefix DIR [--manifest FILE]
```

`fetch-frr.sh --force` 与 `integrate-sources.sh` 会删除目录，因此要求
`HR_BUILD_ROOT` 已设置、目标在其之内、末级目录名精确匹配——不要在别的路径上试。

## 已知限制（不是脚本 bug）

1. **完整 `make check` 不是全绿**：FRR 的 `make check` 会跑 `tests/runtests.py`，
   其中 `tests/isisd/*`、`tests/pimd/*` 的用例需要执行 `isisd/test_*`、`pimd/pimd`
   这类产物，而本项目沿用已验证的 configure 集合禁用了这两个 daemon。
   实测 `14 failed, 514 passed, 5 skipped`（rc=2），14 个失败全部落在这两个目录；
   原始退出码记录在 `fingerprint.txt` 的 `MAKE_CHECK_RC`，脚本按 `--disable-<daemon>`
   归因，**只有无法归因的失败才判构建失败**。EGP 自己的门禁是
   `make check-TESTS`（`PASS: egpd/test_packet`）。
2. **只写 `--prefix` 之内的路径**：`sysconfdir`/`localstatedir`/`runstatedir`
   都指向前缀内，`make install` 不触碰系统 FRR。
3. **同树编译**：`egpd` 必须与同一次构建出的 `zebra`/`libfrr`/`vtysh` 搭配使用
   （ZAPI 常量绑定），不要把它复制到发行版 FRR 旁边。

## 硬性约定

1. 任何一步失败即退出非零，**不做部分应用、不跳过错误**。
2. 复制源码前必须清空目标目录，并校验文件集合恰为预期。
3. 脚本不写死 FRR 路径：一律来自 `patches/frr/BASELINE` 或参数。
4. 日志统一追加到 `<build-root>/logs/build.log`（子步骤另有独立日志）；注意历史上
   曾用 `>` 重定向导致清空，已改为 `>>`。
