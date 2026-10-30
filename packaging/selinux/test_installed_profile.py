#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Exercise an installed profile in an exclusive native two-router lab.

Caller provisions/cleans both namespaces, installed core packages and original
unit namespace drop-ins. The profile must initially be absent. The manual peer
shares the native prefix; its config/PID/log paths follow packaging/TESTING.md.
Run as root with --config backend.json --rpmdir TOPDIR/RPMS --mode Enforcing
(or Disabled for store-only checks). This test performs real package erases;
never point it at a production host or an unowned router/network.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repo / 'packaging'))
import test_installed_reload as installed
from test_package_lifecycle import assert_services_stopped

parser = argparse.ArgumentParser()
parser.add_argument('--config', required=True)
parser.add_argument('--rpmdir', required=True)
parser.add_argument('--mode', choices=('Enforcing', 'Disabled'), required=True)
args = parser.parse_args()
cfg = json.loads(Path(args.config).read_text())
prefix = cfg['prefix']
nodes = {name: installed.Node(cfg[name], prefix) for name in ('target', 'peer')}
target, peer = nodes['target'], nodes['peer']
lab = installed.lab
lab.R1, lab.R2, lab.IP1, lab.IP2 = 'target', 'peer', cfg['ip1'], cfg['ip2']
lab.rsh = lambda name, *cmd, check=True: nodes[name].run(*cmd, check=check).stdout
lab.vty = lambda name, daemon, *cmd: nodes[name].vty(daemon, cmd)
units = ['historic-routing-egpd.service', 'historic-routing-zebra.service']
rpms = list(Path(args.rpmdir).glob('*/*.rpm'))
packages = {name: str(next(p for p in rpms if p.name.startswith('historic-routing-' + name + '-')))
            for name in ('runtime', 'egp', 'selinux')}
original = {prefix + '/etc/frr/' + name: target.read_bytes(prefix + '/etc/frr/' + name)
            for name in ('frr.conf', 'egpd.conf', 'vtysh.conf', 'daemons')}


def healthy():
    lab.wait('both neighbor and RIB/kernel routes', lambda: (
        lab.both_up() and lab.both_routes()
        and lab.has_kernel('target', lab.NET2_CIDR, gw=lab.IP2)
        and lab.has_kernel('peer', lab.NET1_CIDR, gw=lab.IP1)), timeout=60)


def configuration():
    for path, data in original.items():
        actual = target.read_bytes(path)
        assert actual == data, path
        print('EXACT_CONFIG', Path(path).name, hashlib.sha256(actual).hexdigest(), flush=True)


def call(*cmd, expect=0):
    result = target.run(*cmd, check=False)
    print('COMMAND', shlex.join(cmd), 'RC', result.returncode, flush=True)
    print(result.stdout, flush=True)
    if expect == 0:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0, result.stdout
    return result


def module_present():
    lines = target.run('semodule', '-s', 'targeted', '-lfull').stdout.splitlines()
    return any(line.split()[:2] == ['200', 'historic_routing_egp'] for line in lines)


def stop():
    target.run('systemctl', 'stop', *units)
    assert_services_stopped(target, units)


def start(profile=True):
    target.run('systemctl', 'start', *reversed(units))
    assert target.run('getenforce').stdout.strip() == args.mode
    for unit in units:
        pid = target.run('systemctl', 'show', unit, '-p', 'MainPID', '--value').stdout.strip()
        label = target.run('ps', '-p', pid, '-o', 'label=').stdout.strip()
        print('DOMAIN', unit, 'MainPID=' + pid, 'label=' + label, flush=True)
        if args.mode == 'Enforcing':
            assert (':frr_t:' in label) == profile, label
    healthy()


def stop_peer():
    for daemon in ('egpd', 'zebra'):
        pid = peer.run('cat', peer.socket + '/' + daemon + '.pid').stdout.strip()
        assert pid.isdigit() and os.readlink('/proc/' + pid + '/exe') == prefix + '/sbin/' + daemon
        peer.run('kill', '-TERM', pid)
        deadline = time.monotonic() + 10
        while os.path.exists('/proc/' + pid):
            assert time.monotonic() < deadline, 'peer did not stop'
            time.sleep(.1)


def start_peer():
    confdir = Path(args.config).resolve().parent / 'peer'
    for daemon in ('zebra', 'egpd'):
        command = [prefix + '/sbin/' + daemon, '-d', '-u', 'root', '-g', 'root',
                   '-f', str(confdir / (daemon + '.conf')), '-i', peer.socket + '/' + daemon + '.pid',
                   '-z', peer.socket + '/zserv.api', '--vty_socket', peer.socket]
        peer.run('sh', '-c', 'exec ' + shlex.join(command) + ' >> ' +
                 shlex.quote(str(confdir / (daemon + '.start.log'))) + ' 2>&1', network=True)


def remove(*names):
    call('dnf', '--disablerepo=*', '-y', '--setopt=clean_requirements_on_remove=False',
         'remove', *['historic-routing-' + name for name in names])


healthy()
assert not module_present()
pids = {unit: target.run('systemctl', 'show', unit, '-p', 'MainPID', '--value').stdout for unit in units}
result = call('dnf', '--disablerepo=*', '-y', 'install', packages['selinux'], expect=1)
assert 'before first installing' in result.stdout
assert not module_present()
assert target.run('rpm', '-q', 'historic-routing-selinux', check=False).returncode != 0
for unit, pid in pids.items():
    assert target.run('systemctl', 'show', unit, '-p', 'MainPID', '--value').stdout == pid
