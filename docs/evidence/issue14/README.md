# Issue #14 执行证据

基线 `8ae604e` 加本 PR 修改，RHEL 系 aarch64 / Linux 6.12 / rootful Podman。
日期：2026-10-30 至 2026-10-31（Asia/Shanghai）；lab 日志的 Z 时间为 UTC。

- `baseline.log`：修复前的混合网关、255/256 容量、HUP 和全量配置删除对照。
- `lab-first.log`：首次修复后实验；语义失败诊断断言失败，保留首次失败。
- `lab-second.log`：修正诊断后全部协议/重载/慢定时器及 13/13 转发/恢复检查。
- `reload-final.log`：最终组合 `lab.sh reload`，含两模板 ExecReload 实际命令。
- `templates.log`：最终安装前缀上独立执行两模板的等价命令；不代表 systemd/包安装通过。
- `finalbuild.log`：`scripts/test-egp.sh` 和最终 `verify.sh --build-only --jobs 2`，
  构建使用固定 FRR 提交的本地镜像；未跳过 check/dist。完整 make check 逐条证据在
  `docs/known-failures.md`，原始构建/pytest 日志仍保留于执行环境。
- `final-doc-html.log`：Sphinx 7.4.7 用户手册构建警告，19 条都不来自 EGP。
- `final-doc-man.log`：最终集成树 `python3 -m sphinx -b man -W` 成功生成 `frr-egpd.8`。
- `systemd-attempts.log`：宿主 systemd + 独占容器命名空间的失败诊断摘录；非包安装验证。
- `binary-hashes.txt`：最终产物哈希；与实际运行回归所用同树产物逐项一致。

运行入口：`scripts/test-egp.sh`、`scripts/verify.sh --build-only`、`lab/egp/lab.sh`
的 `test-updates` / `test-protocol` / `reload` / `test-timers` / `test`。
Sphinx 输入为最终集成树的 `doc/user`、`doc/manpages`，HTML 使用 `-b html`，man 使用 `-b man -W`；
`make dist` 已确认包含两份 EGP RST。
完整结果、命令和未验证项见 `docs/plan/issue-14-handoff.md`。

公开日志只替换个人工作路径/主机名并去除行尾空格，不改变结果或失败信息。
完整原始日志和专用实验脚本保存在执行环境，未发布 SSH 信息或凭据。
