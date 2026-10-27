#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Live RFC 904 A.4 / RFC 888 section 5 Update regression.

Run through lab.sh test-updates after lab.sh up. Temporarily stop R2's egpd
and answer R1's Hello/Poll commands with independently constructed packets.
Always resume the original daemon and require normal routes to recover.
"""
import json
import os
import subprocess

import test_lab as lab


# This peer deliberately does not share the C codec under test.
PEER = r'''
import json, select, socket, struct, sys
local, remote, asn = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, 8)
s.bind((local, 0))
plan = []
def packet(kind, code, seq, body=b''):
    b = struct.pack('!BBBBHHH', 2, kind, code, 1, 0, asn, seq) + body
    padded = b + b'\0' * (len(b) % 2)
    total = sum(struct.unpack('!%dH' % (len(padded)//2), padded))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return b[:4] + struct.pack('!H', (~total) & 65535) + b[6:]
print('READY', flush=True)
while True:
    ready, _, _ = select.select([s, sys.stdin], [], [], 1)
    if sys.stdin in ready:
        line = sys.stdin.readline()
        if not line:
            break
        plan = json.loads(line)
        print('PLAN', flush=True)
    if s not in ready:
        continue
    b, src = s.recvfrom(2048)
    ihl = (b[0] & 15) * 4
    if src[0] != remote or b[16:20] != socket.inet_aton(local):
        continue
    b = b[ihl:]
    if len(b) < 10:
        continue
    seq = struct.unpack('!H', b[8:10])[0]
    if b[1:3] == bytes([5, 0]):
        s.sendto(packet(5, 1, seq), (remote, 0))
    elif b[1:3] == bytes([2, 0]):
        shared = b[12:16]
        first = shared[0]
        n = 1 if first < 128 else 2 if first < 192 else 3
        body = bytes([bool(plan), 0]) + shared
        if plan:
            # One distance block per test route, independent of C grouping.
            body += socket.inet_aton(local)[n:] + bytes([len(plan)])
            for net, distance in plan:
                ip = socket.inet_aton(net)
                k = 1 if ip[0] < 128 else 2 if ip[0] < 192 else 3
                body += bytes([distance, 1]) + ip[:k]
        s.sendto(packet(1, 0, seq, body), (remote, 0))
'''


def main():
    lab.wait("initial adjacency/routes", lambda: lab.both_up() and lab.both_routes())
    pid = lab.rsh(lab.R2, "cat", "/tmp/run/egpd.pid").strip()
    peer = None
    extra = "198.51.100.0/24"
    poll = int(os.environ.get("LAB_TIMERS", "2 6").split()[1])

    def metric(prefix, value):
        route = lab.egp_route(lab.R1, prefix)
        return (route is not None and route.get("metric") == value
                and lab.has_kernel(lab.R1, prefix, gw=lab.IP2))

    def absent(prefix):
        return lab.egp_route(lab.R1, prefix) is None and not lab.has_kernel(lab.R1, prefix)

    def stage(routes, label, predicate, cycles=2):
        peer.stdin.write(json.dumps(routes) + "\n")
        peer.stdin.flush()
        if peer.stdout.readline().strip() != "PLAN":
            raise AssertionError("raw peer did not accept plan")
        # Explicit withdrawals use two Poll periods, below the stale timer.
        # Omission ordering is checked one packet at a time in test_protocol.
        lab.wait(label, predicate, timeout=cycles * poll, interval=0.25)
        print("PASS " + label, flush=True)

    try:
        lab.rsh(lab.R2, "kill", "-STOP", pid)
        peer = subprocess.Popen(
            ["podman", "exec", "-i", lab.R2, "python3", "-u", "-c", PEER,
             lab.IP2, lab.IP1, lab.AS2], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if peer.stdout.readline().strip() != "READY":
            raise AssertionError("raw peer did not start")
        stage([[lab.NET2, 9]], "learn non-default distance 9", lambda: metric(lab.NET2_CIDR, 9))
        stage([[lab.NET2, 255], ["198.51.100.0", 7]],
              "withdraw one net while learning another",
              lambda: absent(lab.NET2_CIDR) and metric(extra, 7))
        stage([["198.51.100.0", 255]], "all-unreachable Update removes last route",
              lambda: absent(lab.NET2_CIDR) and absent(extra))
        stage([[lab.NET2, 0]], "distance zero remains reachable", lambda: metric(lab.NET2_CIDR, 0))
        # Three accepted omissions are now needed; each refreshes last_update.
        stage([], "three empty Updates age out an omitted route", lambda: absent(lab.NET2_CIDR), cycles=4)
    finally:
        try:
            if peer is not None:
                peer.stdin.close()  # EOF makes the in-container peer exit too.
                peer.wait(timeout=5)
        finally:
            lab.rsh(lab.R2, "kill", "-CONT", pid)
            lab.wait("original daemons recover routes", lambda: lab.both_up() and lab.both_routes(),
                     timeout=90)
            print("PASS original daemons restored", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