print('PASS live first-install refused without restarting services', flush=True)

stop()
call('dnf', '--disablerepo=*', '-y', 'install', packages['selinux'])
assert_services_stopped(target, units)
assert module_present()
configuration()
start()
subprocess.run(['python3', '-B', str(repo / 'packaging/test_installed_reload.py'),
                '--config', args.config], check=True)
configuration()
print('PASS packaged profile full reload and exact configuration', flush=True)

stop()
for directory in ('/run/historic-routing/frr', '/run/historic-routing'):
    if Path(directory).is_dir():
        Path(directory).rmdir()  # Fail rather than recursively deleting unknown content.
assert not Path('/run/historic-routing').exists()
start()
if args.mode == 'Enforcing':
    assert ':frr_var_run_t:' in target.run('stat', '-c', '%C', '/run/historic-routing/frr').stdout
print('PASS removed runtime root recreated and labeled by installed units', flush=True)

pids = {unit: target.run('systemctl', 'show', unit, '-p', 'MainPID', '--value').stdout for unit in units}
call('dnf', '--disablerepo=*', '-y', 'reinstall', packages['selinux'])
for unit, pid in pids.items():
    assert target.run('systemctl', 'show', unit, '-p', 'MainPID', '--value').stdout == pid
assert module_present()
healthy()
print('PASS live profile reinstall retains module and daemon PIDs', flush=True)

if args.mode == 'Enforcing':
    stop()
    call('semodule', '-s', 'targeted', '-X', '200', '-r', 'historic_routing_egp')
    call('systemctl', 'start', *reversed(units), expect=1)
    for unit in units:
        assert target.run('systemctl', 'show', unit, '-p', 'MainPID', '--value').stdout.strip() == '0'
    print('PASS missing policy blocks both service starts', flush=True)
    target.run('systemctl', 'stop', *units)
    target.run('systemctl', 'reset-failed', *units)
    call('dnf', '--disablerepo=*', '-y', 'reinstall', packages['selinux'])
    assert_services_stopped(target, units)
    start()
    print('PASS package reinstall recovers missing policy without manual relabel', flush=True)

# Preserve the package payload before erasing it for the local collision probe.
collision = Path(args.config).resolve().parent / 'collision.pp.bz2'
collision.write_bytes(target.read_bytes('/usr/share/selinux/packages/targeted/historic_routing_egp.pp.bz2'))
remove('selinux')
assert_services_stopped(target, units)
assert not module_present()
configuration()
call('semodule', '-s', 'targeted', '-X', '400', '-i', str(collision))
try:
    result = call('dnf', '--disablerepo=*', '-y', 'install', packages['selinux'], expect=1)
    assert 'local historic_routing_egp module exists' in result.stdout
    assert not module_present()
    assert target.run('rpm', '-q', 'historic-routing-selinux', check=False).returncode != 0
    print('PASS first install refuses an unowned priority-400 module', flush=True)
finally:
    call('semodule', '-s', 'targeted', '-X', '400', '-r', 'historic_routing_egp')
start(profile=False)
stop()
call('dnf', '--disablerepo=*', '-y', 'install', packages['selinux'])
start()
print('PASS profile-only erase, default restart, profile reinstall and route recovery', flush=True)

# The peer shares package files; stop it before erasing any daemon binary.
stop_peer()
socket_inode = target.run('stat', '-c', '%i', '/run/historic-routing/frr/zserv.api').stdout
zebra_pid = target.run('systemctl', 'show', units[1], '-p', 'MainPID', '--value').stdout
remove('egp')
assert target.pid() == '0'
assert target.run('systemctl', 'show', units[1], '-p', 'MainPID', '--value').stdout == zebra_pid
assert module_present()
assert target.run('stat', '-c', '%i', '/run/historic-routing/frr/zserv.api').stdout == socket_inode
print('PASS EGP erase retained the live Zebra socket inode', flush=True)
egp_conf = prefix + '/etc/frr/egpd.conf'
assert target.read_bytes(egp_conf + '.rpmsave') == original[egp_conf]
call('dnf', '--disablerepo=*', '-y', 'install', packages['egp'])
target.write_bytes(egp_conf, original[egp_conf])
start_peer()
start()
print('PASS EGP-only erase stopped egpd, retained Zebra and rpmsave, then recovered', flush=True)

stop_peer()
remove('runtime')
assert not module_present()
assert_services_stopped(target, units)
for name in packages:
    assert target.run('rpm', '-q', 'historic-routing-' + name, check=False).returncode != 0
for path, data in original.items():
    # Modified config files survive as rpm save files; verify before restoring.
    assert target.read_bytes(path + '.rpmsave') == data, path
    print('PRESERVED_RPMSAVE', Path(path).name, hashlib.sha256(data).hexdigest(), flush=True)
call('dnf', '--disablerepo=*', '-y', 'install', *packages.values())
assert_services_stopped(target, units)
for path, data in original.items():
    target.write_bytes(path, data)
start_peer()
start()
configuration()
print('PASS whole bundle erase stopped units and removed module; reinstall restored routes/config', flush=True)
