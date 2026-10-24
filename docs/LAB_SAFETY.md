# 实验环境安全审查（lab/egp）

审查对象：`lab/egp/lab.sh`、`lab/egp/test_lab.py`、`lab/egp/Containerfile`。
方法：**逐函数静态审查** + **由 `scripts/verify.sh` 现场执行的动态验证**（C0b、C1–C6）。
凡是"动态验证"的结论，都能在 `docs/evidence/` 或构建根的 `logs/verify.log` 里找到原始输出。

## 1. 八项检查结论

| # | 检查项 | 结论 | 依据 |
| --- | --- | --- | --- |
| 1 | 只创建/删除本项目资源 | 通过 | `assert_our_container()` 只接受 `$LAB_NAME_PREFIX`+`1/2`，`assert_our_network()` 只接受 `$LAB_NET`；`cmd_down` 只遍历这两台容器和这一个网络，没有任何通配符删除 |
| 2 | 不清理其他项目资源 | 通过 | 全脚本只有 3 处删除动作：`podman rm -f <我们的一台容器>`、`podman network rm <我们的网络>`、`rm -rf` 于 `verify.sh` 自己的临时目录；无 `podman system prune`、无 `podman network prune`、无 `podman rmi` |
| 3 | 拒绝危险路径与不合理参数 | 通过（S6 加固） | 新增 `check_params()`：镜像名/网络名/前缀字符白名单、CIDR 与 IPv4 逐段校验、`LAB_PREFIX`/`LAB_MOUNT`/`LAB_RUNDIR` 必须是绝对路径且不能是 `/`、AS 与端口范围 1..65535、`LAB_TIMERS` 形如 `2 6`；每个命令入口都先过这一关 |
| 4 | 防止容器名称冲突 | 通过 | `check_conflicts()` 对两台容器和网络各做一次 `exists` 检查，冲突即 `die` 并提示 `down` 或改 `LAB_NAME_PREFIX`；动态验证见 C2（第二次 `up` 必须以非 0 退出并说明"已存在"） |
| 5 | 异常中断后的清理 | 通过 | 容器带 `--init`（子进程被回收，不留僵尸）；`cmd_up` 在创建资源前装 ERR trap，中途失败会打印"执行 lab.sh down 清理半成品"；`down` 对"容器已被 kill/已不存在"的情况逐个跳过而不报错；动态验证见 C4（先 `podman kill` 掉一台容器再 `down`） |
| 6 | 重复 up/down/test 的行为 | 通过 | `up` 第二次 → 拒绝；`down` 第二次 → 成功（幂等）；`test` 在未 `up` 时 → `die` 提示先 `up`。动态验证见 C2/C6，静态依据 `cmd_test` 开头的 `podman container exists` 检查 |
| 7 | 失败后是否留下僵尸/容器/错误路由 | 通过 | C5 在 `down` 之后检查：无 `egp-lab*` 容器、无 `egp-lab-net` 网络、宿主机无 `zebra`/`egpd` 进程、宿主机路由表无 `10.0.0.0/8` 与 `172.16.0.0/16` |
| 8 | SYS_ADMIN 是否确实必要 | 必要，且有 A/B 证据 | 见下节 |

### 实验不触碰的东西

- 宿主机 `/etc`、`/var`、`/run`：实验配置与日志全在容器内 `/tmp/egp`、`/tmp/run`；
  宿主侧只写 `$LAB_RUNDIR/logs/` 和（可选的）`$LAB_PREFIX/var`、`$LAB_PREFIX/run` 两个空目录。
- 系统 FRR：`frr.service` 从未被 start/stop/enable；
  实验用的 `zebra`/`egpd` 是前缀里的二进制，且在容器 netns 内运行。
- 宿主路由表：实验网段与 stub 网段都只在容器 netns 内存在；`down` 后宿主机路由表与本实验开始前逐行相同。

## 2. 最小权限：为什么必须有 SYS_ADMIN

zebra 的能力集在编译期固定（`zebra/main.c` 的 `_caps_p[]`）：
`ZCAP_NET_ADMIN`、`ZCAP_SYS_ADMIN`、`ZCAP_NET_RAW`。
`privs_init()` 会调用 `cap_set_proc()` 把自己限制到这一组——**这组里就有 SYS_ADMIN**，
所以容器不提供 SYS_ADMIN 时，zebra 连启动都过不去（不是运行时才需要）。

A/B 实测（`docs/evidence/sys-admin-ab.txt`，由 `verify.sh` 的 C0b 现场生成）：

| 容器能力 | 结果 |
| --- | --- |
| `NET_ADMIN` + `NET_RAW` | `privs_init: initial cap_set_proc failed: Operation not permitted`，zebra 退出 |
| 再加 `SYS_ADMIN` | 正常启动、可连 zserv、可装路由 |

因此实验容器的**最小能力集**是：

| 能力 | 谁需要 | 不给会怎样 |
| --- | --- | --- |
| `NET_ADMIN` | `ip link add dummy`（stub0）、zebra 写内核路由 | 建 stub 失败、路由装不进内核 |
| `NET_RAW` | egpd 的 `socket(AF_INET, SOCK_RAW, 8)` | egpd 打不开 EGP socket |
| `SYS_ADMIN` | zebra 的 `privs_init`（能力集里声明了它） | zebra 起不来（cap_set_proc 失败） |

其余保持默认：无 `--privileged`、无 `--cap-add ALL`、无宿主网络（`--network` 是我们自建的网络）、
无宿主 PID/IPC 命名空间共享；`--security-opt label=disable` 只作用于这两个容器。

如果要进一步收权（S7 之后可做）：给 zebra 打一个把 `ZCAP_SYS_ADMIN` 变成可选的小补丁，
或者用 `CAP_SYS_ADMIN` 之外的手段处理 zebra 的 netns 需求。**本轮不做**：那会改 FRR 行为，
必须单独提交、单独验证。

## 3. 本轮修掉的问题

| 问题 | 影响 | 处理 |
| --- | --- | --- |
| `LAB_*` 参数无校验 | 空的 `LAB_NET` 会让 `assert_our_network ""` 通过；写错的前缀可能指向 `/` | 新增 `check_params()`，每个命令入口强制校验 |
| `up` 中途失败无提示 | 网络已建、容器没建全时，用户不知道要清理 | `cmd_up` 装 ERR trap，打印清理命令；`down` 本身对残缺状态安全 |
| 僵尸进程干扰"进程是否在跑" | 进程判活误报（S5 已修，S6 复核） | 容器 `--init` + `test_lab.py` 的 `alive_pids()` 排除 `Z` 状态 |

## 4. 残余风险

1. `LAB_NAME_PREFIX` 只保证"本项目前缀"格式合法；如果同一台机器上**同时**跑两套本实验，
   必须显式改 `LAB_NAME_PREFIX`/`LAB_NET`/`LAB_IP*`（已实测两套并行可行，但脚本不会自动错开）。
2. 容器里有 `SYS_ADMIN`，容器内 root 的能力高于最小需求；本实验假设容器镜像与挂载的前缀都是可信的本地构建产物。
3. `test_lab.py` 会 `kill -9` 自己的 egpd、`kill -TERM` 自己的 zebra，并把 `no egp neighbor` 作为用例；
   这些都只在实验容器内、只作用于本实验进程，`finally` 里恢复。
4. 未做：SELinux 强制（Enforcing）下 `label=disable` 之外的其他策略验证；`frr_t` 域运行。
