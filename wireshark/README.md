# Wireshark 协议解析器

这里保存与守护进程一起维护的 Wireshark Lua 插件。目前提供 EGP v2
（[RFC 904](https://www.rfc-editor.org/rfc/rfc904.html)）；它注册到 IPv4 协议号 **8**。
未来的 GGP、HELLO 解析器也放在本目录，目前尚未实现。

## 安装

支持目标为启用 Lua 的 Wireshark / TShark **4.0 或更新版本**。
本地已验证 Windows 4.6.9；Linux 的实际版本和测试结果见 CI。

1. 在 Wireshark 的“帮助 → 关于 Wireshark → 文件夹”中找到 **Personal Lua Plugins**。
   也可以运行 `tshark -G folders` 查看；不要误用带版本号的二进制插件目录。
   Windows 默认位置为 `%APPDATA%\Wireshark\plugins`。
2. 将 `egp_dissector.lua` 复制到该目录，然后重启 Wireshark。
3. 打开实验抓包，用 `egp_custom` 过滤。协议列表显示为 EGP。

只需复制 Lua 文件，Python 测试脚本不需要安装。更新时替换原文件；
不要同时安装多个副本，或把已安装的副本再用 `-X lua_script:...` 加载一次。
插件路径和加载规则见 [Wireshark Lua 手册](https://www.wireshark.org/docs/wsdg_html_chunked/wsluarm.html)。

## 字段与边界

| 过滤字段 | 含义 |
| --- | --- |
| `egp_custom.status` | 原始状态字节，保留数值过滤兼容性 |
| `egp_custom.mode` / `egp_custom.cause` | Acquisition 的能力 / 原因，按 Code 区分 |
| `egp_custom.state` | Hello、I-H-U、Poll、Update、Error 的可达状态 |
| `egp_custom.unsolicited` | Update / Error 的最高状态位 |
| `egp_custom.distance` / `egp_custom.network` | 按网关和距离分组的 classful 网络；255 显示为不可达 |
| `egp_custom.bad_header` | Error 引用的原始报文前 12 字节 |
| `egp_custom.checksum_valid` | 对完整捕获的 EGP 载荷校验；捕获被 snaplen 截断时不产生此字段 |
| `egp_custom.warning` | 截断、未知版本等解析提示 |

解析器处理边界检查并提供 Expert Info；它用于观察报文字段，不执行邻居状态机，
也不替代守护进程的接收合法性检查。保留未知值和尾随字节以便排错。

## 离线回归

要求 Python 3.9+ 和启用 Lua 的 TShark，不需要抓包权限或网络接口：

```sh
python3 wireshark/test_dissector.py --tshark tshark
```

Windows 可以使用 `python wireshark/test_dissector.py --tshark "C:\Program Files\Wireshark\tshark.exe"`，
并按实际安装位置调整路径。脚本生成临时报文，检查真实的 TShark 字段输出及 Lua 错误，
覆盖五种 Acquisition Code、可达性、Poll、内外部网关、A/B/C 类网络、距离分组、
Error 引用、坏校验和、抓包截断及逐字节截断 Update。
测试子进程通过临时 `WIRESHARK_CONFIG_DIR` / `WIRESHARK_PLUGIN_DIR` 隔离已安装插件，
不会改写用户配置或使用个人抓包。

## 分发

`scripts/release-source.sh` 使用 `git archive HEAD`，因此未来源码压缩包会包含本目录。
也可以从准备发布的提交生成独立插件 ZIP，与同一提交的 RPM/DEB 并列上传：

```sh
git archive --format=zip --prefix=historic-routing-wireshark/ \
  --output=historic-routing-wireshark.zip HEAD wireshark LICENSE
sha256sum historic-routing-wireshark.zip
```

请在发布记录中保存实际提交和 SHA256；不要把工作目录中未提交的插件混入发布。
现有 v0.1.0 / v0.1.1 发布附件保持原样。

本目录遵循仓库的 GPL-2.0-or-later 许可。
