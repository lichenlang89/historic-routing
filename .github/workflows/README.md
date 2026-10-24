# .github/workflows/

CI 尚未建立。本轮（S0–S3）只做本地操作，没有远端仓库，也没有任何 workflow 在运行。

S4 之后计划加入：

- `ci.yml`：矩阵（RHEL / Fedora 容器 × 固定的 FRR 基线），跑 `scripts/build.sh` + `make check`
- 单元测试（`egpd/test_packet`）作为必过门禁
- lab 集成测试（Podman）作为可选项，允许手动触发

在此之前，**不要**在这里放看起来像在运行但实际上没有验证过的 workflow。
