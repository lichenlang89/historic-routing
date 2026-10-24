#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""解析 FRR 完整 `make check` 日志，产出逐条失败证据并分类。

为什么要单独一个解析器：`make check` 的失败归因不能只看"失败发生在哪个目录"。
这里对每个失败测试提取它在 pytest 失败块里的 `E` 行（真正的异常文本），
只有当**异常文本本身**指向一个被 `--disable-<daemon>` 关掉的模块的可执行文件时，
才判为 KNOWN（已知、有证据）；其余一律 UNCLASSIFIED，交给 verify.sh 判 FAIL。

用法：
  parse-make-check.py <make-check.log> <out.tsv> <out.md> [disabled-daemon ...]

输出：
  TSV:  <KNOWN|UNCLASSIFIED>\t<nodeid>\t<证据行>
  MD :  给人看的表格（含原始 rc/统计与限制说明）
退出码：
  0  解析完成（无论是否有 UNCLASSIFIED；判定由调用方做）
  2  输入不可读或日志里没有任何 FAILED 行但退出码非零（说明解析失败）
"""

import re
import sys

HEADER_RE = re.compile(r"^_{4,}\s+(.+?)\s+_{4,}$")
SUM_RE = re.compile(r"^=+\s+(\d+) failed.*?(\d+) passed.*?(\d+) skipped.*?in\s+([0-9.]+)s")


def load(path):
    with open(path, errors="replace") as f:
        return f.read().splitlines()


def nodeid_key(nodeid):
    """把 pytest nodeid 变成失败块标题里会出现的形式。

    tests/isisd/test_isis_lspdb.py::TestIsisLSPDB::test_exit_cleanly
      -> TestIsisLSPDB.test_exit_cleanly
    """
    parts = nodeid.split("::")
    if len(parts) >= 3:
        return "%s.%s" % (parts[-2], parts[-1])
    if len(parts) == 2:
        return parts[-1]
    return nodeid


def collect_blocks(lines):
    """返回 {标题: [错误行, ...]}，错误行取块内以 'E   ' 开头的行。"""
    blocks = {}
    cur = None
    for line in lines:
        m = HEADER_RE.match(line)
        if m:
            cur = m.group(1).strip()
            blocks.setdefault(cur, [])
            continue
        if line.startswith(("=======", "------------")):
            cur = None
            continue
        if cur is not None and line.startswith("E "):
            blocks[cur].append(line[1:].strip())
        elif cur is not None and line.startswith("E\t"):
            blocks[cur].append(line[1:].strip())
    return blocks


def evidence_for(nodeid, blocks):
    key = nodeid_key(nodeid)
    if key in blocks and blocks[key]:
        return blocks[key][-1]
    # 退化匹配：标题里包含 key 的最后一个分量
    tail = key.split(".")[-1]
    for title, errs in blocks.items():
        if title.endswith(tail) and errs:
            return errs[-1]
    return ""


DISABLED_ARTIFACT_RE = re.compile(r"No such file or directory: '([A-Za-z0-9_.+-]+)/")
NAME_IN_ERROR_RE = re.compile(r"(?<![A-Za-z0-9_])([a-z0-9]+d)/[A-Za-z0-9_.+-]*")


def classify(nodeid, err, disabled):
    """KNOWN 当且仅当证据行指向被 --disable 的模块的可执行文件。"""
    if not err:
        return "UNCLASSIFIED", "日志里找不到该测试的失败块（无直接证据）"
    if "egpd" in nodeid or "/egpd/" in nodeid:
        return "UNCLASSIFIED", "失败发生在 EGP 自己的测试里"
    dirs = set()
    m = DISABLED_ARTIFACT_RE.search(err)
    if m:
        dirs.add(m.group(1))
    for m in NAME_IN_ERROR_RE.finditer(err):
        dirs.add(m.group(1))
    for d in sorted(dirs):
        if d in disabled:
            return "KNOWN", "证据行指向 %s/ 下的可执行文件，而 configure 用了 --disable-%s" % (d, d)
    if "FileNotFoundError" in err and not dirs:
        return "UNCLASSIFIED", "FileNotFoundError 但无法确定属于被禁用的模块"
    return "UNCLASSIFIED", "证据行未指向任何被 --disable 的模块"


def group_key(nodeid):
    """同一测试文件里的同一个类（用于识别 setup 级联失败）。"""
    parts = nodeid.split("::")
    return "::".join(parts[:-1])


def reconcile_cascade(rows, disabled):
    """把 setup 级联失败也判为 KNOWN —— 但必须有同组直接证据。

    pimd/test_pim_jp_encode 缺可执行文件时，setUpClass 里拿不到 testresults，
    同文件其余用例会报 `AttributeError: ... object has no attribute 'testresults'`。
    只这一类（AttributeError + 同组存在"缺被禁用模块可执行文件"的直接证据）才认。
    """
    direct = {}
    for status, nodeid, err, why in rows:
        if status == "KNOWN" and "No such file" in err:
            direct.setdefault(group_key(nodeid), (nodeid, err))
    out = []
    for status, nodeid, err, why in rows:
        if status == "UNCLASSIFIED" and "AttributeError" in err:
            anchor = direct.get(group_key(nodeid))
            if anchor:
                out.append(("KNOWN", nodeid, err,
                            "setup 级联：同组的 %s 因缺少 %s 失败（%s）"
                            % (anchor[0].split("::")[-1], anchor[1].split("'")[-2], anchor[1])))
                continue
        out.append((status, nodeid, err, why))
    return out


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    log_path, tsv_path, md_path = argv[1], argv[2], argv[3]
    disabled = argv[4:]

    try:
        lines = load(log_path)
    except OSError as exc:
        print("无法读取 %s: %s" % (log_path, exc), file=sys.stderr)
        return 2

    failed = [ln.split(None, 1)[1].strip() for ln in lines if ln.startswith("FAILED ")]
    blocks = collect_blocks(lines)
    m = None
    for line in lines:
        mm = SUM_RE.match(line)
        if mm:
            m = mm
    summary = ("%s failed / %s passed / %s skipped in %ss" % m.groups()) if m else "未解析到 pytest 统计行"

    if not failed:
        print("日志里没有 FAILED 行（summary: %s）" % summary, file=sys.stderr)
        return 2

    rows = []
    for nodeid in failed:
        err = evidence_for(nodeid, blocks)
        status, why = classify(nodeid, err, disabled)
        rows.append((status, nodeid, err or "(无)", why))
    rows = reconcile_cascade(rows, disabled)

    with open(tsv_path, "w", encoding="utf-8") as f:
        for status, nodeid, err, _why in rows:
            f.write("%s\t%s\t%s\n" % (status, nodeid, err.replace("\t", " ")))

    known = sum(1 for r in rows if r[0] == "KNOWN")
    unclassified = len(rows) - known
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# FRR 完整 `make check` 的已知失败（自动生成）\n\n")
        f.write("> 本文件由 `scripts/parse-make-check.py` 从 `make check` 原始日志生成，"
                "**不要手工编辑**；重跑 `scripts/verify.sh` 会覆盖它。\n\n")
        f.write("- 原始结果：**%s**，`make check` 退出码非 0（未伪装成通过）\n" % summary)
        f.write("- 本次 configure 关闭的模块：`%s`\n" % (" ".join(disabled) or "(无)"))
        f.write("- 判定口径：只看每个失败测试**自己的异常文本**是否指向被关闭模块的可执行文件；"
                "不按目录推断。\n\n")
        f.write("| # | 失败测试 | 直接证据（该测试的 E 行） | 分类 | 依据 |\n")
        f.write("| --- | --- | --- | --- | --- |\n")
        for i, (status, nodeid, err, why) in enumerate(rows, 1):
            f.write("| %d | `%s` | `%s` | %s | %s |\n"
                    % (i, nodeid.replace("../../frr-src/", ""), err.replace("|", "\\|"), status, why))
        f.write("\n## 限制\n\n")
        f.write("1. 未做**对照构建**（另外编译一份 `--enable-isisd --enable-pimd` 的 FRR 来证明这些用例"
                "在启用后能通过）。因此这里的结论是「证据显示失败源于相应 daemon 未编译」，"
                "而不是「已证明与本项目补丁无关」。\n")
        f.write("2. 失败清单与上游 FRR `27f287be9` 的配置选择有关；换 configure 组合必须重跑本验证。\n")
        f.write("3. 完整日志在构建根的 `logs/verify-make-check.log`，`test-suite.log` 已一并保留。\n")

    print("%d 项失败：KNOWN=%d UNCLASSIFIED=%d（%s）" % (len(rows), known, unclassified, summary))
    for status, nodeid, err, why in rows:
        print("  [%s] %s :: %s" % (status, nodeid.replace("../../frr-src/", ""), err))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
