#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""frr-reload 回归：PID 保持，network 无损，全局变更按序重建邻接。

用例（都在实验里真跑）：
  1. 在完整运行配置后追加一条 `egp network`，用 frr-reload.py --reload 应用：
     对端在超时内学到该网络，egpd 的 pid 不变，两端邻居仍是 Up，原有网络不丢。
  2. 同一份配置再重载一次：frr-reload 报无变化，pid 不变，状态不变。
  3. 恢复原配置：只有新增的那条网络被撤掉。
  4. 完整清空、默认值、AS/timers 变更、CLI 约束、错误返回及恢复。
  5. 执行 RPM/DEB 原模板的 ExecReload 命令（不等同于包安装/systemd 验收）。

实验里的注意事项（都是实测出来的）：
  * frr-reload.py 在 `sbin/`，且必须给 --bindir/--confdir，否则它以 /usr/bin、
    /etc/frr 为默认值直接报 "not a valid path"；
  * 它要在 rundir 下写临时文件，默认 /var/run/frr 不存在，需先建；
  * 配置要按**完整**运行配置喂进去；只喂 `egp` 行会让它把 hostname 等行判成待删。

由 `lab.sh reload` 调用；需要先 `lab.sh up`。
"""
import sys

import test_lab as lab
from test_service_reload import check_templates

EXTRA = "192.168.0.0"
EXTRA_CIDR = "192.168.0.0/24"
WORK = "/tmp/run"
CONF = WORK + "/reload.conf"
PREFIX = "/build/prefix"
# 前缀是只读挂载（lab.sh 用 :ro），所以 frr-reload 的 confdir 必须落在可写目录；
# rundir 默认值的 /var/run/frr 也需要先建。
CONF_DIR = WORK
ENV = ("PATH=%s/bin:%s/sbin:$PATH LD_LIBRARY_PATH=%s/lib:%s/lib/frr"
       % (PREFIX, PREFIX, PREFIX, PREFIX))
RELOAD = ("%s %s/sbin/frr-reload.py --reload --daemon egpd --bindir %s/bin --confdir %s "
          "--rundir %s --vty_socket %s %s; echo RC=$?"
          % (ENV, PREFIX, PREFIX, CONF_DIR, WORK, WORK, CONF))


def running_config(node):
    """完整运行配置；去掉 vtysh 横幅、缺失文件告警和结尾的 end。"""
    text = lab.vty(node, "egpd", "show running-config")
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("%"):
            continue
        if stripped.startswith("Building configuration") or stripped.startswith("Current configuration"):
            continue
        if stripped == "end":
            continue
        lines.append(line.rstrip())
    return lines


def write_conf(node, lines):
    lab.rsh(node, "sh", "-c",
            "mkdir -p /var/run/frr %s; cat > %s <<'EOF'\n%s\nEOF"
            % (WORK, CONF, "\n".join(lines)))


def reload(node):
    """跑一次 frr-reload，返回 (rc, 去掉 RC= 行的输出)。"""
    out = lab.rsh(node, "sh", "-c", RELOAD, check=False)
    rc, lines = None, []
    for line in out.splitlines():
        if line.startswith("RC="):
            rc = int(line[3:] or -1)
        else:
            lines.append(line)
    return rc, "\n".join(lines)


def egpd_pid(node):
    return lab.rsh(node, "cat", "/tmp/run/egpd.pid").strip()


def restore(base, failure):
    """任何退出路径都把运行配置还原；恢复自身失败时打印，且在没有原始异常时才抛出。"""
    try:
        if running_config(lab.R1) == base:
            return
        write_conf(lab.R1, base)
        rc, out = reload(lab.R1)
        if rc != 0:
            raise RuntimeError("恢复重载 rc=%s：%s" % (rc, out))
        lab.wait("恢复原配置", lambda: running_config(lab.R1) == base, timeout=30)
        print("PASS 失败路径已恢复原配置", flush=True)
    except Exception as exc:  # noqa: BLE001 - 恢复失败不能掩盖最初的异常
        print("FAIL 恢复原配置：%s" % exc, flush=True)
        if failure is None:
            raise


def main():
    lab.wait("reload 前置：双方 Up 且双向路由齐备",
             lambda: lab.both_up() and lab.both_routes(), timeout=60)
    base = running_config(lab.R1)
    if not base:
        raise AssertionError("读不到 egpd 的运行配置")
    pid = egpd_pid(lab.R1)
    failure = None
    try:
        steps(base, pid)
        check_templates(base, pid)
    except BaseException as exc:
        failure = exc
        raise
    finally:
        restore(base, failure)
    return 0


def steps(base, pid):
    # 1) 追加一条 network 并重载
    write_conf(lab.R1, base + ["egp network " + EXTRA])
    rc, out = reload(lab.R1)
    if rc != 0:
        raise AssertionError("重载失败 rc=%s：\n%s" % (rc, out))
    if egpd_pid(lab.R1) != pid:
        raise AssertionError("重载重启了 egpd（pid %s -> %s）\n%s" % (pid, egpd_pid(lab.R1), out))
    try:
        lab.wait("对端学到新增的 " + EXTRA_CIDR,
                 lambda: bool(lab.egp_route(lab.R2, EXTRA_CIDR)), timeout=40)
    except AssertionError as exc:
        raise AssertionError("%s\nfrr-reload 输出:\n%s" % (exc, out)) from exc
    if "Up" not in lab.neighbors(lab.R1) or "Up" not in lab.neighbors(lab.R2):
        raise AssertionError("重载后邻居不是 Up")
    if not lab.egp_route(lab.R2, lab.NET1_CIDR):
        raise AssertionError("重载把原有的 %s 丢了" % lab.NET1_CIDR)
    print("PASS 重载新增一条 network：egpd pid 不变、邻居不抖、原有路由保留", flush=True)

    # 2) 同一份配置再重载：必须无变化
    rc, again = reload(lab.R1)
    low = again.lower()
    if rc != 0:
        raise AssertionError("二次重载失败 rc=%s：\n%s" % (rc, again))
    if not ("no configuration change" in low or "nothing" in low or not again.strip()):
        raise AssertionError("同配置二次重载不幂等：\n%s" % again)
    if egpd_pid(lab.R1) != pid:
        raise AssertionError("二次重载重启了 egpd")
    if not lab.egp_route(lab.R2, EXTRA_CIDR):
        raise AssertionError("二次重载把新增网络弄丢了")
    print("PASS 同配置二次重载幂等（frr-reload 报无变化，pid 不变）", flush=True)

    # 3) 恢复原配置：只撤掉新增的那条
    write_conf(lab.R1, base)
    rc, out = reload(lab.R1)
    if rc != 0:
        raise AssertionError("恢复重载失败 rc=%s：\n%s" % (rc, out))
    if egpd_pid(lab.R1) != pid:
        raise AssertionError("恢复重载重启了 egpd\n%s" % out)
    lab.wait("撤掉新增的 " + EXTRA_CIDR,
             lambda: not lab.egp_route(lab.R2, EXTRA_CIDR), timeout=40)
    if not lab.egp_route(lab.R2, lab.NET1_CIDR):
        raise AssertionError("恢复后原有 %s 没回来" % lab.NET1_CIDR)
    if "Up" not in lab.neighbors(lab.R1):
        raise AssertionError("恢复后邻居不是 Up")
    print("PASS 恢复原配置：只撤掉新增网络，原路由与邻居保持", flush=True)

    # Syntax errors must fail before a single running command is deleted.
    write_conf(lab.R1, base + ["egp timers 0 1"])
    rc, out = reload(lab.R1)
    assert rc != 0 and out.strip(), (rc, out)
    assert running_config(lab.R1) == base
    assert egpd_pid(lab.R1) == pid and lab.both_up() and lab.both_routes()
    print("PASS 语法错误返回非零与诊断，运行配置和原路由保持", flush=True)

    # CLI global changes are guarded; reload performs the ordered teardown.
    for cmd in ("no egp local-as", "no egp timers"):
        try:
            lab.vty(lab.R1, "egpd", "configure terminal", cmd)
        except RuntimeError as exc:
            assert "Remove neighbors" in str(exc), str(exc)
        else:
            raise AssertionError("有邻居时应拒绝 " + cmd)
    assert running_config(lab.R1) == base
    print("PASS 有邻居时直接删除 AS/timers 被拒绝", flush=True)

    empty = [line for line in base if not line.startswith("egp ")]
    write_conf(lab.R1, empty)
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    assert not any(line.startswith("egp ") for line in running_config(lab.R1))
    assert "local AS 0" in lab.neighbors(lab.R1)
    assert not lab.has_kernel(lab.R1, lab.NET2_CIDR)
    assert egpd_pid(lab.R1) == pid
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    # Both bare and value-bearing reset forms are idempotent.
    lab.vty(lab.R1, "egpd", "configure terminal", "no egp local-as",
            "no egp local-as 65001", "no egp timers", "no egp timers 1 1")
    print("PASS 全量清空及重复应用：AS=0、默认 timers、无残留配置或路由", flush=True)

    write_conf(lab.R1, base)
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    lab.wait("清空后恢复", lambda: lab.both_up() and lab.both_routes(), timeout=60)

    # A timer change with an unchanged neighbor needs delete/wait/re-add.
    changed = ["egp timers 2 1" if line.startswith("egp timers ") else line
               for line in base]
    write_conf(lab.R1, changed)
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    assert "egp timers 2 1" in running_config(lab.R1)
    lab.wait("新 timers 下邻居和路由恢复", lambda: lab.both_up() and lab.both_routes(), timeout=60)
    assert egpd_pid(lab.R1) == pid
    print("PASS timers 变更按序重建邻接，egpd PID 保持", flush=True)

    # AS change is accepted without a process restart. The remote still
    # expects the old AS; recovery below reapplies the original config.
    changed = ["egp local-as 65003" if line.startswith("egp local-as ") else line
               for line in base]
    write_conf(lab.R1, changed)
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    assert "egp local-as 65003" in running_config(lab.R1)
    assert egpd_pid(lab.R1) == pid
    print("PASS AS 变更按序应用，egpd PID 保持", flush=True)

    write_conf(lab.R1, base)
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    lab.wait("AS/timers 恢复", lambda: lab.both_up() and lab.both_routes(), timeout=60)

    # A semantic error can occur after deletions: FRR reload is best effort.
    bad = [line.replace("remote-as " + lab.AS2, "remote-as " + lab.AS1)
           if line.startswith("egp neighbor ") else line for line in base]
    write_conf(lab.R1, bad)
    rc, out = reload(lab.R1)
    assert rc != 0 and "Failed to apply EGP" in out and "remote-as" in out, (rc, out)
    write_conf(lab.R1, base)
    rc, out = reload(lab.R1)
    assert rc == 0, (rc, out)
    lab.wait("语义失败后恢复", lambda: lab.both_up() and lab.both_routes(), timeout=60)
    assert egpd_pid(lab.R1) == pid
    print("PASS 语义错误返回非零，重载原配置后恢复邻接与双向路由", flush=True)


if __name__ == "__main__":
    sys.exit(main())
