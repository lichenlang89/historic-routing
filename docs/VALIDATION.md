# 验收记录索引

以下链接固定到整理前的 Git 提交。报告内的相对链接可以继续打开同一提交中的日志和抓包。

- [EGP 重载、配置删除和多网关验收（#14）](https://github.com/lichenlang89/historic-routing/blob/50c81b1b7600e88a070ce86456325940fdbf5930/docs/plan/issue-14-handoff.md)
- [实际安装包服务与升级回退](https://github.com/lichenlang89/historic-routing/blob/50c81b1b7600e88a070ce86456325940fdbf5930/docs/evidence/package-service-20261031/README.md)
- [SELinux profile 与共享运行目录](https://github.com/lichenlang89/historic-routing/blob/50c81b1b7600e88a070ce86456325940fdbf5930/docs/evidence/selinux-package-20261031/README.md)
- [GateD 双向互通和撤路（#16）](https://github.com/lichenlang89/historic-routing/blob/50c81b1b7600e88a070ce86456325940fdbf5930/docs/evidence/issue16-interop/follow-up-20261107.md)
- [长期丢包乱序及多邻居压力（#16）](https://github.com/lichenlang89/historic-routing/blob/50c81b1b7600e88a070ce86456325940fdbf5930/docs/evidence/issue16-stress/README.md)
- [全部历史验收日志、抓包与报告](https://github.com/lichenlang89/historic-routing/tree/50c81b1b7600e88a070ce86456325940fdbf5930/docs/evidence)
- [已归档的验收计划](https://github.com/lichenlang89/historic-routing/tree/50c81b1b7600e88a070ce86456325940fdbf5930/docs/plan)
- [RHEL x86_64 与 Debian amd64 安装包实机验收（#22）](https://github.com/lichenlang89/historic-routing/pull/24)

`scripts/verify.sh` 会在 `docs/evidence/sys-admin-ab.txt` 记录能力 A/B 实验输出。
EGP 的源码和补丁校验仍由 `scripts/test-egp.sh` 执行。
