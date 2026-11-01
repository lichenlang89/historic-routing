# FRR 完整 `make check` 的已知失败（自动生成）

> 本文件由 `scripts/parse-make-check.py` 从 `make check` 原始日志生成，**不要手工编辑**；重跑 `scripts/verify.sh` 会覆盖它。

- 原始结果：**14 failed / 514 passed / 5 skipped in 10.29s**，`make check` 退出码非 0（未伪装成通过）
- 本次 configure 关闭的模块：`isisd pimd`
- 判定口径：只看每个失败测试**自己的异常文本**是否指向被关闭模块的可执行文件；不按目录推断。

| # | 失败测试 | 直接证据（该测试的 E 行） | 分类 | 依据 |
| --- | --- | --- | --- | --- |
| 1 | `tests/isisd/test_fuzz_isis_tlv.py::TestFuzzIsisTLV::test_exit_cleanly` | `FileNotFoundError: [Errno 2] No such file or directory: 'isisd/test_fuzz_isis_tlv'` | KNOWN | 证据行指向 isisd/ 下的可执行文件，而 configure 用了 --disable-isisd |
| 2 | `tests/isisd/test_isis_lspdb.py::TestIsisLSPDB::test_exit_cleanly` | `FileNotFoundError: [Errno 2] No such file or directory: 'isisd/test_isis_lspdb'` | KNOWN | 证据行指向 isisd/ 下的可执行文件，而 configure 用了 --disable-isisd |
| 3 | `tests/isisd/test_isis_remove_excess_adjs.py::TestIsisRemoveExcessAdjs::test_exit_cleanly` | `FileNotFoundError: [Errno 2] No such file or directory: 'isisd/test_isis_remove_excess_adjs'` | KNOWN | 证据行指向 isisd/ 下的可执行文件，而 configure 用了 --disable-isisd |
| 4 | `tests/isisd/test_isis_spf.py::TestIsisSPF::test_refout` | `FileNotFoundError: [Errno 2] No such file or directory: 'isisd/test_isis_spf'` | KNOWN | 证据行指向 isisd/ 下的可执行文件，而 configure 用了 --disable-isisd |
| 5 | `tests/isisd/test_isis_tlv_ext_reach.py::TestIsisTlvExtReach::test_exit_cleanly` | `FileNotFoundError: [Errno 2] No such file or directory: 'isisd/test_isis_tlv_ext_reach'` | KNOWN | 证据行指向 isisd/ 下的可执行文件，而 configure 用了 --disable-isisd |
| 6 | `tests/isisd/test_isis_vertex_queue.py::TestIsisVertexQueue::test_exit_cleanly` | `FileNotFoundError: [Errno 2] No such file or directory: 'isisd/test_isis_vertex_queue'` | KNOWN | 证据行指向 isisd/ 下的可执行文件，而 configure 用了 --disable-isisd |
| 7 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_exit_cleanly` | `FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'` | KNOWN | 证据行指向 pimd/ 下的可执行文件，而 configure 用了 --disable-pimd |
| 8 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_sgrpt_prune_with_sg_join_OK` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |
| 9 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_sgrpt_prune_with_sg_join_and_prune_OK` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |
| 10 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_sgrpt_prune_split_records_OK` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |
| 11 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_sgrpt_prune_split_after_joins_OK` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |
| 12 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_sgrpt_prune_same_record_as_starg_join_OK` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |
| 13 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_sgrpt_prune_overflow_OK` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |
| 14 | `tests/pimd/test_pim_jp_encode.py::TestPimJpEncode::test_exit_cleanly_2` | `AttributeError: 'TestPimJpEncode' object has no attribute 'testresults'` | KNOWN | setup 级联：同组的 test_exit_cleanly 因缺少 pimd/test_pim_jp_encode 失败（FileNotFoundError: [Errno 2] No such file or directory: 'pimd/test_pim_jp_encode'） |

## 限制

1. 未做**对照构建**（另外编译一份 `--enable-isisd --enable-pimd` 的 FRR 来证明这些用例在启用后能通过）。因此这里的结论是「证据显示失败源于相应 daemon 未编译」，而不是「已证明与本项目补丁无关」。
2. 失败清单与上游 FRR `27f287be9` 的配置选择有关；换 configure 组合必须重跑本验证。
3. 完整日志在构建根的 `logs/verify-make-check.log`，`test-suite.log` 已一并保留。
