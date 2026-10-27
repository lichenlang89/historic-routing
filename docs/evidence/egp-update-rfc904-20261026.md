# EGP Update 距离与撤路回归（2026-10-26）

## 范围与规范

- [RFC 904 附录 A.4](https://www.rfc-editor.org/rfc/rfc904.html#appendix-A.4)：
  Update 的每个网关块包含 distance 分组，各组有自己的网络数量。
- [RFC 888 第 5 节](https://www.rfc-editor.org/rfc/rfc888.html#section-5)：
  distance 255 表示不可达，其余数值表示可达。
- 本轮修复实际 distance 的编码与显式不可达项的接收处理。第三方网关、
  unsolicited Update、连续多次遗漏后的老化和完整 core 状态机不在本轮范围内。

## 实测环境

- aarch64，Fedora 42 用户态构建/运行容器；GCC 15.2.1。
- 宿主内核：`6.12.0-211.49.1.el10_2.aarch64`。
- FRR 固定提交：`27f287be9210d4024a140486b7b8ddd5eb41fe04`；4 个必需补丁。
- 独立构建目录、安装前缀与实验容器/网络，未复用旧二进制。
- 实验 timers 为 `2 6`；使用单独的 `198.18.129.0/24` 网络。
- 运行镜像基于已有 Fedora 42 实验镜像，补入宿主的 `ps`、`pgrep`、`libproc2`。
  初次运行因缺少这些工具，进程检查 01/10/11 失败；补齐后从干净实验重新运行全部检查。
  这是本次验证镜像的准备方式，未修改项目 Containerfile，也未测试安装包。

## 结果

| 检查 | 结果 |
| --- | --- |
| `scripts/build.sh` 完整流程（固定源码 → 补丁 → 编译 → 检查 → dist → 安装） | rc=0 |
| `scripts/verify.sh --build-only --protocols egp --jobs 4` | **13 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL**，rc=0 |
| `make check-TESTS` | `egpd/test_packet` PASS，TOTAL=1 / PASS=1 / FAIL=0 |
| 完整 `make check` | 514 passed / 14 failed / 5 skipped，rc=2；14 项仍归因于禁用的 isisd/pimd 缺少可执行文件 |
| 独立 codec，`-Wall -Wextra -Werror -fsanitize=address,undefined` | rc=0，无 sanitizer 报告 |
| 新金样本配旧 `main` 编码器 | 在 `test_distances` 的独立金样本字节比较处失败，rc=134；确认能检出原缺陷 |
| `lab.sh test-updates` | **5 个 Update 场景 + daemon 恢复检查全部 PASS**，rc=0 |
| 原有 `lab.sh test` | **13 通过 / 0 失败 / 共 13 项**，rc=0；包括双向 UDP、进程异常、重启及撤路 |

新增 codec 检查包括：交错输入中的相同 distance 合并、0/7/255 的独立金样本、
255 个 distance 分组、单组 255 条网络以及同组后部非法网络的拒绝。
已有的校验和、截断、非对齐与随机报文检查全部保留。

独立原始报文对端输出：

```text
PASS learn non-default distance 9
PASS withdraw one net while learning another
PASS all-unreachable Update removes last route
PASS distance zero remains reachable
PASS empty Update still withdraws routes
PASS original daemons restored
```

这组测试直接检查 zebra RIB 的 metric 和内核路由。每个 Update 场景在两个 Poll
周期内完成断言，早于 `3 * poll` 的旧路由过期时间；不会把自动过期当成显式撤路成功。
混合场景要求旧网络消失且另一网络以 metric 7 同时出现。

## 复跑入口

在具备项目构建依赖的 Linux 环境中：

```sh
./scripts/verify.sh --build-only --protocols egp --jobs 4 --build-root /tmp/hr-rfc904
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -Iprotocols/egp/src protocols/egp/src/egp_packet.c \
  protocols/egp/tests/test_packet.c -o /tmp/test-egp-rfc904
/tmp/test-egp-rfc904
cd lab/egp
# 先在 lab.env 中指定本次安装前缀、兼容的运行镜像和独立实验资源名。
./lab.sh up
./lab.sh test-updates
./lab.sh test
./lab.sh down
```

本轮没有复测 x86_64、RPM 或 DEB，也不声称已完成 RFC 904 core gateway。
路由类型、显示码 G、管理距离 140、默认本地 network 的 distance 1 均保留。
