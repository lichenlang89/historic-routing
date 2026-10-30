#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Exercise driver mains with real file I/O and controlled service transactions.

No package is installed and no real service is touched. Separate installed-
package labs validate systemd behavior; these cases inject faults into the
drivers that a healthy package cannot reliably expose.
"""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import test_installed_reload as installed
import test_package_lifecycle as lifecycle

RealNode = installed.Node


class DriverRegression(unittest.TestCase):
    def exercise(self, driver, data, fault=None, fail_transaction=1):
        with tempfile.TemporaryDirectory() as work:
            prefix = Path(work) / 'prefix'
            confdir = prefix / 'etc/frr'
            confdir.mkdir(parents=True)
            files = {confdir / name: data for name in
                     ('frr.conf', 'egpd.conf', 'vtysh.conf', 'daemons')}
            for path, original in files.items():
                path.write_bytes(original)
            backend = Path(work) / 'backend.json'
            backend.write_text(json.dumps({
                'prefix': str(prefix), 'packages': 'deb',
                'ip1': '198.18.251.11', 'ip2': '198.18.251.12',
                'target': {'container': 'target'},
                'peer': {'container': 'peer'},
            }))
            state = {'version': '1', 'transactions': 0,
                     'egpd': ('active', '101'), 'zebra': ('active', '102')}
            real = RealNode({'netns': 'unused'}, str(prefix))

            class FakeNode:
                def __init__(self, config, prefix):
                    self.config, self.prefix = config, prefix
                    self.unit = 'historic-routing-egpd.service'
                    self.socket = '/run/historic-routing/frr'

                def pid(self):
                    return state['egpd'][1]

                def run(self, *args, **kwargs):
                    # Crucially, file reads/writes use the actual Node.run
                    # subprocess path, including its binary/text selection.
                    if args[0] in ('cat', 'tee', 'test'):
                        return real.run(*args, **kwargs)
                    rc, output = 0, ''
                    if args[0] == 'dpkg-query':
                        output = (state['version'] + '\n') * 2
                    elif args[0] == 'systemctl':
                        operation = args[1]
                        if operation == 'stop':
                            state['egpd'] = state['zebra'] = ('inactive', '0')
                        elif operation == 'start':
                            state['egpd'], state['zebra'] = ('active', '101'), ('active', '102')
                        elif operation == 'show':
                            service = 'zebra' if 'zebra' in args[2] else 'egpd'
                            active, pid = state[service]
                            if '--value' in args:
                                output = pid + '\n'
                            else:
                                output = ('ActiveState=%s\nMainPID=%s\n'
                                          'ExecReload=frr-reload.py --daemon egpd\n' % (active, pid))
                    elif args[0] == 'apt-get':
                        rc = 1  # Unmatched single-component dependency probe.
                    elif args[0] == 'env':
                        state['transactions'] += 1
                        if fault == 'transaction-error':
                            raise RuntimeError('injected transaction failure')
                        state['version'] = '1' if args[-1] == 'old-egp' else '2'
                        if fault and state['transactions'] == fail_transaction:
                            service, active, pid = fault
                            state[service] = active, pid
                    else:
                        raise AssertionError('Unexpected external operation: %r' % (args,))
                    return subprocess.CompletedProcess(args, rc, output)

                def read_bytes(self, path):
                    return RealNode.read_bytes(self, path)

                def write_bytes(self, path, data):
                    return RealNode.write_bytes(self, path, data)

                def vty(self, *args):
                    return ''

            def steps(*args):
                (confdir / 'egpd.conf').write_bytes(b'hostname changed\n')
                if fault == 'reload-error':
                    raise RuntimeError('injected reload failure')

            def wait(message, predicate, **kwargs):
                self.assertTrue(predicate(), message)

            argv = [str(driver.__file__), '--config', str(backend)]
            if driver is lifecycle:
                argv += ['--old', 'old-runtime', 'old-egp', '--new', 'new-runtime', 'new-egp']
            error = None
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(installed, 'Node', FakeNode))
                stack.enter_context(mock.patch.object(sys, 'argv', argv))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                # Restore globals assigned by main as well as the faked APIs.
                for module, names in ((installed.lab, ('rsh', 'vty', 'R1', 'R2', 'IP1', 'IP2', 'AS1', 'AS2')),
                                      (installed.cases, ('write_conf', 'reload', 'egpd_pid'))):
                    for name in names:
                        stack.enter_context(mock.patch.object(module, name, getattr(module, name)))
                for name in ('both_up', 'both_routes', 'has_kernel'):
                    stack.enter_context(mock.patch.object(installed.lab, name, return_value=True))
                stack.enter_context(mock.patch.object(installed.lab, 'wait', wait))
                stack.enter_context(mock.patch.object(installed.cases, 'running_config', return_value=[]))
                stack.enter_context(mock.patch.object(installed.cases, 'steps', steps))
                stack.enter_context(mock.patch.object(installed.cases, 'restore', return_value=None))
                try:
                    self.assertEqual(driver.main(), 0)
                except (AssertionError, RuntimeError) as exc:
                    error = exc
            # Inspect filesystem bytes independently of the driver's own read
            # path, so newline normalization cannot make the assertion pass.
            for path, original in files.items():
                self.assertEqual(path.read_bytes(), original, path.name)
            return error, state['transactions']

    def test_configuration_bytes_on_success(self):
        for driver in (installed, lifecycle):
            for data in (b'hostname original\r\n! comment  \r\n',
                         b'hostname original\n! comment  \n',
                         b'hostname original\r\n! no final newline  '):
                with self.subTest(driver=driver.__name__, data=data):
                    error, _ = self.exercise(driver, data)
                    self.assertIsNone(error)

    def test_configuration_bytes_after_failure(self):
        for driver, fault in ((installed, 'reload-error'), (lifecycle, 'transaction-error')):
            with self.subTest(driver=driver.__name__):
                error, _ = self.exercise(driver, b'hostname original\r\n! comment  \r\n', fault)
                self.assertIsInstance(error, RuntimeError)
                self.assertIn('injected', str(error))

    def test_each_unit_is_rejected_after_each_transaction(self):
        for service in ('egpd', 'zebra'):
            for active, pid in (('active', '999'), ('activating', '0'), ('inactive', '999')):
                for transaction in (1, 2, 3):
                    with self.subTest(service=service, state=active, pid=pid, transaction=transaction):
                        error, count = self.exercise(
                            lifecycle, b'hostname original\n', (service, active, pid), transaction)
                        self.assertIsInstance(error, AssertionError)
                        self.assertEqual(count, transaction)
                        self.assertIn('historic-routing-' + service + '.service', str(error))


if __name__ == '__main__':
    unittest.main(verbosity=2)
