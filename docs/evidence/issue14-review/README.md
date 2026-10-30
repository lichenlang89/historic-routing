# PR #15 默认 VRF 本机地址检查：评审增补证据

日期：2026-10-31（Asia/Shanghai）。基线为 `c651234` 加本轮工作树修改。
RHEL 系 aarch64 / Linux 6.12 / rootful Podman，固定 FRR 基线和匹配工具链。

- `baseline.log`：用 c651234 的已核对产物运行新增 loopback 回归，
  因错误 Update 被接受而缺少 Error 响应失败；记录错误候选和 `via <alias> dev lo` 内核路由。
- `build.log`：`scripts/test-egp.sh` 与完整 `verify.sh --build-only --jobs 2`，
  PASS 13 / KNOWN-FAIL 1 / FAIL 0。14 项已禁用 isisd/pimd 的缺产物失败保留 rc=2；
  逐条直接异常见 `docs/known-failures.md`，未按失败数量放行。
- `lab.log`：`lab.sh up` → `test-updates` → `test-protocol` → `test` → finally `down`。
  包含动态添加的 loopback /32、eth0 /24 secondary，原子拒绝、遗漏计数和同一 Poll 上两种
  接收额度保持，删除地址后接受第三方网关，原状态机/多网关/错误窗口回归和 13/13 转发恢复。
- `binary-hashes.txt`：本轮源码重新构建的匹配产物；源码哈希在 SOURCES.sha256。

完整原始日志、构建日志与专用实验参数保留于执行环境。公开日志仅替换私有工作路径并去除行尾空格。
本轮未重复慢定时器、包安装、systemd/SELinux 或 TShark，不能将首轮记录算作新一轮执行。
