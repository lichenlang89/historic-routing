#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""historic-routing / EGP 双路由器实验的集成测试（12 项 + 收尾校验）。

设计原则：
  * 每一项都真实执行命令并断言解析后的状态，不依赖"日志里出现 PASS"；
  * 失败保留现场（打印异常与栈），整体退出码非 0；
  * 破坏性操作（撤宣告、杀进程、删邻居）都在 finally 里恢复实验；
  * 参数全部来自环境变量（由 lab.sh 从 lab.env 注入），脚本内无个人路径。

关于查询方式：RIB 一律用 `show ip route json` 解析（protocol=="egp"、distance==140），
文本里再确认显示码 'G'。`show ip route egp` 自 S9 起在默认构建里可用，可作为
独立的第二证据（它走 `proto_redistnum` 的名字解析，和 JSON 不是同一条代码路径）。

由 lab.sh test 调用；也可手动：
  LAB_R1=egp-lab-r1 LAB_R2=egp-lab-r2 ... python3 test_lab.py
"""

import json
import os
import re
import subprocess
import sys
import time
import traceback


def e(k, d=""):
    return os.environ.get(k, d)


# ---------------- 参数（lab.sh 注入） ----------------
MOUNT = e("LAB_MOUNT", "/build/prefix")
R1 = e("LAB_R1", "egp-lab-r1")
R2 = e("LAB_R2", "egp-lab-r2")
IP1 = e("LAB_IP1", "198.18.123.1")
IP2 = e("LAB_IP2", "198.18.123.2")
AS1 = e("LAB_AS1", "65001")
AS2 = e("LAB_AS2", "65002")
NET1 = e("LAB_NET1", "10.0.0.0")
HOST1 = e("LAB_HOST1", "10.0.0.1/8")
NET2 = e("LAB_NET2", "172.16.0.0")
HOST2 = e("LAB_HOST2", "172.16.0.1/16")
PORT = int(e("LAB_UDP_PORT", "9999"))
RUNDIR = e("LAB_RUNDIR", "/var/tmp/egp-lab")

NET1_CIDR = "10.0.0.0/8"
NET2_CIDR = "172.16.0.0/16"
STUB1 = HOST1.split("/")[0]
STUB2 = HOST2.split("/")[0]

LOG_PATH = os.path.join(RUNDIR, "logs", "test-%s.log" % time.strftime("%Y%m%d-%H%M%S"))
OUT = []


def say(msg):
    print(msg, flush=True)
    OUT.append(msg)


# ---------------- 底层执行 ----------------
def sh(*cmd, check=True):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError("命令失败: %s (rc=%d)\nstdout:\n%s\nstderr:\n%s" % (
            " ".join(cmd), p.returncode, p.stdout.strip(), p.stderr.strip()))
    return p.stdout


def rsh(n, *args, check=True):
    return sh("podman", "exec", n, *args, check=check)


def vty(n, daemon, *cmds):
    base = ["podman", "exec", n, MOUNT + "/bin/vtysh", "--vty_socket", "/tmp/run", "-d", daemon]
    for c in cmds:
        base += ["-c", c]
    return sh(*base)


def alive_pids(n, name):
    """容器内名为 name 的**非僵尸**进程 pid 列表。

    容器里如果没有 init 回收子进程，被杀掉的 daemon 会以 Z 状态留在进程表，
    pgrep 仍能匹配到它；直接把僵尸当成"还在运行"会造成假失败。
    """
    out = rsh(n, "sh", "-c",
              "ps -eo pid=,comm=,stat= | awk '$2==\"%s\" && $3 !~ /^Z/ {print $1}'" % name,
              check=False)
    return [x for x in out.split() if x.isdigit()]


def pids_of(n, name):
    out = rsh(n, "sh", "-c", "pgrep -x %s" % name, check=False)
    return [x for x in out.split() if x.isdigit()]


def start_daemon(n, d):
    cmd = ("%s/sbin/%s -d -u root -g root -f /tmp/egp/%s.conf "
           "-i /tmp/run/%s.pid -z /tmp/run/zserv.api --vty_socket /tmp/run "
           ">>/tmp/egp/%s.start.log 2>&1" % (MOUNT, d, d, d, d))
    rsh(n, "sh", "-c", cmd, check=False)
    time.sleep(1)


def kernel_routes(n):
    raw = rsh(n, "ip", "-j", "-4", "route").strip()
    return json.loads(raw) if raw else []


def has_kernel(n, dst, gw=None, proto=None):
    for r in kernel_routes(n):
        if r.get("dst") != dst:
            continue
        if gw is not None and r.get("gateway") != gw:
            continue
        if proto is not None and r.get("protocol") != proto:
            continue
        return True
    return False


def zebra_rib(n):
    raw = vty(n, "zebra", "show ip route json").strip()
    return json.loads(raw) if raw else {}


def egp_route(n, prefix):
    """某前缀下 protocol==egp 的 RIB 条目；没有则 None。"""
    for entry in zebra_rib(n).get(prefix, []):
        if entry.get("protocol") == "egp":
            return entry
    return None


def zebra_text(n):
    return vty(n, "zebra", "show ip route")


def neighbors(n):
    return vty(n, "egpd", "show ip egp neighbors")


def wait(label, pred, timeout=40, interval=1.0):
    start = time.monotonic()
    last = None
    while time.monotonic() - start < timeout:
        try:
            if pred():
                return time.monotonic() - start
        except Exception as exc:
            last = exc
        time.sleep(interval)
    raise AssertionError("%s: %.0fs 内未满足%s" % (
        label, timeout, ("（最后错误: %s）" % last) if last else ""))


def both_up():
    return ("Up" in neighbors(R1)) and ("Up" in neighbors(R2))


def both_routes():
    return has_kernel(R1, NET2_CIDR, gw=IP2) and has_kernel(R2, NET1_CIDR, gw=IP1)


# ---------------- 结果收集 ----------------
RESULTS = []


def check(name):
    def deco(fn):
        def wrapper():
            t0 = time.monotonic()
            try:
                evidence = fn()
                RESULTS.append((name, True, evidence, time.monotonic() - t0))
                say("PASS  %-44s %s" % (name, evidence))
            except Exception as exc:
                detail = str(exc) if str(exc) else exc.__class__.__name__
                RESULTS.append((name, False, detail, time.monotonic() - t0))
                say("FAIL  %-44s %s" % (name, detail))
                say(traceback.format_exc().rstrip())
        return wrapper
    return deco


# ---------------- 12 项检查 ----------------
@check("01 两个 egpd 进程正常启动")
def c01():
    ev = []
    for n in (R1, R2):
        eg = alive_pids(n, "egpd")
        zb = alive_pids(n, "zebra")
        if not eg or not zb:
            raise AssertionError("%s 存活的 egpd/zebra 缺失：egpd=%r zebra=%r（全部进程：%s）"
                                 % (n, eg, zb, rsh(n, "ps", "-eo", "pid,comm,stat")))
        ev.append("%s: egpd=%s zebra=%s" % (n, eg[0], zb[0]))
    return "; ".join(ev)


@check("02 双方邻居状态 Up")
def c02():
    t1, t2 = neighbors(R1), neighbors(R2)
    for table, peer, asn, who in ((t1, IP2, AS2, R1), (t2, IP1, AS1, R2)):
        m = re.search(r"(%s)\s+(\d+)\s+(\S+)\s+(active|passive)" % re.escape(peer), table)
        if not m:
            raise AssertionError("%s 邻居表里没有 %s：\n%s" % (who, peer, table))
        if m.group(3) != "Up":
            raise AssertionError("%s 邻居 %s 状态=%s（期望 Up）" % (who, peer, m.group(3)))
        if m.group(2) != asn:
            raise AssertionError("%s 邻居 %s AS=%s（期望 %s）" % (who, peer, m.group(2), asn))
    m1 = re.search(r"%s\s+%s\s+Up\s+(\S+)" % (re.escape(IP2), AS2), t1).group(1)
    m2 = re.search(r"%s\s+%s\s+Up\s+(\S+)" % (re.escape(IP1), AS1), t2).group(1)
    return "R1->%s Up(AS%s,%s)  R2->%s Up(AS%s,%s)" % (IP2, AS2, m1, IP1, AS1, m2)


@check("03 双向学习 EGP 路由")
def c03():
    e1, e2 = egp_route(R1, NET2_CIDR), egp_route(R2, NET1_CIDR)
    if not e1:
        raise AssertionError("%s 的 RIB 里没有 protocol=egp 的 %s；RIB=%s"
                             % (R1, NET2_CIDR, json.dumps(zebra_rib(R1))[:600]))
    if not e2:
        raise AssertionError("%s 的 RIB 里没有 protocol=egp 的 %s" % (R2, NET1_CIDR))
    return "%s 学到 %s（protocol=%s）；%s 学到 %s（protocol=%s）" % (
        R1, NET2_CIDR, e1["protocol"], R2, NET1_CIDR, e2["protocol"])


@check("04 zebra 显示类型 G、管理距离 140")
def c04():
    e1, e2 = egp_route(R1, NET2_CIDR), egp_route(R2, NET1_CIDR)
    if not e1 or not e2:
        raise AssertionError("RIB 里找不到 EGP 条目（见检查 03）")
    if e1.get("distance") != 140 or e2.get("distance") != 140:
        raise AssertionError("管理距离不是 140：R1=%r R2=%r"
                             % (e1.get("distance"), e2.get("distance")))
    pat2 = r"^G>\*\s+" + re.escape(NET2_CIDR) + r"\s+\[(\d+)/(\d+)\]"
    pat1 = r"^G>\*\s+" + re.escape(NET1_CIDR) + r"\s+\[(\d+)/(\d+)\]"
    m1 = re.search(pat2, zebra_text(R1), re.M)
    m2 = re.search(pat1, zebra_text(R2), re.M)
    if not m1 or not m2:
        raise AssertionError("文本输出里没有 'G>* <prefix> [140/x]' 行")
    return "JSON protocol=egp distance=140；文本 R1: G>* %s [%s/%s]  R2: G>* %s [%s/%s]" % (
        NET2_CIDR, m1.group(1), m1.group(2), NET1_CIDR, m2.group(1), m2.group(2))


@check("05 内核路由表存在学习到的路由")
def c05():
    if not has_kernel(R1, NET2_CIDR, gw=IP2, proto="zebra"):
        raise AssertionError("%s 内核表没有 %s via %s proto zebra：\n%s"
                             % (R1, NET2_CIDR, IP2, rsh(R1, "ip", "-4", "route")))
    if not has_kernel(R2, NET1_CIDR, gw=IP1, proto="zebra"):
        raise AssertionError("%s 内核表没有 %s via %s proto zebra：\n%s"
                             % (R2, NET1_CIDR, IP1, rsh(R2, "ip", "-4", "route")))
    return "R1: %s via %s proto zebra；R2: %s via %s proto zebra" % (
        NET2_CIDR, IP2, NET1_CIDR, IP1)


SERVER_CODE = (
    "import socket,sys\n"
    "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\n"
    "s.bind((sys.argv[1],int(sys.argv[2])))\n"
    "print('READY',flush=True)\n"
    "d,a=s.recvfrom(2048)\n"
    "s.sendto(b'ECHO:'+d,a)\n"
    "print('SERVED',d.decode(),flush=True)\n"
)

CLIENT_CODE = (
    "import socket,sys\n"
    "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\n"
    "s.bind((sys.argv[1],0))\n"
    "s.settimeout(6)\n"
    "s.sendto(sys.argv[4].encode(),(sys.argv[2],int(sys.argv[3])))\n"
    "d,_=s.recvfrom(2048)\n"
    "assert d==b'ECHO:'+sys.argv[4].encode(), d\n"
    "print('OK',d.decode())\n"
)


def udp_roundtrip(server_node, server_ip, client_node, client_ip, payload):
    proc = subprocess.Popen(
        ["podman", "exec", server_node, "python3", "-u", "-c", SERVER_CODE,
         server_ip, str(PORT)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        line = proc.stdout.readline().strip()
        if line != "READY":
            raise AssertionError("UDP 服务端未就绪: %r" % line)
        out = rsh(client_node, "python3", "-c", CLIENT_CODE,
                  client_ip, server_ip, str(PORT), payload).strip()
        if not out.startswith("OK"):
            raise AssertionError("客户端未收到回包: %r" % out)
        return out
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


@check("06 两个 Stub 网络之间 UDP 双向通信")
def c06():
    a = udp_roundtrip(R2, STUB2, R1, STUB1, "p1-to-p2")
    b = udp_roundtrip(R1, STUB1, R2, STUB2, "p2-to-p1")
    return "%s->%s: %s ; %s->%s: %s" % (STUB1, STUB2, a, STUB2, STUB1, b)


@check("07 取消 network 通告后对端撤路")
def c07():
    vty(R1, "egpd", "configure terminal", "no egp network %s" % NET1)
    dt = wait("等待 %s 撤销 %s" % (R2, NET1_CIDR),
              lambda: (not has_kernel(R2, NET1_CIDR)) and (egp_route(R2, NET1_CIDR) is None),
              timeout=45)
    return "撤宣告后 %.0fs：%s 的 RIB 与内核均无 %s" % (dt, R2, NET1_CIDR)


@check("08 重新宣告后路由恢复")
def c08():
    try:
        vty(R1, "egpd", "configure terminal", "egp network %s" % NET1)
        dt = wait("等待 %s 恢复 %s" % (R2, NET1_CIDR),
                  lambda: has_kernel(R2, NET1_CIDR, gw=IP1), timeout=45)
        return "重宣告后 %.0fs：%s 恢复 %s via %s" % (dt, R2, NET1_CIDR, IP1)
    finally:
        if egp_route(R2, NET1_CIDR) is None:
            vty(R1, "egpd", "configure terminal", "egp network %s" % NET1)


@check("09 egpd 异常退出后过期路由撤销")
def c09():
    pid = rsh(R2, "cat", "/tmp/run/egpd.pid").strip()
    if not pid:
        raise AssertionError("%s 没有 egpd pid 文件" % R2)
    rsh(R2, "kill", "-9", pid)
    dt = wait("等待 %s 撤销 %s" % (R1, NET2_CIDR),
              lambda: (not has_kernel(R1, NET2_CIDR)) and (egp_route(R1, NET2_CIDR) is None),
              timeout=60)
    return "SIGKILL egpd@%s(pid=%s) 后 %.0fs：%s 撤掉 %s" % (R2, pid, dt, R1, NET2_CIDR)


@check("10 egpd 重启后邻居与路由重建")
def c10():
    if alive_pids(R2, "egpd"):
        raise AssertionError("%s 的 egpd 仍在运行（%r），无法验证重启恢复"
                             % (R2, alive_pids(R2, "egpd")))
    start_daemon(R2, "egpd")
    wait("等待 %s 的 egpd 进程起来" % R2, lambda: bool(alive_pids(R2, "egpd")), timeout=20)
    dt = wait("等待邻居与路由恢复", lambda: both_up() and both_routes(), timeout=70)
    return "重启 egpd@%s 后 %.0fs：邻居 Up、双向路由恢复" % (R2, dt)


@check("11 zebra 重启后 egpd 重新下发路由")
def c11():
    pid = rsh(R1, "cat", "/tmp/run/zebra.pid").strip()
    if not pid:
        raise AssertionError("%s 没有 zebra pid 文件" % R1)
    rsh(R1, "kill", "-TERM", pid)
    time.sleep(3)
    start_daemon(R1, "zebra")
    wait("等待 %s 的 zebra 进程起来" % R1, lambda: bool(alive_pids(R1, "zebra")), timeout=20)
    dt = wait("等待 %s 的 zebra 重新装上 %s" % (R1, NET2_CIDR),
              lambda: has_kernel(R1, NET2_CIDR, gw=IP2) and egp_route(R1, NET2_CIDR) is not None,
              timeout=70)
    return "重启 zebra@%s 后 %.0fs：%s 重新出现在 zebra 与内核" % (R1, dt, NET2_CIDR)


@check("12 删除 EGP 邻居后路由撤销")
def c12():
    vty(R1, "egpd", "configure terminal", "no egp neighbor %s" % IP2)
    try:
        dt1 = wait("等待 %s 撤掉 %s" % (R1, NET2_CIDR),
                   lambda: not has_kernel(R1, NET2_CIDR), timeout=45)
        dt2 = wait("等待 %s 撤掉 %s（Cease）" % (R2, NET1_CIDR),
                   lambda: not has_kernel(R2, NET1_CIDR), timeout=45)
    finally:
        vty(R1, "egpd", "configure terminal",
            "egp neighbor %s local-address %s remote-as %s" % (IP2, IP1, AS2))
    return "删邻居后 %.0fs %s 撤路、%.0fs %s 撤路；邻居已重新配置" % (dt1, R1, dt2, R2)


def final_restore():
    dt = wait("实验恢复", lambda: both_up() and both_routes(), timeout=90)
    return "%.0fs 内双方邻居 Up、双向路由齐备" % dt


# ---------------- 主流程 ----------------
def main():
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    say("EGP 双路由器实验集成测试")
    say("  参数: R1=%s(%s,AS%s)  R2=%s(%s,AS%s)  前缀=%s  UDP端口=%d"
        % (R1, IP1, AS1, R2, IP2, AS2, MOUNT, PORT))
    say("  宣告: %s @ %s ; %s @ %s" % (NET1, HOST1, NET2, HOST2))
    say("")

    for fn in (c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11, c12):
        fn()

    try:
        ev = final_restore()
        RESULTS.append(("13 实验恢复（收尾校验）", True, ev, 0.0))
        say("PASS  %-44s %s" % ("13 实验恢复（收尾校验）", ev))
    except Exception as exc:
        RESULTS.append(("13 实验恢复（收尾校验）", False, str(exc), 0.0))
        say("FAIL  %-44s %s" % ("13 实验恢复（收尾校验）", exc))

    ok = sum(1 for r in RESULTS if r[1])
    bad = len(RESULTS) - ok
    say("")
    say("汇总: %d 通过 / %d 失败 / 共 %d 项" % (ok, bad, len(RESULTS)))
    for name, passed, detail, dur in RESULTS:
        say("  [%s] %-44s %5.1fs  %s" % ("PASS" if passed else "FAIL", name, dur, detail))

    with open(LOG_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(OUT) + "\n")
    print("\n日志: %s" % LOG_PATH, flush=True)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
