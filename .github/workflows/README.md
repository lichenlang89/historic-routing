# .github/workflows/

`ci.yml` 在 PR、main 推送及手动触发时运行原生 amd64 / arm64 两个平台。
工具链与运行镜像都使用 Fedora 43 用户态；编译固定的 FRR 提交，不使用旧二进制。

每个平台执行：源码/补丁哈希、资源分配、codec ASan/UBSan、完整 build/verify、
独立 Update 报文回归与双路由器实验。如果分支含 `test_protocol.py`，也执行其 RFC 回归。
完整 make check 保留原始退出码，并通过 verify 的归因器判断已知失败；不放宽测试断言。

Podman 使用临时 GitHub runner 的 root 权限，仅实验容器增加所需能力。
仓库令牌仅 contents:read，checkout 不保存凭据，无 self-hosted runner 或私网依赖。
所有日志与 JSON 验证结果以 14 天 artifact 保留；失败时同样收集证据并清理实验。
