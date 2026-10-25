# DEB 打包（Debian 13 amd64）

> 状态：**开发验证构建**。版本 `0.1.1~dev<源码短提交>-1`，Description 与 changelog 都写明
> "development build (NOT released)"。不是 v0.1.0 的发布包。

## 1. 两个包与严格绑定

| 包 | 内容 |
| --- | --- |
| `historic-routing-runtime` | `libfrr.so.0`、`zebra`、`vtysh`、`etc/frr/{frr,vtysh}.conf`、zebra unit、`BUILD-INFO.txt` |
| `historic-routing-egp` | `egpd`、`etc/frr/egpd.conf`、egpd unit |

绑定方式（双重）：

1. `historic-routing-egp` 依赖 `historic-routing-runtime (= ${binary:Version})` —— 版本必须完全相等；
2. 两个包共享 `historic-routing-abi = <源码短提交>-<FRR短提交>`：runtime `Provides`，egp `Depends`。

只靠 `libfrr.so.0` 的 SONAME 不够（不同构建 SONAME 相同、ZAPI 枚举可能不同），所以第 2 条是硬约束。

## 2. 安装布局与隔离

```
/opt/historic-routing/27f287be9/{bin,sbin,lib,etc/frr,BUILD-INFO.txt}
/usr/lib/systemd/system/historic-routing-{zebra,egpd}.service
/usr/share/doc/historic-routing-{runtime,egp}/
/run/historic-routing/frr/            ← socket / PID（RuntimeDirectory，见 §4）
```

发行版 FRR 的 `/etc/frr`、`/usr/sbin/frr*`、`/usr/lib/*/frr/libfrr.so.0`、`frr.service`
一律不碰。`libfrr` 用 `RUNPATH=$ORIGIN/../lib` 解析（`patchelf` 在 `debian/rules` 里改），
不写 `ld.so.conf.d`，因此不会和系统 `libfrr.so.0` 抢 ldconfig 缓存。

## 3. 构建流程

`scripts/package-deb.sh`：

1. 要求 `/etc/debian_version` 存在——**不在 RHEL 上生成 DEB**；
2. `git archive HEAD` 出源码快照，把 `packaging/debian/` 装成源码树里的 `debian/`，
   替换 `@VERSION@/@COMMIT@/@ABI@/@PREFIX@/@RUNSTATEDIR@`；
3. `dpkg-buildpackage -us -uc -b`；`debian/rules` 的 `override_dh_auto_build` 直接调
   `scripts/build.sh`（固定 FRR 提交 → 补丁 → 协议源码 → configure → make → 单测 →
   `make check` → `--destdir` 暂存安装），**不是**把已有目录打成包；
4. 对产物跑 `dpkg-deb -I/-c`、依赖断言、`sha256sum`、`lintian`。

`debian/rules` 不重写 FRR 的构建系统，构建逻辑与 RPM 共用同一份 `scripts/build.sh`。

## 4. socket / PID：放在 /run，不放前缀（S8-B 设计验证项）

configure 时传 `--runstatedir=/run/historic-routing`（FRR 会在其下建 `frr/` 子目录），
unit 里用：

```ini
RuntimeDirectory=historic-routing/frr
RuntimeDirectoryMode=0755
ExecStart=<prefix>/sbin/zebra -f <prefix>/etc/frr/frr.conf \
          -i /run/historic-routing/frr/zebra.pid \
          -z /run/historic-routing/frr/zserv.api \
          --vty_socket /run/historic-routing/frr -u root -g root
```

效果：

- 安装前缀里**没有** `run/` 目录，卸载后不会留下 socket/pid（RPM 阶段残留的就是这一类）；
- 服务停止时 systemd 直接删掉 `/run/historic-routing/frr`；
- `vtysh` 的编译期默认路径就是 `<runstatedir>/frr`，所以**不带参数**也能连上；
- 权限由 systemd 建目录，不需要 postinst 里 `mkdir`。

RPM 侧**本轮不改**（未验证的重构不做），差异记在 `docs/PACKAGING.md` 的"后续可复用设计"。

## 5. 与 RPM 包的区别

| 项 | RPM（S8-A） | DEB（S8-B） |
| --- | --- | --- |
| socket/PID | `<prefix>/run/frr`（包内目录） | `/run/historic-routing/frr`（RuntimeDirectory） |
| 版本字符串 | `0.1.1-0.1.dev<sha>.el10` | `0.1.1~dev<sha>-1` |
| 配置保护 | `%config(noreplace)` | `conffiles` |
| 服务 | 只装 unit，不 enable/start | 同（`dh_installsystemd --no-start --no-enable`） |
| 私有库依赖 | `__provides_exclude_from` / `__requires_exclude` | `.shlibs` + `dh_shlibdeps -l` |
| 构建输入 | `%build` 调 `scripts/build.sh` | `override_dh_auto_build` 调同一个脚本 |

## 6. 与 Debian 硬化编译参数的冲突（实测）

Debian 的 `dpkg-buildflags` 给 CFLAGS 加 `-ffile-prefix-map=$(CURDIR)=.`。它会让 FRR 的
xref 记录成相对路径（`./debian/hr-build/frr-src/lib/keychain_cli.c`），而
`python/xref2vtysh.py` 用 `os.path.relpath(file, frr_top_src)` 得到的前缀不是 `lib/`，
于是落到 `VTYSH_<目录名>` 的兜底分支，生成 `VTYSH_LIB` 这种不存在的宏：

```
vtysh/vtysh_cmd.c:19:8: error: 'VTYSH_LIB' undeclared here (not in a function)
```

`debian/rules` 的 `override_dh_auto_build` 只在调用 `scripts/build.sh` 时去掉这一个参数，
其余加固参数保留。这是"为了能构建"而不是"为了过测试"——`make check`/单测照常执行。

## 7. 本地构建

```sh
# 在 Debian 13 amd64 上（需要 debhelper、lintian、patchelf 及 control 里的 Build-Depends）
sudo apt-get install debhelper devscripts lintian patchelf
./scripts/package-deb.sh --work /tmp/hr-deb --keep
```

产物在 `<work>/src/*.deb`。
