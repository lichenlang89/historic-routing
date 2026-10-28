# Wireshark EGP 回归（2026-10-27）

## 范围

将已有的 EGP Lua 插件纳入 `wireshark/`，按 RFC 904 Appendix A 修正字段解释。
守护进程、FRR 补丁和已发布附件未改动。

## 本地验证

- Windows x64，TShark 4.6.9（Lua 5.4.6），Python 3。
- 执行 `python wireshark/test_dissector.py --tshark <tshark路径>`：
  `Wireshark EGP: 51 wire fixtures passed; no Lua errors`。
- 输入由独立的 Python 标准库编码器生成，不调用守护进程编码器。
  覆盖 Acquisition 五种 Code、Hello/I-H-U、Poll、Update 内外网关和 A/B/C 类地址、
  距离 0/7/255、unsolicited、Error 12 字节引用、坏校验和、snaplen 截断、
  Update 每个不完整前缀和非法网络类别。
- 测试使用临时 Wireshark 配置和插件目录；已安装插件的 SHA256 在前后相同：
  `58f4eb17b9c7452c260ba6433379dfeb2631509fdeb4bb79ca552dd1c1f65357`。
- `git diff --check` 通过。

Linux 的实际 TShark 版本、同一套报文及插件 ZIP 回读结果由
`.github/workflows/wireshark.yml` 的 PR 检查保存；本记录不预报 CI 结果。

这组测试验证解析行为，不代表与其它历史路由器的互通认证。
