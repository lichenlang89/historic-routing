# S9：收口文档里写着的限制（计划与进度）

状态：S9.1 / S9.2 / S9.3 / S9.5 已完成并实测；S9.4 未执行（原因见下）。
PR：<https://github.com/lichenlang89/historic-routing/pull/13>，分支 `s9-limits-closure`。

## 范围与原因

`README.md` 与 `docs/FIDELITY.md` 里有几条"我们没做/做不到"的说明，长期挂着会让读者
把实现简化当成协议定义。本任务把它们逐条收口，或明确写成"有意不做"的原因。

| 子步 | 目标 | 状态 |
| --- | --- | --- |
| S9.1 | `show ip route egp` / `redistribute egp` 默认可用 | 完成 |
| S9.2 | 邻居与路由可观测（detail/json、计数、`clear … *`） | 完成 |
| S9.3 | Refuse（code 2）与 Error（type 8，reason 1–4） | 完成 |
| S9.4 | `doc/user/egp.rst` + man 页 | **未做**：构建镜像无 sphinx，宿主无 pip，`--network host` 容器里 `dnf install python3-sphinx` 也拿不到包，无法渲染验证 |
| S9.5 | frr-reload 回归 | 完成 |

## 需要保留的行为

- 配置文件语法不变：`egp local-as|timers|network|neighbor` 保持原样，已有 `frr.conf` 不需迁移。
- route type 32、显示码 `G`、管理距离 140、vtysh 位 `0x400000` 不变。
- 补丁应用顺序与 `PROTOCOL.meta` 登记顺序不变；`--with-optional` 仍可用于未来协议。
- 原有 23 条原始报文回归（邻接、可达性窗口、Cease 握手、遗漏老化、主动更新、定时器协商）必须继续通过。

## 涉及文件

- 补丁：`patches/frr/egp/0001`（并入 `lib/log.c`）、删除 `0005`、`patches/frr/SHA256SUMS`。
- 协议源码：`protocols/egp/src/{egpd.c,egp_packet.c,egp_packet.h}`、`protocols/egp/tests/test_packet.c`。
- 脚本与实验：`scripts/{apply-patches,build}.sh`、`lab/egp/{lab.sh,test_protocol.py,test_reload.py,test_lab.py}`。
- 文档：`README.md`、`protocols/egp/README.md`、`docs/{FIDELITY,ARCHITECTURE,HISTORY}.md`、
  `docs/evidence/s9-*`、`AGENTS.md`、`CHANGELOG.md`、`lab/README.md`。

## 验收测试（都在本机按 AGENTS.md 的清单跑过）

```sh
./scripts/verify.sh --build-only --build-root <work>/build --jobs 2   # PASS 13 / KNOWN-FAIL 1 / FAIL 0
cd lab/egp && ./lab.sh up && ./lab.sh test-updates && ./lab.sh test-protocol \
  && ./lab.sh test && ./lab.sh reload && ./lab.sh test-timers && ./lab.sh down
```

结果见 `docs/evidence/s9-20261030.md`、`docs/evidence/s9-20261030b.md` 与同目录日志
（日志里的工作目录已替换为 `<work>`，避免记录本机私有路径）。

## 关键决定

1. `lib/log.c` 的 `proto_redistnum` 映射并入 `0001`，不单独留 `0005`：路由类型和它的名字
   选择器是同一项能力；EGP 因此没有 `0005`，`--with-optional` 留给未来协议。
2. **Poll 不做超频判定**：RFC 904 §4.4 的"重复 Poll"是合法流程（第二次回复消耗主动更新
   预算）。最初实现照 A.5 reason 4 对 Poll 也判定，直接打断了既有 `unsolicited_updates()`。
3. 超频阈值取 `max(1, hello/2)` 秒；`hello/2` 在 `hello=1` 时为 0，会让断言永不触发。
4. `EGP_MAX_INTERVAL=3600`：起初写 86400，而 Hello/Poll 是 16 位字段，Refuse 永远不会触发。

## 失败证据（保留，不掩盖）

- 本轮三次 lab 迭代都是同一个测试失败被修掉：Poll 超频误判、`EGP_MAX_INTERVAL` 过大、
  `hello/2` 为 0。三次都保留了首次失败日志与原因，没有靠放宽断言通过。
- 其中"Poll 超频误判"是**既有回归在修复前确实失败**的例子：`unsolicited_updates()` 超时，
  修掉后通过。
- Error/Refuse 属于新增能力，没有"修复前失败"的对照可做，这一点在 PR 里也写明了。

## 未解决 / 下一步

- S9.4 需要 sphinx 环境（`dnf install python3-sphinx`）才能验证，未做。
- `make check` 的 14 项 isisd/pimd 已知失败未修（与 S6 相同）。
- S10（`router egp` 节点化）未开始；它是唯一的配置语法破坏性变更。
