# RFC 904 主动 Update 回归，2026-10-27

全新 aarch64/Fedora 42 构建：verify 为
13 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL。14 项已知上游失败未变。
codec、可达性、控制状态、老化与序列号/预算单测在 ASan/UBSan 下通过。

原始报文对端协商 Hello=1s、Poll=10s，以逐包观察一个完整区间：

```text
PASS unsolicited wrong sequence rejected
PASS second unsolicited Update in one Poll window rejected
PASS unsolicited does not consume the solicited response
PASS new Poll renews unsolicited receive budget
PASS network change emits unsolicited Update using last command sequence
PASS transmit budget survives duplicate Poll
PASS new Poll renews unsolicited transmit budget
```

测试结束时重新获取邻接，恢复实验配置的 1/1 周期，随后运行既有 Update 与双路由器回归。
首次串行回归曾因遗漏重新协商恢复而继续使用 10 秒 Poll，触发旧测试的 2 秒时限；
修复了测试恢复步骤，保留原时限断言，从干净实验重跑。
重跑结果：完整协议回归通过，Update 的五个场景及恢复通过，原有双路由器实验
13/13；恢复步骤与获取确认的事件顺序另做一次主动更新定向复核，全部通过。
最后再执行 build-only 门禁，仍为 13 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL。

四个协议 PR 的 daemon 验证平台为 aarch64；不声称已复测 x86 安装包。
独立 CI PR 的 amd64/arm64 全量构建与实验均成功：
[运行 40491743437](https://github.com/lichenlang89/historic-routing/actions/runs/40491743437)。
该 CI PR 基于 main，协议增量仍以各自本地构建和报文证据为准。
