#!/usr/bin/env python3
"""Integration tests for lab.sh's disposable containers; restores a live lab."""
import json
import subprocess
import time


def run(n, *args):
    return subprocess.check_output(
        ["podman", "exec", f"egp-lab-r{n}", *args], text=True,
        stderr=subprocess.STDOUT,
    )


def vty(n, daemon, *commands):
    args = ["env", "LD_LIBRARY_PATH=/build/prefix/lib:/build/prefix/lib/frr",
            "/build/prefix/bin/vtysh", "--vty_socket", "/tmp/run", "-d", daemon]
    for command in commands:
        args.extend(["-c", command])
    return run(n, *args)


def route(n, prefix):
    return any(r.get("dst") == prefix for r in json.loads(run(n, "ip", "-j", "-4", "route")))


def wait(label, predicate, timeout=35):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            print("PASS", label, flush=True)
            return
        time.sleep(1)
    raise AssertionError(label)


def start(n, daemon):
    run(n, "env", "LD_LIBRARY_PATH=/build/prefix/lib:/build/prefix/lib/frr",
        f"/build/prefix/sbin/{daemon}", "-d", "-u", "root", "-g", "root",
        "-f", f"/tmp/{daemon}.conf", "-i", f"/tmp/{daemon}.pid",
        "-z", "/tmp/zserv.api", "--vty_socket", "/tmp/run")


def stop(n, daemon, sig="TERM"):
    pid = run(n, "cat", f"/tmp/{daemon}.pid").strip()
    run(n, "kill", f"-{sig}", pid)


wait("bilateral kernel routes", lambda: route(1, "172.16.0.0/16") and route(2, "10.0.0.0/8"))
assert "G" in vty(1, "zebra", "show ip route egp")
assert "egp neighbor 198.18.123.2" in vty(1, "egpd", "show running-config")
print("PASS vtysh route type and configuration serialization", flush=True)

# Exercise both forwarding paths using explicitly bound stub addresses.
server = subprocess.Popen(["podman", "exec", "egp-lab-r2", "python3", "-u", "-c",
    "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); "
    "s.bind(('172.16.0.1',19040)); s.settimeout(10); print('ready',flush=True); "
    "data,peer=s.recvfrom(1024); s.sendto(data,peer)"], stdout=subprocess.PIPE, text=True)
try:
    assert server.stdout.readline().strip() == "ready"
    run(1, "python3", "-c",
        "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); "
        "s.bind(('10.0.0.1',0)); s.settimeout(5); "
        "s.sendto(b'EGP-zebra',('172.16.0.1',19040)); "
        "assert s.recv(1024)==b'EGP-zebra'")
    assert server.wait(timeout=10) == 0
finally:
    if server.poll() is None:
        server.terminate()
print("PASS routed UDP round trip between stub networks", flush=True)

try:
    vty(1, "egpd", "configure terminal", "no egp network 10.0.0.0")
    wait("empty Update withdraws route", lambda: not route(2, "10.0.0.0/8"))
finally:
    vty(1, "egpd", "configure terminal", "egp network 10.0.0.0")
wait("readvertisement installs route", lambda: route(2, "10.0.0.0/8"))

stop(2, "egpd", "KILL")
try:
    wait("ungraceful neighbor loss withdraws route", lambda: not route(1, "172.16.0.0/16"))
finally:
    start(2, "egpd")
wait("neighbor restart recovers", lambda: route(1, "172.16.0.0/16") and route(2, "10.0.0.0/8"))

stop(1, "zebra")
time.sleep(2)
start(1, "zebra")
wait("zebra reconnect replays routes", lambda: route(1, "172.16.0.0/16"), timeout=50)

vty(1, "egpd", "configure terminal", "no egp neighbor 198.18.123.2")
try:
    wait("neighbor deletion removes owned route", lambda: not route(1, "172.16.0.0/16"))
    wait("Cease withdraws remote route", lambda: not route(2, "10.0.0.0/8"))
finally:
    vty(1, "egpd", "configure terminal",
        "egp neighbor 198.18.123.2 local-address 198.18.123.1 remote-as 65002")
wait("restored playable lab", lambda: route(1, "172.16.0.0/16") and route(2, "10.0.0.0/8"))
print("All EGP lab checks passed", flush=True)
