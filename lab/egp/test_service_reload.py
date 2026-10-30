#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Execute the actual RPM/DEB ExecReload commands in the isolated lab.

This checks rendered unit paths and command behavior, not package installation,
systemd supervision or SELinux policy. Called by test_reload.py.
"""
from pathlib import Path
import subprocess
import sys

import test_lab as lab


def check_templates(base, pid):
    repo = Path(__file__).resolve().parents[2]
    templates = {
        'rpm': 'packaging/rpm/units/historic-routing-egpd.service',
        'deb': 'packaging/debian/historic-routing-egp.historic-routing-egpd.service.in',
    }
    for flavor, path in templates.items():
        prefix, runtime = '/tmp/hr-egp-service-' + flavor, '/tmp/hr-egp-run-' + flavor
        # These are test-owned paths inside the exclusive disposable R1.
        lab.rsh(lab.R1, 'sh', '-c', 'test ! -e %s && test ! -e %s' % (prefix, runtime))
        lab.rsh(lab.R1, 'cp', '-a', lab.MOUNT, prefix)
        lab.rsh(lab.R1, 'mkdir', '-p', prefix + '/etc/frr', runtime)
        lab.rsh(lab.R1, 'ln', '-s', '/tmp/run', runtime + '/frr')
        lab.rsh(lab.R1, 'touch', prefix + '/etc/frr/vtysh.conf')
        text = (repo / path).read_text().replace('\\\n', ' ')
        text = text.replace('@PREFIX@', prefix).replace('@RUNSTATEDIR@', runtime)
        command = next(line[len('ExecReload='):] for line in text.splitlines()
                       if line.startswith('ExecReload='))
        assert '--daemon egpd' in command and 'kill' not in command, command

        def write(lines):
            subprocess.run(['podman', 'exec', '-i', lab.R1, 'sh', '-c',
                            'cat > ' + prefix + '/etc/frr/egpd.conf'],
                           input='\n'.join(lines) + '\n', text=True, check=True)

        def apply(ok=True):
            result = subprocess.run(['podman', 'exec', lab.R1, 'sh', '-c', command],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            assert (result.returncode == 0) == ok, (command, result.returncode, result.stdout)
            assert lab.rsh(lab.R1, 'cat', '/tmp/run/egpd.pid').strip() == pid
            assert pid in lab.alive_pids(lab.R1, 'egpd')
            return result.stdout

        try:
            write(base + ['egp network 192.168.0.0'])
            apply()
            lab.wait('rendered unit new route', lambda: lab.egp_route(lab.R2, '192.168.0.0/24'))
            assert lab.both_up() and lab.both_routes()
            apply()
            write(base + ['egp network 192.168.0.0', 'egp timers 0 1'])
            out = apply(ok=False)
            assert 'Unknown command' in out or 'failed to process' in out, out
            assert lab.both_up() and lab.both_routes()
            assert lab.egp_route(lab.R2, '192.168.0.0/24')
            write([line for line in base if not line.startswith('egp ')])
            apply()
            assert 'local AS 0' in lab.neighbors(lab.R1)
            assert not lab.has_kernel(lab.R1, lab.NET2_CIDR)
            apply()
            print('PASS ' + flavor + ' ExecReload: exact rendered paths, network/idempotence/clear/error, PID unchanged', flush=True)
        finally:
            failure = sys.exc_info()[0]
            try:
                write(base)
                apply()
                lab.wait('unit command config recovery', lambda: lab.both_up() and lab.both_routes(), timeout=60)
                print('PASS ' + flavor + ' ExecReload original configuration restored', flush=True)
            except Exception as exc:
                print('FAIL service-command recovery: ' + str(exc), flush=True)
                if failure is None:
                    raise
            finally:
                lab.rsh(lab.R1, 'rm', '-rf', prefix, runtime)
