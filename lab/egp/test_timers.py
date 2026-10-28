#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Real-clock timer regression; run lab.sh test-timers in an isolated lab."""
import os
import time

import test_lab as lab


def configure(hello, poll):
    peers = ((lab.R1, lab.IP1, lab.IP2, lab.AS2),
             (lab.R2, lab.IP2, lab.IP1, lab.AS1))
    for node, _, remote, _ in peers:
        # A second Stop also releases a neighbor whose Cease ACK was lost.
        lab.vty(node, 'egpd', 'configure terminal',
                'no egp neighbor '+remote, 'no egp neighbor '+remote)
    for node, _, _, _ in peers:
        lab.vty(node, 'egpd', 'configure terminal', 'egp timers %d %d' % (hello, poll))
    for node, local, remote, asn in peers:
        lab.vty(node, 'egpd', 'configure terminal',
                'egp neighbor %s local-address %s remote-as %s' % (remote, local, asn))


def main():
    original = tuple(map(int, os.environ.get('LAB_TIMERS', '2 6').split()))
    lab.wait('initial timer routes', lambda: lab.both_up() and lab.both_routes())
    try:
        configure(3, 1)
        lab.wait('local Hello=3/Poll=1 configuration',
                 lambda: lab.both_up() and lab.both_routes(), timeout=25)
        print('PASS CLI accepts independent Hello=3/Poll=1 intervals', flush=True)
        configure(90, 120)
        lab.wait('slow peers acquired',
                 lambda: all('Down' in lab.neighbors(n) or 'Up' in lab.neighbors(n)
                             for n in (lab.R1, lab.R2)), timeout=10)
        started = time.monotonic()
        while time.monotonic() - started < 125:
            assert all('Down' in lab.neighbors(n) or 'Up' in lab.neighbors(n)
                       for n in (lab.R1, lab.R2)), 'slow peer aborted before reachability'
            time.sleep(2)
        print('PASS slow peers remain acquired beyond the old 120-second abort', flush=True)
        remaining = max(1, 365 - (time.monotonic() - started))
        lab.wait('Hello=90/Poll=120 reaches Up and exchanges routes',
                 lambda: lab.both_up() and lab.both_routes(), timeout=remaining)
        print('PASS Hello=90/Poll=120 establishes both neighbors and routes', flush=True)
    finally:
        configure(*original)
        lab.wait('original timer recovery', lambda: lab.both_up() and lab.both_routes(),
                 timeout=4 * original[0] + original[1] + 40)
        print('PASS original timer configuration restored', flush=True)


if __name__ == '__main__':
    main()
