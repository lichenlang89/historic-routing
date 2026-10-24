
## S5 集成测试日志

- `lab-test-20261024.log` —— 从提交 `fb2fc7e` 的干净导出在实验机上跑出的
  13/13 全通过日志（`./lab.sh up && ./lab.sh test`，随后 `./lab.sh down`）。
- `lab-test-altpath-20261024.log` —— 同一份代码、另一套参数（`egp-lab2-r*`、
  `198.18.124.0/24`、`/var/tmp/egp-lab2`）在另一个检出目录跑出的日志，同样 13/13。

两者都是脚本自己写出的运行记录（`$LAB_RUNDIR/logs/test-*.log`），未经手工编辑。
