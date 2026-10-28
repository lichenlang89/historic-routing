#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate RFC wire fixtures and assert actual TShark Lua field output."""
import argparse
import csv
import io
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile


def checksum(data):
    padded = data + b'\0' * (len(data) % 2)
    value = sum(struct.unpack('!%dH' % (len(padded)//2), padded))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return (~value) & 65535


def packet(kind, code=0, status=1, body=b''):
    data = struct.pack('!BBBBHHH', 2, kind, code, status, 0, 65001, 7) + body
    return data[:4] + struct.pack('!H', checksum(data)) + data[6:]


def frame(data):
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20+len(data), 1, 0, 64, 8, 0,
                     bytes([192, 0, 2, 1]), bytes([192, 0, 2, 2]))
    ip = ip[:10] + struct.pack('!H', checksum(ip)) + ip[12:]
    return bytes.fromhex('0200000000020200000000010800') + ip + data


def fixtures():
    cases = []
    def add(label, data, expected, trim=0):
        cases.append((label, data, expected, trim))
    for code, status in [(0, 1), (1, 2), (2, 4), (3, 5), (4, 7)]:
        body = struct.pack('!HH', 30, 120) if code <= 1 else b''
        expected = {'mode': str(status), 'cause': ''} if code <= 1 else {'cause': str(status), 'mode': ''}
        expected.update({'state': '', 'checksum_valid': 'True'})
        add('acquisition code %d' % code, packet(3, code, status, body), expected)
    add('Hello Down', packet(5, 0, 2), {'state': '2', 'checksum_valid': 'True'})
    add('I-H-U Up', packet(5, 1, 1), {'state': '1'})
    add('Poll', packet(2, body=bytes.fromhex('0000c0000200')),
        {'source_network': '192.0.2.0', 'warning': ''})
    # Independent hand-written gateway and distance blocks (RFC 904 A.4).
    body = bytes.fromhex('0100c0000200 01 03 0702 0a c63364 ff01 ac10 0001 c00003')
    update = packet(1, status=129, body=body)
    add('unsolicited grouped Update', update,
        {'state': '1', 'unsolicited': 'True', 'distance': '7,255,0',
         'network': '0a,c63364,ac10,c00003', 'warning': '', 'trailing': ''})
    for shared, hosts in [('0a000000', '000001'), ('ac100000', '0001'), ('c0000200', '01')]:
        body = bytes.fromhex('0100'+shared+hosts+'0101010a')
        add('gateway host width '+hosts, packet(1, body=body),
            {'gateway_host': hosts, 'network': '0a', 'warning': ''})
    add('internal and external gateways', packet(1, body=bytes.fromhex(
        '0101c0000200 010101010a 02010201ac10')),
        {'internal_gateways': '1', 'external_gateways': '1', 'distance': '1,2', 'warning': ''})
    quoted = bytes.fromhex('020300000000fde90007001e')
    add('Error quotes three 32-bit words', packet(8, status=130, body=struct.pack('!H', 2)+quoted),
        {'error_reason': '2', 'bad_header': quoted.hex(), 'trailing': '',
         'unsolicited': 'True', 'state': '2', 'warning': ''})
    add('short Error', packet(8, body=struct.pack('!H', 1)+quoted[:10]),
        {'warning': 'contains:Truncated Error', 'bad_header': quoted[:10].hex()})
    bad = bytearray(packet(5))
    bad[-1] ^= 1
    add('bad checksum', bytes(bad), {'checksum_valid': 'False', 'expert': 'contains:Bad EGP checksum'})
    add('snaplen truncation', packet(3, body=struct.pack('!HH', 30, 120)),
        {'checksum_valid': '', 'warning': 'contains:Capture truncated'}, trim=1)
    # Every incomplete prefix, with valid checksums where a header exists.
    for size in range(1, len(update)):
        data = update[:size]
        if size >= 10:
            data = data[:4] + b'\0\0' + data[6:]
            data = data[:4] + struct.pack('!H', checksum(data)) + data[6:]
        add('Update truncated at %d' % size, data, {'warning': 'contains:Truncated'})
    add('invalid class', packet(1, body=bytes.fromhex('0100c0000200 01010101f0')),
        {'warning': 'contains:Invalid classful'})
    add('truncated distance block', packet(1, body=bytes.fromhex('0100c0000200 01ff')),
        {'warning': 'contains:Truncated distance'})
    return cases


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--tshark', default=os.environ.get('TSHARK', 'tshark'))
    ap.add_argument('--dissector', type=Path, default=Path(__file__).with_name('egp_dissector.lua'))
    args = ap.parse_args()
    tshark = shutil.which(args.tshark)
    if not tshark:
        ap.error('TShark not found; use --tshark PATH or TSHARK')
    version = subprocess.check_output([tshark, '--version'], encoding='utf8', errors='replace').splitlines()[0]
    match = re.search(r'\b(\d+)\.(\d+)\.', version)
    if not match or int(match[1]) < 4:
        ap.error('Wireshark/TShark 4.0 or later is required')
    print(version, flush=True)
    cases = fixtures()
    fields = ['type', 'mode', 'cause', 'state', 'unsolicited', 'source_network',
              'internal_gateways', 'external_gateways', 'gateway_host', 'distance',
              'network', 'bad_header', 'trailing', 'warning', 'checksum_valid', 'error_reason']
    with tempfile.TemporaryDirectory(prefix='hr-wireshark-') as tmp:
        root = Path(tmp)
        config, plugins = root/'config', root/'plugins'
        config.mkdir(); plugins.mkdir()
        env = os.environ.copy()
        env['WIRESHARK_CONFIG_DIR'] = str(config)
        env['WIRESHARK_PLUGIN_DIR'] = str(plugins)
        capture = root/'fixtures.pcap'
        with capture.open('wb') as out:
            out.write(struct.pack('<IHHIIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
            for i, (_, data, _, trim) in enumerate(cases, 1):
                data = frame(data)
                out.write(struct.pack('<IIII', i, 0, len(data)-trim, len(data)))
                out.write(data[:-trim] if trim else data)
        cmd = [tshark, '-n', '-X', 'lua_script:'+str(args.dissector.resolve()),
               '-r', str(capture), '-T', 'fields', '-E', 'occurrence=a', '-E', 'aggregator=,']
        for name in fields:
            cmd += ['-e', 'egp_custom.'+name]
        cmd += ['-e', '_ws.expert.message']
        result = subprocess.run(cmd, env=env, capture_output=True, encoding='utf8', errors='replace')
        if result.returncode or re.search(r'Lua(?: Error|:)', result.stderr+result.stdout):
            raise AssertionError('TShark/Lua error:\n'+result.stderr+'\n'+result.stdout)
        rows = list(csv.reader(io.StringIO(result.stdout), delimiter='\t'))
        if len(rows) != len(cases):
            raise AssertionError('wrong frame count: %d != %d' % (len(rows), len(cases)))
        for (label, _, expected, _), row in zip(cases, rows):
            actual = dict(zip(fields + ['expert'], row))
            for name, value in expected.items():
                got = actual.get(name, '')
                ok = value.removeprefix('contains:') in got if value.startswith('contains:') else got == value
                if not ok:
                    raise AssertionError('%s: %s expected %r, got %r' % (label, name, value, got))
    print('Wireshark EGP: %d wire fixtures passed; no Lua errors' % len(cases))


if __name__ == '__main__':
    main()
