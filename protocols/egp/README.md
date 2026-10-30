# Experimental EGP for FRRouting

This branch adds a native `egpd` linked with libfrr. EGP uses raw IPv4
protocol 8. Learned routes go through ZAPI to zebra (route type `egp`, display
code `G`, administrative distance 140); zebra resolves next hops and installs
kernel routes. `egpd` never modifies the kernel routing table directly.

This is a **stub-gateway lab implementation**, not a complete RFC 904 core
gateway or a production routing protocol. Wire formats follow
[RFC 904 Appendix A](https://www.rfc-editor.org/rfc/rfc904.html#appendix-A).
It replaces the initial prototype's acquisition/reachability confusion,
missing Poll reserved field, incorrect Update field order and fixed-width
network encoding.

## Build

From the historic-routing repository root:

```sh
./scripts/test-egp.sh
./scripts/build.sh --jobs 4
./scripts/verify.sh --build-only --build-root "$PWD/build" --jobs 4
```

The scripts apply the fixed FRR baseline and register egpd with
``--enable-egpd``. Build zebra, egpd, libfrr and vtysh together. On Linux
egpd needs CAP_NET_RAW. The VTY uses a Unix socket without a TCP listener.
The maintained user/man sources are in [doc/](doc/); source integration copies
them to FRR's `doc/user/egp.rst` and `doc/manpages/frr-egpd.rst`.

## Configuration

Commands live at the top configuration level. Configure AS/timers before
neighbors. Remove neighbors and wait for Cease cleanup before directly changing the AS or
timers. `no egp local-as [AS]` resets AS to 0; `no egp timers [HELLO POLL]`
resets timers to 30/120. Reapplying the current values is a no-op.
Package `systemctl reload historic-routing-egpd` uses the matching
`frr-reload.py --reload --daemon egpd`, with explicit bindir/confdir/rundir/socket
paths. Reload drains old neighbors before AS/timer changes and restores target
neighbors; network-only changes preserve adjacency and the process PID.
Do not send HUP. Syntax errors fail before changes; runtime semantic errors can
partially apply, return nonzero and require correcting or reapplying the saved
configuration. A global change may wait for the 120-second Cease abort.

```text
egp local-as 65001
egp timers 2 6
egp network 10.0.0.0
egp neighbor 198.18.123.2 local-address 198.18.123.1 remote-as 65002
```

Peer configuration uses AS 65002, local address 198.18.123.2, neighbor
198.18.123.1 / AS 65001, and `egp network 172.16.0.0`.

```text
show ip egp neighbors
show ip egp neighbors detail
show ip egp neighbors json
show ip egp neighbors 198.18.123.2
show ip route egp
show running-config
clear ip egp neighbor 198.18.123.2
clear ip egp neighbor *
configure terminal
no egp network 10.0.0.0
no egp neighbor 198.18.123.2
```

`detail` 每行一条学到的网络（前缀 / distance / gateway / 遗漏次数 / age），
`json` 输出 `localAs`、`zebraConnected`、每个邻居的定时器剩余与 tx/rx 计数器。

Default timers are 30/120 seconds. The 2/6 setting is for quick lab feedback.
Hello and Poll minima are independent; Poll may be shorter than Hello.
After acquisition, abort holds cover at least four negotiated Hello intervals;
the default 120-second acquisition and 3600-second established holds are floors.
Both capability modes are supported; with two instances of this daemon the
lower AS becomes active. Expect roughly three Hello intervals to establish
reachability, plus a Poll interval for routes. Explicit distance 255 withdraws
immediately; an omitted network is removed after three accepted Updates.
Dead neighbors and stale Updates also cause route withdrawal.
Reconnect to zebra replays the current learned routes.

Error reasons 1–4 are generated (RFC 904 sections 4.5 and A.5).
Error messages (type 8) report an unusable length or invalid Type/Code/Status
(reason 1), a bad data field such as a zero interval or an unparsable Update
body (reason 2), a Poll naming a net this gateway does not serve (reason 3), and
Hellos arriving closer than `max(1, hello/2)` seconds (reason 4). Polls are
deliberately **not** rate-limited: RFC 904 section 4.4 makes a repeated Poll a
legal flow that spends the unsolicited Update budget. A received Error is
advisory only - it is counted, does not change state, and is never answered with
another Error. Refuse (Acquisition code 2) is decoded and honoured, but this
implementation does not send one: the only trigger left would be an invented
timer cap, and RFC 904 has none (a cap would refuse still-valid timer
configurations). `show ip egp neighbors detail` prints the error counters.

## Ready-to-play Podman lab

`lab.sh` uses two isolated containers, dummy stub interfaces and an internal
198.18.123.0/24 network. It never enables forwarding on the host. It needs a
matching Linux installation and a runtime image containing its dependencies,
iproute2 and Python 3. The defaults refer to the prepared development host.

```sh
cd lab/egp
export LAB_PREFIX=/path/to/matching/install
export LAB_IMAGE=localhost/historic-routing-lab:egp
export LAB_TIMERS="1 1"
./lab.sh build
./lab.sh up
./lab.sh status
./lab.sh test-updates
./lab.sh test-protocol
./lab.sh reload
./lab.sh test-timers
./lab.sh test
./lab.sh down
```

See [the lab manual](../../lab/README.md) for all `LAB_*` parameters and
exclusive resource names. Tests change and restore only their disposable
containers. `test-protocol` covers mixed interior/exterior gateway lists,
invalid next hops, candidate failover and omission aging. `reload` covers
network changes, complete deletion, idempotence, AS/timer changes, syntax and
semantic failures, and recovery.

## Deliberate limits

* Default VRF, IPv4 class A/B/C networks only, 16 neighbors, 255 advertised or
  learned (network, gateway) candidates per peer. No CIDR, IPv6, default route or same-AS adjacency.
* Explicit `egp network` announcements are operator assertions. They are not
  automatically derived from connected routes, and stay advertised if the
  local interface disappears. No redistribution, route maps or authentication.
* Accepts interior and exterior gateway lists on the common classful network
  (RFC 904 section 4.4/A.4; RFC 888 sections 5/8). The router's own address,
  network/broadcast gateways, ambiguous duplicate claims from one gateway and
  excess capacity reject the whole Update without changing routes or omissions.
  Distinct gateways may advertise the same network. Each candidate withdraws
  or ages independently; stable first-live peer/candidate order wins, without
  comparing distances across ASes. Solicited/unsolicited receive windows remain
  enforced. Receiving indirect gateways does not add core relay/re-advertisement.
* Deletion/shutdown uses Cease with 30-second retries and a 120-second abort.
  Duplicate Poll replies share one extra-Update allowance with triggered
  Updates; once spent, further duplicate Polls are ignored until a new Poll.
  Error reasons 1–4 are generated; received Error packets are advisory only.
* Other daemons can use the `redistribute egp` name mapping. egpd itself does
  not import other protocols from the local RIB; announcements remain explicit.
* No interoperability certification with historical implementations, prolonged
  loss/reordering/concurrency stress or SELinux frr_t execution validation.
  See the [current handoff](../../docs/plan/issue-14-handoff.md) for executed
  tests, packaging/service boundaries and known upstream test failures.

Maintenance sources live in `protocols/egp/src/`; generated FRR build copies are not the maintenance source.
