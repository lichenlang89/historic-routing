# lab/

实验环境。每个协议一个子目录。

| 目录 | 说明 | 状态 |
| --- | --- | --- |
| `egp/` | 双路由器 EGP 实验：`lab.sh`（up/down/status/vty）、`test_lab.py`（11 项集成检查） | 脚本已从原 fork 迁入（S3），**仍带硬编码路径，S5 才参数化** |

S5 要补：

- `Containerfile`：运行期依赖镜像（当前依赖一个仓库里不存在的私有镜像 `localhost/frr-23837-base:20261022`）
- `lab.env`：`PREFIX` / `IMAGE` / 地址规划集中配置
- 参数化 `lab.sh` 与 `test_lab.py` 中写死的 `/build/prefix` 与 `PREFIX` 默认值
- 一台没装过 FRR 的干净机器上的验收记录
