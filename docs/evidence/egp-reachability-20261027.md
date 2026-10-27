# RFC 904 可达性回归，2026-10-27

在 aarch64 / Fedora 42 用户态容器、RHEL 6.12 内核上从固定 FRR 基线全新构建。

- `verify.sh --build-only`：13 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL。
- 完整 `make check`：514 passed / 14 failed / 5 skipped，14 项仍是已知禁用模块缺少程序。
- 原有双路由器实验：13/13；Update 回归：5 个场景及恢复通过。
- 新原始报文回归（timers `1 1`）实测输出：

```text
PASS active stays Up using Update responses only
PASS stale responses do not renew reachability
PASS passive stays Up using Poll Up commands only
PASS passive four-T1 expiry
PASS protocol regressions and original daemon recovery
```

codec 单测另覆盖 T1 内去重、窗口精确到期、时间大幅跳跃和环形窗口复用。
后续 PR 将分别处理停止状态机、遗漏老化、主动 Update 和 CI；本 PR 不包含这些改动。
