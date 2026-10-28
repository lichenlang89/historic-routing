# RFC 904 控制状态回归，2026-10-27

基于可达性 PR，全新 aarch64/Fedora 42 构建：verify 为
13 PASS / 1 KNOWN-FAIL / 0 SKIP / 0 FAIL。完整 make check 为
514 passed / 14 failed / 5 skipped，失败归因仍为已禁用的 isisd/pimd。

原有双路由器实验 13/13、Update 回归和可达性回归全部通过。
独立原始报文对端另验证：

```text
PASS Refuse stops acquisition
PASS repeated Cease is acknowledged in Idle
PASS wrong Cease-ack leaves teardown pending
PASS Cease retransmits with the same sequence after P3
PASS matching Cease-ack releases resources
PASS protocol regressions and original daemon recovery
```

重传实测等待完整 P3=30 秒，不通过缩短协议定时器替代。
P5 abort 的到期前/到期点以及控制状态转换由可控时钟单测覆盖。
此处不声称执行过长达一小时的 P4 实时等待测试。
