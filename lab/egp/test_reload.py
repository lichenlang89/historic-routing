#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""frr-reload 回归：重载 egpd 配置不得重启进程、不得抖动邻居，且必须幂等。

用例（都在实验里真跑）：
  1. 在完整运行配置后追加一条 `egp network`，用 frr-reload.py --reload 应用：
     对端在超时内学到该网络，egpd 的 pid 不变，两端邻居仍是 Up，原有网络不丢。
  2. 同一份配置再重载一次：frr-reload 报无变化，pid 不变，状态不变。
  3. 恢复原配置：只有新增的那条网络被撤掉。

实验里的注意事项（都是实测出来的）：
  * frr-reload.py 在 `sbin/`，且必须给 --bindir/--confdir，否则它以 /usr/bin、
    /etc/frr 为默认值直接报 "not a valid path"；
  * 它要在 rundir 下写临时文件，默认 /var/run/frr 不存在，需先建；
  * 配置要按**完整**运行配置喂进去；只喂 `egp` 行会让它把 hostname 等行判成待删。

由 `lab.sh reload` 调用；需要先 `lab.sh up`。
"""
import sys

import test_lab as lab

EXTRA = "192.168.0.0"
EXTRA_CIDR = "192.168.0.0/24"
CONF = "/tmp/run/reload.conf"
PREFIX = "/build/prefix"
ENV = ("PATH=%s/bin:%s/sbin:$PATH LD_LIBRARY_PATH=%s/lib:%s/lib/frr"
       % (PREFIX, PREFIX, PREFIX, PREFIX))
RELOAD = ("%s %s/sbin/frr-reload.py --reload --bindir %s/bin --confdir %s/etc/frr "
          "--vty_socket /tmp/run %s" % (ENV, PREFIX, PREFIX, PREFIX, CONF))


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
            "mkdir -p /var/run/frr; cat > %s <<'EOF'\n%s\nEOF" % (CONF, "\n".join(lines)))


def reload(node):
    return lab.rsh(node, "sh", "-c", RELOAD, check=False)


def egpd_pid(node):
    return lab.rsh(node, "cat", "/tmp/run/egpd.pid").strip()


def restore(base, failure):
    """任何退出路径都把运行配置还原；恢复自身失败时打印，且在没有原始异常时才抛出。"""
    try:
        if running_config(lab.R1) == base:
            return
        write_conf(lab.R1, base)
        reload(lab.R1)
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
    except BaseException as exc:
        failure = exc
        raise
    finally:
        restore(base, failure)
    return 0


def steps(base, pid):
    # 1) 追加一条 network 并重载
    write_conf(lab.R1, base + ["egp network " + EXTRA])
    out = reload(lab.R1)
    if egpd_pid(lab.R1) != pid:
        raise AssertionError("重载重启了 egpd（pid %s -> %s）\n%s" % (pid, egpd_pid(lab.R1), out))
    lab.wait("对端学到新增的 " + EXTRA_CIDR,
             lambda: bool(lab.egp_route(lab.R2, EXTRA_CIDR)), timeout=40)
    if "Up" not in lab.neighbors(lab.R1) or "Up" not in lab.neighbors(lab.R2):
        raise AssertionError("重载后邻居不是 Up")
    if not lab.egp_route(lab.R2, lab.NET1_CIDR):
        raise AssertionError("重载把原有的 %s 丢了" % lab.NET1_CIDR)
    print("PASS 重载新增一条 network：egpd pid 不变、邻居不抖、原有路由保留", flush=True)

    # 2) 同一份配置再重载：必须无变化
    again = reload(lab.R1)
    low = again.lower()
    if not ("no configuration change" in low or "nothing" in low or not again.strip()):
        raise AssertionError("同配置二次重载不幂等：\n%s" % again)
    if egpd_pid(lab.R1) != pid:
        raise AssertionError("二次重载重启了 egpd")
    if not lab.egp_route(lab.R2, EXTRA_CIDR):
        raise AssertionError("二次重载把新增网络弄丢了")
    print("PASS 同配置二次重载幂等（frr-reload 报无变化，pid 不变）", flush=True)

    # 3) 恢复原配置：只撤掉新增的那条
    write_conf(lab.R1, base)
    out = reload(lab.R1)
    if egpd_pid(lab.R1) != pid:
        raise AssertionError("恢复重载重启了 egpd\n%s" % out)
    lab.wait("撤掉新增的 " + EXTRA_CIDR,
             lambda: not lab.egp_route(lab.R2, EXTRA_CIDR), timeout=40)
    if not lab.egp_route(lab.R2, lab.NET1_CIDR):
        raise AssertionError("恢复后原有 %s 没回来" % lab.NET1_CIDR)
    if "Up" not in lab.neighbors(lab.R1):
        raise AssertionError("恢复后邻居不是 Up")
    print("PASS 恢复原配置：只撤掉新增网络，原路由与邻居保持", flush=True)


if __name__ == "__main__":
    sys.exit(main())
