# lab/egp — EGP 双路由器实验

两台隔离的 Podman 容器，各自运行 `zebra` + `egpd`，在实验网段
`198.18.123.0/24` 上用 **IPv4 协议号 8** 交换 EGP；各自带一个 dummy `stub0`
承载要宣告的有类网络，因此可以用真实 UDP 流量验证转发路径。

实验用**同一棵树**编出来的 FRR：容器不打包 FRR 二进制，而是把 S4 的
`make install` 前缀只读挂载进去。

## 前置条件

| 依赖 | 说明 |
| --- | --- |
| `podman` | 已在 podman 5.6 上验证；rootful |
| S4 安装前缀 | 含 `sbin/{egpd,zebra}`、`bin/vtysh`、`lib/libfrr.so*`，且来自同一次构建 |
| 实验镜像 | 由本目录 `Containerfile` 从公开基础镜像构建（见下） |
| `python3` | 宿主机上跑 `test_lab.py`（仅用标准库） |

## 快速开始

```sh
cd lab/egp
./lab.sh build            # 构建镜像 localhost/historic-routing-lab:egp
./lab.sh up               # 预检 + 起容器 + 起 daemon（等到邻居 Up）
./lab.sh status           # 邻居 / RIB / 内核路由
./lab.sh vty 1            # 进 r1 的 vtysh（exit 退出）
./lab.sh test             # 12 项集成测试 + 收尾校验
./lab.sh reload           # frr-reload 回归（network 无损、清空/AS/timers、错误及恢复）
./lab.sh down             # 只删本实验的容器与网络
```

`cp lab.env.example lab.env` 可以只写要改的项（先加载 example 的默认值，再用
`lab.env` 覆盖）。`lab.env` 已在 `.gitignore` 里，**不要提交个人路径或凭据**。

`test-protocol` 还覆盖独立报文构造的内部/外部混合网关、无效下一跳原子拒绝、
同前缀备用网关切换和逐候选遗漏老化。`reload` 保留 network 无损与幂等检查，
并测试全量清空、默认值、AS/timers 变更、语法/语义错误及恢复；全局变化有意重建邻接，
不会重启 egpd；还会渲染并执行 RPM/DEB 原模板的 `ExecReload` 命令
（等价命令检查，不是安装包 systemd/SELinux 验收）。等待失联邻居 Cease abort 最长约 120 秒。

## 参数（lab.env）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `LAB_IMAGE` | `localhost/historic-routing-lab:egp` | 实验镜像名 |
| `LAB_BASE_IMAGE` | `quay.io/centos/centos:stream10` | 公开基础镜像 |
| `LAB_PREFIX` | `/opt/historic-routing/egp-27f287be9` | S4 安装前缀（宿主路径） |
| `LAB_MOUNT` | `/build/prefix` | 容器内挂载点（固定约定） |
| `LAB_NET` / `LAB_SUBNET` | `egp-lab-net` / `198.18.123.0/24` | 实验网络 |
| `LAB_NAME_PREFIX` | `egp-lab-r` | 容器名前缀（实际为 `egp-lab-r1`/`r2`） |
| `LAB_IP1` / `LAB_IP2` | `198.18.123.1` / `.2` | 两台路由器在实验网段的地址 |
| `LAB_AS1` / `LAB_AS2` | `65001` / `65002` | 本地 AS（低 AS 侧成为 active） |
| `LAB_TIMERS` | `2 6` | Hello/Poll 秒（实验值；实现默认 30/120） |
| `LAB_NET1` / `LAB_HOST1` | `10.0.0.0` / `10.0.0.1/8` | r1 宣告的有类网络与 stub 地址 |
| `LAB_NET2` / `LAB_HOST2` | `172.16.0.0` / `172.16.0.1/16` | r2 同上 |
| `LAB_UDP_PORT` | `9999` | 数据面测试端口 |
| `LAB_RUNDIR` | `/var/tmp/egp-lab` | 宿主侧日志目录（`logs/test-*.log`） |

## 容器内固定路径（契约，不要随意改）

| 路径 | 用途 |
| --- | --- |
| `/build/prefix` | 宿主安装前缀的只读挂载点；`LD_LIBRARY_PATH` 指向它的 `lib` |
| `/build/prefix/var`、`/build/prefix/run` | 只读前缀上的 **tmpfs**，给 zebra 存状态与 pid/socket 用 |
| `/tmp/egp/*.conf`、`/tmp/egp/*.log` | 生成的配置与日志（含 `<daemon>.start.log`） |
| `/tmp/run` | vty socket（`zebra.vty`/`egpd.vty`）、`zserv.api`、pid 文件 |

