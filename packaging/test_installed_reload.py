#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run the existing reload behavior cases against an installed systemd unit.

The caller provides two disposable EGP routers and a JSON backend description.
Native routers must be in named network namespaces. Container routers must have
their own systemd PID 1 and installed package files. No daemon is restarted to
make a reload assertion pass. This driver does not provision or clean networks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lab/egp'))
import test_lab as lab
import test_reload as cases


class Node:
    def __init__(self, config, prefix):
        self.config, self.prefix = config, prefix
        self.unit = config.get('unit', 'historic-routing-egpd.service')
        self.socket = config.get('socket', '/run/historic-routing/frr')

    def run(self, *args, input=None, check=True, network=False, binary=False):
        command = list(args)
        if self.config.get('container'):
            command = ['podman', 'exec', '-i', self.config['container']] + command
        elif network or (args and args[0] == 'ip'):
            command = ['ip', 'netns', 'exec', self.config['netns']] + command
        result = subprocess.run(command, input=input, text=not binary, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        if check and result.returncode:
            raise RuntimeError('%s rc=%s\n%s' % (command, result.returncode, result.stdout))
        return result

    def read_bytes(self, path):
        return self.run('cat', path, binary=True).stdout

    def write_bytes(self, path, data):
        self.run('tee', path, input=data, binary=True)

    def pid(self):
        return self.run('systemctl', 'show', self.unit, '-p', 'MainPID', '--value').stdout.strip()

    def vty(self, daemon, commands):
        argv = [self.prefix + '/bin/vtysh', '--config_dir', self.prefix + '/etc/frr',
                '--vty_socket', self.socket, '-d', daemon]
        for command in commands:
            argv.extend(['-c', command])
        return self.run(*argv).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, help='JSON describing exclusive test routers')
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    prefix = config.get('prefix', '/opt/historic-routing/27f287be9')
    nodes = {name: Node(config[name], prefix) for name in ('target', 'peer')}
    target = nodes['target']
    conf = prefix + '/etc/frr/egpd.conf'
    saved_file = target.read_bytes(conf)
    lab.R1, lab.R2 = 'target', 'peer'
    lab.IP1, lab.IP2 = config['ip1'], config['ip2']
    lab.AS1, lab.AS2 = '65001', '65002'

    def rsh(node, *command, check=True):
        return nodes[node].run(*command, check=check).stdout

    lab.rsh = rsh
    lab.vty = lambda node, daemon, *commands: nodes[node].vty(daemon, commands)
    cases.egpd_pid = lambda node: nodes[node].pid()

    def write_conf(node, lines):
        nodes[node].run('tee', conf, input='\n'.join(lines) + '\n')

    def reload(node):
        router = nodes[node]
        start = time.monotonic()
        result = router.run('systemctl', 'reload', router.unit, check=False)
        out = result.stdout
        if result.returncode:
            out += router.run('journalctl', '-u', router.unit, '-n', '80', '--no-pager').stdout
            print('RELOAD_DIAGNOSTIC\n' + out, flush=True)
        print('SYSTEMCTL_RELOAD node=%s rc=%d elapsed=%.2fs MainPID=%s' % (
            node, result.returncode, time.monotonic() - start, router.pid()), flush=True)
        return result.returncode, out

    cases.write_conf, cases.reload = write_conf, reload
    print('BACKEND ' + json.dumps(config, sort_keys=True), flush=True)
    for name, router in nodes.items():
        print('PLATFORM ' + name + '\n' + router.run('cat', '/etc/os-release').stdout, flush=True)
        if config['packages'] == 'rpm':
            print(router.run('rpm', '-q', 'historic-routing-runtime', 'historic-routing-egp').stdout, flush=True)
        else:
            print(router.run('dpkg-query', '-W', 'historic-routing-runtime', 'historic-routing-egp').stdout, flush=True)
        if name == 'target':
            print(router.run('systemctl', 'cat', router.unit).stdout, flush=True)
            properties = router.run('systemctl', 'show', router.unit, '-p', 'MainPID',
                                    '-p', 'FragmentPath', '-p', 'DropInPaths',
                                    '-p', 'ExecStart', '-p', 'ExecReload').stdout
            print(properties, flush=True)
            assert 'frr-reload.py' in properties and '--daemon egpd' in properties
            pid = router.pid()
            assert pid.isdigit() and int(pid) > 0
            if not router.config.get('container'):
                assert os.stat('/proc/' + pid + '/ns/net').st_ino == os.stat(
                    '/run/netns/' + router.config['netns']).st_ino

    lab.wait('installed service baseline', lambda: lab.both_up() and lab.both_routes(), timeout=60)
    base, pid = cases.running_config(lab.R1), target.pid()
    failure = None
    try:
        cases.steps(base, pid)
        assert target.pid() == pid
        print('PASS installed package systemctl reload behavior cases', flush=True)
    except BaseException as exc:
        failure = exc
        raise
    finally:
        try:
            cases.restore(base, failure)
            target.write_bytes(conf, saved_file)
            rc, out = reload(lab.R1)
            assert rc == 0, out
            lab.wait('original installed configuration restored',
                     lambda: lab.both_up() and lab.both_routes(), timeout=60)
            actual = target.read_bytes(conf)
            assert actual == saved_file
            print('RESTORED_CONFIG sha256=' + hashlib.sha256(actual).hexdigest(), flush=True)
            assert target.pid() == pid
            print('PASS original file bytes, PID, neighbors and routes restored', flush=True)
        except Exception as exc:
            print('FAIL installed-service recovery: ' + str(exc), flush=True)
            if failure is None:
                raise
    return 0


if __name__ == '__main__':
    sys.exit(main())
