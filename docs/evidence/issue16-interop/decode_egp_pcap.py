# SPDX-License-Identifier: GPL-2.0-or-later
"""Decode EGP frames from a tcpdump pcap (Ethernet or Linux SLL2 link layer).

Layout follows protocols/egp/src/egp_packet.c (RFC 904 / RFC 888):
  header 10 bytes: version, type, code, status, checksum, AS, seq
  Update: [int-gw count][ext-gw count][shared net 4B] then per gateway
          (4-n bytes of gateway suffix, n = classlen(shared)), nd, then
          nd x (distance, nr, nr x classful network bytes).
"""
import struct
import sys

TYPES = {1: "Update", 2: "Poll", 3: "Acquire", 5: "Reach", 8: "Error"}
IPV4 = 0x0800


def classlen(first_octet):
    if first_octet < 128:
        return 1
    if first_octet < 192:
        return 2
    if first_octet < 224:
        return 3
    return 4


def ip(b):
    return ".".join(str(x) for x in b)


def decode(payload):
    typ, code, status = payload[1], payload[2], payload[3]
    asn, seq = struct.unpack("!HH", payload[6:10])
    out = {
        "type": TYPES.get(typ, str(typ)),
        "code": code,
        "status": status & 0x7F,
        "U": int(bool(status & 0x80)),
        "as": asn,
        "seq": seq,
        "routes": [],
        "timers": None,
    }
    if typ == 3 and code <= 1 and len(payload) >= 14:
        out["timers"] = struct.unpack("!HH", payload[10:14])
    if typ == 1:
        nint, next_ = payload[10], payload[11]
        shared = payload[12:16]
        n = classlen(shared[0])
        pos = 16
        for g in range(nint + next_):
            gw = bytearray(shared)
            gw[n:] = payload[pos:pos + 4 - n]
            gw = bytes(gw)
            pos += 4 - n
            nd = payload[pos]
            pos += 1
            for _ in range(nd):
                distance = payload[pos]
                nr = payload[pos + 1]
                pos += 2
                for _ in range(nr):
                    k = classlen(payload[pos])
                    net = bytearray(4)
                    net[:k] = payload[pos:pos + k]
                    pos += k
                    out["routes"].append(
                        (ip(bytes(net)), ip(gw), distance,
                         "ext" if g >= nint else "int"))
    return out


def frames(path):
    data = open(path, "rb").read()
    magic = data[:4]
    if magic == bytes((0xD4, 0xC3, 0xB2, 0xA1)):
        endian = "<"
    elif magic == bytes((0xA1, 0xB2, 0xC3, 0xD4)):
        endian = ">"
    elif magic == bytes((0x4D, 0x3C, 0xB2, 0xA1)):
        endian = "<"
    else:
        endian = ">"
    linktype = struct.unpack(endian + "I", data[20:24])[0]
    off = 24
    while off + 16 <= len(data):
        ts, tus, caplen, _orig = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        pkt = data[off:off + caplen]
        off += caplen
        ifindex = 0
        if linktype == 1:                       # Ethernet
            if len(pkt) < 34 or struct.unpack("!H", pkt[12:14])[0] != IPV4:
                continue
            pkt = pkt[14:]
        elif linktype == 276:                   # Linux SLL2
            if len(pkt) < 20 or struct.unpack("!H", pkt[0:2])[0] != IPV4:
                continue
            ifindex = struct.unpack("!I", pkt[4:8])[0]
            pkt = pkt[20:]
        elif linktype != 101 and linktype != 12 and linktype != 228:
            continue                            # raw IP link layers: no header
        if len(pkt) < 20 or pkt[9] != 8:
            continue
        ihl = (pkt[0] & 0x0F) * 4
        ip_len = struct.unpack("!H", pkt[2:4])[0]
        ident = struct.unpack("!H", pkt[4:6])[0]
        src, dst = ip(pkt[12:16]), ip(pkt[16:20])
        stamp = "%d.%06d" % (ts, tus)
        yield stamp, ident, ifindex, src, dst, pkt[ihl:ip_len]


def main(path):
    seen = {}
    order = []
    for stamp, ident, ifindex, src, dst, payload in frames(path):
        key = (ident, src, dst, payload)
        if key in seen:
            seen[key]["copies"] += 1
            seen[key]["ifindexes"].add(ifindex)
            continue
        rec = {"stamp": stamp, "src": src, "dst": dst, "len": len(payload),
               "copies": 1, "ifindexes": {ifindex}, "decoded": decode(payload)}
        seen[key] = rec
        order.append(rec)
    total = sum(r["copies"] for r in order)
    print("unique=%d captured=%d duplicates=%d" % (len(order), total, total - len(order)))
    for r in order:
        d = r["decoded"]
        extra = ""
        if d["timers"]:
            extra = " hello/poll=%d/%d" % d["timers"]
        print("%s %15s -> %-15s %-8s code=%d status=%d U=%d AS=%d seq=%d len=%d if=%s%s"
              % (r["stamp"], r["src"], r["dst"], d["type"], d["code"], d["status"],
                 d["U"], d["as"], d["seq"], r["len"],
                 ",".join(str(i) for i in sorted(r["ifindexes"])), extra))
        for net, gw, dist, kind in d["routes"]:
            print("        route %s gw %s distance %d (%s)" % (net, gw, dist, kind))


if __name__ == "__main__":
    main(sys.argv[1])
