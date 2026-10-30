# 已安装软件包的服务验收

这两个驱动复用 `lab/egp/test_reload.py` 的行为断言，目标是**安装包自己的 systemd unit**，
不以手动执行 reload 脚本或重启 daemon 代替 `systemctl reload`。
实测版本、失败、恢复和平台边界见
[2026-10-31 证据](../docs/evidence/package-service-20261031/README.md)。

## 前置条件

仅在已经确认独占的实验资源中以 root 运行。驱动不创建/清理网络；调用者必须安排
失败后的服务停止、配置恢复、namespace/container/drop-in 清理与宿主状态比较。
不能直接指向生产路由器。Python 使用 `-B`，避免生成缓存污染构建工作树。

两端安装各自匹配的 runtime + egp，运行 Zebra + egpd；target 使用安装后的原 unit。
目标 AS 65001，对端 AS 65002，timers 1/1；独占链路互为直连邻居。
目标 stub 网络为 `10.0.0.0/8`，对端为 `172.16.0.0/16`，起点双向邻接与路由必须健康。
配置文件放在安装前缀 `etc/frr/egpd.conf`。容器必须真正以 systemd 为 PID 1，
具有实验需要的网络能力，且两个网络命名空间不能接入宿主业务路由。

容器 backend.json 示例（名字/IP 必须对应自行准备的独占环境）：

```json
{
  "prefix": "/opt/historic-routing/27f287be9",
  "packages": "deb",
  "ip1": "198.18.251.11", "ip2": "198.18.251.12",
  "target": {"container": "hrpkg-deb-r1"},
  "peer": {"container": "hrpkg-deb-r2"}
}
```

原生 RPM backend 把 packages 改为 `rpm`，target 使用
`{"netns":"hrpkg-rhel1","socket":"/run/historic-routing/frr"}`，peer 使用
`{"netns":"hrpkg-rhel2","socket":"/run/hrpkg-peer"}`。两个安装 unit 需要
`NetworkNamespacePath=/run/netns/hrpkg-rhel1` drop-in；驱动检查 target 进程 netns inode。
原生 peer 是在另一个 netns 内、用相同已安装前缀启动的两个 daemon；其 PID 文件位于
peer.socket，配置位于 backend.json 同目录的 `peer/{zebra,egpd}.conf`，
便于替换共享前缀前停止它们、替换后以新二进制重新启动。

## 执行

```sh
python3 -B packaging/test_installed_reload.py --config /path/to/backend.json
python3 -B packaging/test_package_lifecycle.py --config /path/to/backend.json \
  --old /path/to/old/runtime-package /path/to/old/egp-package \
  --new /path/to/new/runtime-package /path/to/new/egp-package
```

reload 驱动覆盖 network 增删/幂等、全部清空/重复清空、AS/timers 变化、错误语法、
错误语义、恢复；成功后原文件内容、PID、邻接、双向路由都须恢复。
语义错误会返回非零但可能已经部分应用，恢复原配置是测试的一部分。
150 秒 unit 超时用于涵盖 RFC 904 Cease 的 120 秒等待，不能以重启绕开。

lifecycle 起点必须安装 `--old` 那一对。逐个新组件的依赖探测必须拒绝不匹配组合，
之后正常 dnf/apt **成对升级 → 回退 → 再升级**，每步检查配置、版本、起停、RIB/内核。
RPM 配置使用 noreplace；DEB 实验明确使用 `--force-confold` 保留运维配置，不声称无选择地
自动合并配置。driver 会临时加入配置标记并在 finally 恢复，最外层还需保留完整备份。
原生 peer 和 target 共享前缀，因此替换文件前两者都要停止；容器根文件系统相互独立。

SELinux 的受限域实验使用[可选配置](selinux/README.md)，需要额外环境 drop-in；
默认包的 unconfined_service_t 成功不能代替该实验。

## 构建证据

```sh
scripts/package-deb.sh --work /path/to/build --keep
```

`--keep` 保留 `src/historic-routing-*/debian/hr-build/{logs,fingerprint.txt}`。
原实现即使 --keep 也传 `dpkg-buildpackage -tc`，导致 build 后清掉原始 make-check 日志；
本轮修正并重新构建验证。构建失败、首次环境错误和后续重试日志应分开保存。
