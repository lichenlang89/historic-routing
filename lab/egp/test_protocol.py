#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Independent raw-peer regressions. Use lab.sh test-protocol with timers 1 1."""
import json
import os
import queue
import subprocess
import threading
import time

import test_lab as lab

PEER = r'''
import json, select, socket, struct, sys, time
local, remote, asn = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, 8)
s.bind((local, 0))
plan = {}
next_command, command_seq = 0, 30000
ip = socket.inet_aton(local)
n = 1 if ip[0] < 128 else 2 if ip[0] < 192 else 3
shared = ip[:n] + b'\0' * (4-n)
def send(kind, code, status, seq, body=b''):
    b = struct.pack('!BBBBHHH', 2, kind, code, status, 0, asn, seq) + body
    padded = b + b'\0' * (len(b) % 2)
    total = sum(struct.unpack('!%dH' % (len(padded)//2), padded))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    b = b[:4] + struct.pack('!H', (~total) & 65535) + b[6:]
    s.sendto(b, (remote, 0))
def update(seq, status=1):
    routes = plan.get('routes', [])
    body = bytes([bool(routes), 0]) + shared
    if routes:
        body += ip[n:] + bytes([len(routes)])
        for net, distance in routes:
            a = socket.inet_aton(net)
            k = 1 if a[0] < 128 else 2 if a[0] < 192 else 3
            body += bytes([distance, 1]) + a[:k]
    send(1, 0, status, seq, body)
print(json.dumps({'ready': True}), flush=True)
while True:
    ready, _, _ = select.select([s, sys.stdin], [], [], .1)
    if sys.stdin in ready:
        line = sys.stdin.readline()
        if not line:
            break
        cmd = json.loads(line)
        if 'plan' in cmd:
            plan = cmd['plan']
        if 'send' in cmd:
            kind, code, status, seq, body = cmd['send']
            send(kind, code, status, seq, bytes.fromhex(body))
        if 'update' in cmd:
            update(cmd['update'][0], cmd['update'][1])
        print(json.dumps({'ack': cmd['id']}), flush=True)
    if plan.get('commands') and time.monotonic() >= next_command:
        command_seq = (command_seq + 1) & 65535
        send(2, 0, 1, command_seq, b'\0\0' + shared)
        next_command = time.monotonic() + 1
    if s not in ready:
        continue
    b, src = s.recvfrom(2048)
    ihl = (b[0] & 15) * 4
    if src[0] != remote or b[16:20] != socket.inet_aton(local):
        continue
    b = b[ihl:]
    if len(b) < 10:
        continue
    ver, kind, code, status, check, peer_as, seq = struct.unpack('!BBBBHHH', b[:10])
    print(json.dumps({'recv': [kind, code, status, seq], 'body': b[10:].hex()}), flush=True)
    if (kind, code) == (5, 0) and plan.get('hello', True):
        send(5, 1, 1, (seq + plan.get('seq_offset', 0)) & 65535)
    if (kind, code) == (2, 0) and plan.get('updates', True):
        update(seq)
'''


class Peer:
    def __init__(self, node, local, remote, asn):
        self.node, self.local, self.remote, self.asn = node, local, remote, asn
        self.proc = None
        self.events, self.saved, self.serial = queue.Queue(), [], 0

    def __enter__(self):
        self.pid = lab.rsh(self.node, 'cat', '/tmp/run/egpd.pid').strip()
        lab.rsh(self.node, 'kill', '-STOP', self.pid)
        try:
            self.proc = subprocess.Popen(
                ['podman', 'exec', '-i', self.node, 'python3', '-u', '-c', PEER,
                 self.local, self.remote, self.asn], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            def read():
                for line in self.proc.stdout:
                    try:
                        self.events.put(json.loads(line))
                    except ValueError:
                        self.events.put({'error': line.strip()})
                self.events.put({'error': 'raw peer exited'})
            threading.Thread(target=read, daemon=True).start()
            self.wait(lambda e: e.get('ready'), 5)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def wait(self, pred, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            for i, event in enumerate(self.saved):
                if pred(event):
                    return self.saved.pop(i)
            event = self.events.get(timeout=max(.01, deadline-time.monotonic()))
            if 'error' in event:
                raise AssertionError(event['error'])
            self.saved.append(event)
            if time.monotonic() > deadline:
                raise AssertionError('expected peer event not received')

    def command(self, **cmd):
        self.serial += 1
        cmd['id'] = self.serial
        self.proc.stdin.write(json.dumps(cmd) + '\n')
        self.proc.stdin.flush()
        self.wait(lambda e: e.get('ack') == self.serial)

    def __exit__(self, *args):
        try:
            if self.proc is not None:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
        finally:
            lab.rsh(self.node, 'kill', '-CONT', self.pid)


def stable(label, pred, seconds=7):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not pred():
            raise AssertionError(label)
        time.sleep(.25)
    print('PASS ' + label, flush=True)


def reachability():
    lab.wait('initial routes', lambda: lab.both_up() and lab.both_routes())
    try:
        with Peer(lab.R2, lab.IP2, lab.IP1, lab.AS2) as p:
            p.command(plan={'hello': False, 'updates': True, 'routes': [[lab.NET2, 9]]})
            lab.wait('fresh Update received', lambda: (lab.egp_route(lab.R1, lab.NET2_CIDR) or {}).get('metric') == 9)
            stable('active stays Up using Update responses only', lambda: 'Up' in lab.neighbors(lab.R1))
            p.command(plan={'hello': True, 'updates': False, 'seq_offset': 1})
            lab.wait('stale I-H-U cannot keep active neighbor Up', lambda: 'Down' in lab.neighbors(lab.R1), timeout=8)
            assert not lab.has_kernel(lab.R1, lab.NET2_CIDR)
            print('PASS stale responses do not renew reachability', flush=True)
    finally:
        lab.wait('active recovery', lambda: lab.both_up() and lab.both_routes(), timeout=60)
    try:
        with Peer(lab.R1, lab.IP1, lab.IP2, lab.AS1) as p:
            p.command(plan={'hello': False, 'updates': False, 'commands': True})
            stable('passive stays Up using Poll Up commands only', lambda: 'Up' in lab.neighbors(lab.R2))
            p.command(plan={'hello': False, 'updates': False})
            lab.wait('passive expires without indications', lambda: 'Down' in lab.neighbors(lab.R2), timeout=8)
            print('PASS passive four-T1 expiry', flush=True)
    finally:
        lab.wait('passive recovery', lambda: lab.both_up() and lab.both_routes(), timeout=60)


def main():
    if os.environ.get('LAB_TIMERS') != '1 1':
        raise SystemExit('test-protocol requires LAB_TIMERS="1 1" in lab.env')
    reachability()
    print('PASS protocol regressions and original daemon recovery', flush=True)


if __name__ == '__main__':
    main()
