# PR #17：验收驱动审查修复（2026-10-31）

对应审查：[CRLF 原始字节恢复](https://github.com/lichenlang89/historic-routing/pull/17#discussion_r4428370171)、
[Zebra 自动启动漏检](https://github.com/lichenlang89/historic-routing/pull/17#discussion_r4428370182)。
旧 head `9d63c94`；本轮实际执行的驱动提交 `f33ce89`（源码哈希见
[driver-sources.sha256](driver-sources.sha256)）。本记录另存，不覆盖上轮历史证据。

## 修复

- CLI/日志仍用文本；配置使用 Node 的二进制 cat/tee 读写，不经 universal-newline
  解码。reload 保存/恢复 bytes；lifecycle 原始备份、追加标记、成对事务后的比较、
  finally 恢复与 SHA256 均使用 bytes。追加标记也保留原内容的尾部空白/换行。
- stop 和每次 install/downgrade 返回后，在显式 start 前逐个读取 egpd、Zebra 的
  ActiveState/MainPID。两者都须 inactive/0；拒绝 active、activating/PID=0，
  以及 inactive/PID 非零，并输出实际两个 unit 的属性。
- Linux 临时文件和真实 Node.run/cat/tee 验证两个 main 的成功/异常路径，
  独立 Path.read_bytes 比较 CRLF、LF、无末尾换行与尾部空白。
  包管理/systemd 使用受控替身，分别在升级/回退/再升级注入任一 unit 的三种坏状态。
  三个测试方法覆盖 26 个子用例；[旧版失败](before-fix.log)，[修复后全部通过](after-fix.log)。
  旧版失败来自实际换行变化或漏检/缺失服务诊断，不是缺少新 API 导致无法运行。
  此故障注入不是当前包已经发生自动启动故障的证据。
- `python3 -B packaging/test_driver_regressions.py` 纳入 native CI 两个架构，
  输出作为 `build/package-driver.log` 上传；不能代替真实包实验。

## 真实已安装包复测

用户指定的原两台 aarch64 主机，独占 namespace/container，原系统 FRR 不停止。
本轮只修改验收驱动及其回归；继续使用已有、版本/ABI 匹配的开发包，没有重打包或改协议。
包来源和 SHA256 沿用[上轮记录](../package-service-20261031/README.md)。

| 平台 | 已安装包与实际执行 | 结果 |
| --- | --- | --- |
| RHEL 10.2 aarch64 原生，SELinux Enforcing | RPM 00dcc4f 对 → bb070e0 对；成对升级/回退/再升级，然后全量实际 systemctl reload | [通过](rhel-installed.log)；每次事务后两个 unit inactive/0；4 个 CRLF 配置文件独立 SHA256 一致，原 FRR PID/配置恢复 |
| Debian 13.7 arm64/systemd 容器，Fedora 42 aarch64 宿主 | DEB 3dd0c63 对 → d098a0d 对；先全量实际 reload，再成对升级/回退/再升级 | [功能与字节校验通过](deb-installed.log)；每次事务后两个 unit inactive/0；3 个 CRLF 配置文件独立 SHA256 一致 |

均覆盖 network 增删/清空、AS/timers、错误配置与恢复；reload 保持 PID，
邻接、双向 RIB/内核路由恢复。CRLF 配置经真实已安装 vtysh 的 -C 语法检查。

RHEL 的 [before](rhel-crlf-before.sha256)、[after lifecycle](rhel-crlf-after-lifecycle.sha256)、
[after reload](rhel-crlf-after-reload.sha256) 字节一致；Debian 的
[before](deb-crlf-before.sha256)、[after reload](deb-crlf-after-reload.sha256)、
[after lifecycle](deb-crlf-after-lifecycle.sha256) 一致。
Debian 最终还用独立二进制读取验证每个文件的 CRLF 数量，egpd 初始 SHA 与独立构造的
合法五行 CRLF 配置匹配，见[清理/独立校验](cleanup.log)。

## 首次失败和清理

私有实验脚本首次改名时误改了本地镜像名，容器创建前 rc=125：
[初次 setup](deb-first-setup.log)。修正镜像名、加 --pull=never 后继续。

Debian 完整功能测试通过后，私有脚本漏记 owned 容器数组，自动清理没有执行，
容器清单比较因此使整次 wrapper **rc=1**；[原日志](deb-installed.log)保留这一结果，
不改记成 rc=0。已用开头记录的两个完整创建 ID 与 inspect 比较，确认均为本任务资源后
逐个停止本项目服务、停止/删除容器；最终独立核对宿主路由表、原容器清单和原 FRR 状态一致，
见[补清理结果](cleanup.log)。私有脚本后续版本已修正归属记录，未为此重复功能测试。

RHEL wrapper rc=0，原 FRR PID 不变、全部路由表字节一致，
Enforcing 保持，namespace/drop-in/peer 已清理；两个开发包 unit 最后 inactive。
未更改 SELinux 策略；受限域手动配置的验证继续以[上轮证据](../package-service-20261031/README.md)为准。

## 边界

检查的是事务返回后、显式 start 前的状态，不宣称审计了事务内所有短暂启动行为。
未重跑软件包构建或完整协议矩阵；协议和包内容未改，本轮针对驱动缺陷做真实包复测。
原 9d63c94 的 CI 已 6/6，通过不能覆盖当时驱动缺陷；新 head 的 CI 状态以 PR 检查为准。
Issue #14 保持开放，PR #17 不自动合并，不正式发布；SELinux 包管理集成等发布门禁仍保留。
公开日志脱敏私有工作路径/宿主名并规范行尾空白，原件保留执行环境。
