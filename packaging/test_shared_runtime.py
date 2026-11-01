#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Restart only installed egpd and require the live Zebra socket to survive.

Use an already provisioned, exclusive backend as in packaging/TESTING.md.
The caller owns final network/service cleanup. No Zebra restart is used to
recover this assertion; doing so would hide the shared-directory defect.
"""
import argparse
import json
import os
from pathlib import Path

from test_installed_reload import Node, lab


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    prefix = config.get('prefix', '/opt/historic-routing/27f287be9')
    nodes = {name: Node(config[name], prefix) for name in ('target', 'peer')}
    target = nodes['target']
    lab.R1, lab.R2, lab.IP1, lab.IP2 = 'target', 'peer', config['ip1'], config['ip2']
    lab.rsh = lambda name, *argv, check=True: nodes[name].run(*argv, check=check).stdout
    lab.vty = lambda name, daemon, *commands: nodes[name].vty(daemon, commands)
    zebra = 'historic-routing-zebra.service'

    def healthy():
        return (lab.both_up() and lab.both_routes()
                and lab.has_kernel('target', lab.NET2_CIDR, gw=lab.IP2)
                and lab.has_kernel('peer', lab.NET1_CIDR, gw=lab.IP1))

    def zebra_pid():
        return target.run('systemctl', 'show', zebra, '-p', 'MainPID', '--value').stdout.strip()

    lab.wait('shared-runtime baseline', healthy, timeout=60)
    original_pid, original_zebra = target.pid(), zebra_pid()
    assert int(original_pid) > 0 and int(original_zebra) > 0
    if not target.config.get('container'):
        assert os.stat('/proc/' + original_pid + '/ns/net').st_ino == os.stat(
            '/run/netns/' + target.config['netns']).st_ino
    socket = target.socket + '/zserv.api'
    inode = target.run('stat', '-c', '%i', socket).stdout.strip()
    try:
        target.run('systemctl', 'stop', target.unit)
        assert target.pid() == '0'
        assert zebra_pid() == original_zebra
        assert target.run('test', '-S', socket, check=False).returncode == 0, 'live Zebra socket removed'
        assert target.run('stat', '-c', '%i', socket).stdout.strip() == inode
        target.run('systemctl', 'start', target.unit)
        lab.wait('egpd reconnects to unchanged Zebra', healthy, timeout=60)
        assert target.pid() not in ('0', original_pid)
        assert zebra_pid() == original_zebra
        print('PASS egpd stop/start retained Zebra PID=%s socket inode=%s and recovered RIB/kernel routes'
              % (original_zebra, inode), flush=True)
    finally:
        if target.pid() == '0':
            target.run('systemctl', 'start', target.unit)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
