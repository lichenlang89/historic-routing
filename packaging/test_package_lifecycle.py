#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check paired package upgrade/rollback in the exclusive installed-service lab."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys
import time

import test_installed_reload as installed

lab = installed.lab


def assert_services_stopped(target, units):
    """Reject either unit starting before the driver's explicit start."""
    for unit in units:
        result = target.run('systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'MainPID')
        properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        active, pid = properties.get('ActiveState'), properties.get('MainPID')
        print('STOPPED_UNIT %s ActiveState=%s MainPID=%s' % (unit, active, pid), flush=True)
        assert active == 'inactive' and pid == '0', (
            'Expected %s stopped before explicit start; ActiveState=%s MainPID=%s'
            % (unit, active, pid))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--old', nargs=2, required=True)
    parser.add_argument('--new', nargs=2, required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    prefix = config.get('prefix', '/opt/historic-routing/27f287be9')
    routers = {name: installed.Node(config[name], prefix) for name in ('target', 'peer')}
    target = routers['target']
    lab.R1, lab.R2 = 'target', 'peer'
    lab.IP1, lab.IP2 = config['ip1'], config['ip2']
    lab.rsh = lambda node, *argv, check=True: routers[node].run(*argv, check=check).stdout
    lab.vty = lambda node, daemon, *commands: routers[node].vty(daemon, commands)
    units = ['historic-routing-egpd.service', 'historic-routing-zebra.service']
    names = ['historic-routing-runtime', 'historic-routing-egp']

    def healthy():
        return (lab.both_up() and lab.both_routes()
                and lab.has_kernel(lab.R1, lab.NET2_CIDR, gw=lab.IP2)
                and lab.has_kernel(lab.R2, lab.NET1_CIDR, gw=lab.IP1))

    def versions():
        if config['packages'] == 'rpm':
            text = target.run('rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}\n', *names).stdout
        else:
            text = target.run('dpkg-query', '-W', '-f', '${Version}\n', *names).stdout
        values = text.strip().splitlines()
        assert len(values) == 2 and values[0] == values[1], text
        return values[0]

    def stop():
        target.run('systemctl', 'stop', *units)
        assert_services_stopped(target, units)
        # Native peers share the installed prefix with the target. Stop the
        # matching peer processes before replacing any files, then relaunch
        # both daemons from the newly installed pair. Container roots differ.
        peer = routers['peer']
        if not peer.config.get('container'):
            for daemon in ('egpd', 'zebra'):
                pid = peer.run('cat', peer.socket + '/' + daemon + '.pid').stdout.strip()
                assert pid.isdigit()
                assert os.readlink('/proc/' + pid + '/exe') == prefix + '/sbin/' + daemon
                peer.run('kill', '-TERM', pid)
                deadline = time.monotonic() + 10
                while os.path.exists('/proc/' + pid):
                    if time.monotonic() >= deadline:
                        raise AssertionError('Native peer did not stop: ' + daemon)
                    time.sleep(.1)

    def start():
        peer = routers['peer']
        if not peer.config.get('container'):
            peer_dir = str(Path(args.config).resolve().parent / 'peer')
            for daemon in ('zebra', 'egpd'):
                command = [prefix + '/sbin/' + daemon, '-d', '-u', 'root', '-g', 'root',
                           '-f', peer_dir + '/' + daemon + '.conf',
                           '-i', peer.socket + '/' + daemon + '.pid',
                           '-z', peer.socket + '/zserv.api', '--vty_socket', peer.socket]
                # Detached daemons retain logging descriptors. Give them a
                # file rather than keeping subprocess.communicate's pipe open.
                peer.run('sh', '-c', 'exec ' + shlex.join(command) + ' >> ' +
                         shlex.quote(peer_dir + '/' + daemon + '.start.log') + ' 2>&1',
                         network=True)
        target.run('systemctl', 'start', *reversed(units))
        lab.wait('installed services recover RIB/kernel routes', healthy, timeout=60)
        assert target.pid() != '0'

    def apply(packages, downgrade=False):
        if config['packages'] == 'rpm':
            command = ['dnf', '--disablerepo=*', '-y',
                       'downgrade' if downgrade else 'install'] + packages
        else:
            command = ['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', '-y',
                       '--no-remove', '--allow-downgrades', '-o',
                       'Dpkg::Options::=--force-confold', 'install'] + packages
        result = target.run(*command)
        print(result.stdout, flush=True)
        assert_services_stopped(target, units)

    paths = [prefix + '/etc/frr/' + name for name in ('frr.conf', 'egpd.conf', 'vtysh.conf', 'daemons')]
    original = {path: target.read_bytes(path) for path in paths
                if target.run('test', '-f', path, check=False).returncode == 0}
    marker = b'! installed package upgrade/rollback preservation marker'
    expected = {}
    for path, data in original.items():
        newline = b'\r\n' if b'\r\n' in data else b'\n'
        separator = b'' if not data or data.endswith(b'\n') else newline
        expected[path] = data + separator + marker + newline
    lab.wait('lifecycle baseline', healthy, timeout=60)
    old_version = versions()
    print('OLD_PAIRED_VERSION=' + old_version, flush=True)
    failure = None
    try:
        for path, text in expected.items():
            target.write_bytes(path, text)
        target.run('systemctl', 'reload', target.unit)
        lab.wait('operator configuration valid before upgrade', healthy, timeout=30)
        stop()

        for package in args.new:
            if config['packages'] == 'rpm':
                result = target.run('rpm', '-U', '--test', package, check=False)
            else:
                result = target.run('apt-get', '--simulate', '--no-remove', 'install', package,
                                    check=False)
            print('MISMATCH_PROBE rc=%d\n%s' % (result.returncode, result.stdout), flush=True)
            assert result.returncode != 0, 'A single new component would break the exact pair'

        apply(args.new)
        new_version = versions()
        assert new_version != old_version
        for path, text in expected.items():
            assert target.read_bytes(path) == text, path
        start()
        print('PASS paired upgrade: configuration retained, no automatic start, RIB/kernel recovered; ' + new_version, flush=True)

        stop()
        apply(args.old, downgrade=True)
        assert versions() == old_version
        for path, text in expected.items():
            assert target.read_bytes(path) == text, path
        start()
        print('PASS paired rollback: configuration retained, RIB/kernel recovered; ' + old_version, flush=True)

        stop()
        apply(args.new)
        assert versions() == new_version
        for path, text in expected.items():
            assert target.read_bytes(path) == text, path
        start()
        target.run('systemctl', 'reload', target.unit)
        lab.wait('reload after final upgrade', healthy, timeout=30)
        print('PASS final paired upgrade and systemctl reload', flush=True)
    except BaseException as exc:
        failure = exc
        raise
    finally:
        try:
            for path, text in original.items():
                target.write_bytes(path, text)
            if target.pid() == '0':
                start()
            else:
                target.run('systemctl', 'reload', target.unit)
            lab.wait('original operational configuration restored', healthy, timeout=60)
            for path, text in original.items():
                actual = target.read_bytes(path)
                assert actual == text
                print('RESTORED_CONFIG %s sha256=%s' % (
                    path, hashlib.sha256(actual).hexdigest()), flush=True)
            print('PASS original configuration restored after lifecycle tests', flush=True)
        except Exception as exc:
            print('FAIL lifecycle recovery: ' + str(exc), flush=True)
            if failure is None:
                raise
    return 0


if __name__ == '__main__':
    sys.exit(main())