## 为什么需要这些容器参数

| 参数 | 原因 |
| --- | --- |
| `--cap-add NET_ADMIN` | 建 dummy 接口、zebra 写内核路由 |
| `--cap-add NET_RAW` | egpd 的 `socket(AF_INET, SOCK_RAW, 8)` |
| `--cap-add SYS_ADMIN` | **zebra 编译期声明的能力集是 `{NET_ADMIN, SYS_ADMIN, NET_RAW}`**，缺它 `privs_init` 直接失败（实测报 `initial cap_set_proc failed`） |
| `--init` | 容器 PID 1 用 podman 的 init 回收子进程；否则 SIGKILL 掉的 daemon 会以僵尸态留在进程表，使"进程是否在跑"的判断失真 |
| `--security-opt label=disable` | RHEL 系 SELinux 下允许容器内挂载与 raw socket |
| `-v $LAB_PREFIX:/build/prefix:ro` | 用同一棵树的产物；镜像里没有 FRR 二进制 |
| `--tmpfs .../var`、`.../run` | 给 zebra 提供可写的 state/run 目录。前缀是只读挂载，所以先在宿主侧建空目录当作挂载点，再用 tmpfs 盖住。注意 zebra 会打印 `failed to mkdir "<构建期前缀>/var/lib/frr"` 警告——二进制里写死的是 `--prefix` 路径，容器里挂载点是 `/build/prefix`；**这只是警告，不影响启动与装路由** |

## 安全边界

- 只操作名字精确匹配的资源：容器 `${LAB_NAME_PREFIX}1/2`、网络 `$LAB_NET`；
  `lab.sh` 里对这两个名字做了白名单断言，删错名字会直接报错退出。
- `up` 前会检查同名容器/网络是否已存在，存在就停下并提示 `down`，不会覆盖别人的资源。
- 前置探针在一次性容器里验证：`libfrr` 确实解析到挂载前缀、`NET_ADMIN` 与
  `NET_RAW` 可用。
- 不写宿主机 `/etc`、`/var`、`/run`；实验只存在于容器 netns 内。

## 12 项集成测试（`./lab.sh test`）

| # | 检查 | 判定依据（真实执行，不靠日志字符串） |
| --- | --- | --- |
| 01 | 两个 egpd 进程正常启动 | 容器内 `ps` 里存在**非僵尸**的 `egpd` 与 `zebra` |
| 02 | 双方邻居状态 Up | `show ip egp neighbors` 解析出 peer/AS/State/Mode |
| 03 | 双向学习 EGP 路由 | `show ip route json` 里存在 `protocol=egp` 的前缀 |
| 04 | 类型 G、管理距离 140 | JSON `protocol=egp` 且 `distance=140`；文本里 `G>* <prefix> [140/x]` |
| 05 | 内核路由存在 | `ip -j route` 里 `dst=... gateway=... protocol=zebra` |
| 06 | Stub 之间 UDP 双向 | 两个方向各起 UDP 回声服务，绑定 stub 地址收发 |
| 07 | 撤宣告后对端撤路 | `no egp network` 后对端 RIB 与内核都消失 |
| 08 | 重宣告后恢复 | `egp network` 后对端内核路由回来 |
| 09 | egpd 异常退出撤路 | `kill -9` 后对端在超时内撤掉路由 |
| 10 | egpd 重启恢复 | 重启后邻居 Up、双向路由重建 |
| 11 | zebra 重启后重放 | 杀 zebra 再起，egpd 重连并把路由重新下发 |
| 12 | 删邻居后撤路 | `no egp neighbor` 后本端与对端都撤路（Cease） |

第 13 项是**收尾校验**：确认实验已恢复到"双方 Up、双向路由齐备"，失败也算整体失败。

## 已知限制

1. `show ip route egp` 自 S9 起在默认构建里可用（`proto_redistnum` 的 `"egp"` 映射随
   补丁 `0001` 应用）。测试仍以 `show ip route json` 解析为准（`protocol=="egp"`、
   `distance==140`），文本里再确认显示码 `G`——两种方式互为独立证据。
2. **只在当前开发机（RHEL 10.1 + podman 5.6）验证过**。
   已在不改变镜像/前缀的前提下换目录、换容器名、换网段跑通，
   但尚未在"全新机器"上验证（见 `docs/HISTORY.md` 的 S5 记录）。
3. 实验网段与 stub 网段都是文档化值；同时开两套实验时记得改
   `LAB_NET/LAB_SUBNET/LAB_NAME_PREFIX/LAB_IP1/LAB_IP2`（已实测可行）。
