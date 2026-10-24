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

Start with FRR's normal Linux build dependencies (see `doc/developer/`). Add
`--enable-egpd` to configure; it is disabled by default. Build zebra, egpd and
vtysh together: the additional ZAPI route type requires matching binaries.

```sh
./bootstrap.sh
mkdir build && cd build
../configure --enable-egpd --disable-doc
make -j4
make egpd/test_packet
./egpd/test_packet
sudo make install
```

Standalone codec checks, including sanitizers:

```sh
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  egpd/egp_packet.c egpd/test_packet.c -o /tmp/test-egp
/tmp/test-egp
```

Enable `egpd=yes` in the installed FRR daemons file if using the FRR service.
On Linux the daemon needs `CAP_NET_RAW`; zebra needs its normal privileges.
The VTY is a Unix socket, with no additional TCP listener.

## Configuration

Commands live at the top configuration level. Configure AS/timers before
neighbors. Remove neighbors before changing the AS or timers.

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
show ip route egp
show running-config
configure terminal
no egp network 10.0.0.0
no egp neighbor 198.18.123.2
```

Default timers are 30/120 seconds. The 2/6 setting is for quick lab feedback.
Both capability modes are supported; with two instances of this daemon the
lower AS becomes active. Expect roughly three Hello intervals to establish
reachability, plus a Poll interval for routes. Network withdrawal takes effect
on the next Poll. Dead neighbors and stale Updates cause route withdrawal.
Reconnect to zebra replays the current learned routes.

## Ready-to-play Podman lab

`lab.sh` uses two isolated containers, dummy stub interfaces and an internal
198.18.123.0/24 network. It never enables forwarding on the host. It needs a
matching Linux installation and a runtime image containing its dependencies,
iproute2 and Python 3. The defaults refer to the prepared development host.

```sh
bash egpd/lab.sh up
bash egpd/lab.sh status
bash egpd/lab.sh vty 1
bash egpd/lab.sh vty 2
python3 egpd/test_lab.py
bash egpd/lab.sh down
```

`PREFIX=/path/to/install IMAGE=your-runtime-image bash egpd/lab.sh up` overrides
the installation and image. `test_lab.py` changes and restores the lab network
advertisement, restarts lab daemons and tests data-plane traffic; run it only
against these disposable containers. The lab remains running after tests.

## Deliberate limits

* Default VRF, IPv4 class A/B/C networks only, 16 neighbors, 255 advertised or
  learned networks per peer. No CIDR, IPv6, default route or same-AS adjacency.
* Explicit `egp network` announcements are operator assertions. They are not
  automatically derived from connected routes, and stay advertised if the
  local interface disappears. No redistribution, route maps or authentication.
* Accepts only the configured peer's own gateway in Updates. Third-party/core
  transit and unsolicited Updates are not imported. Metrics are not used to
  compare different autonomous systems; first configured live peer wins.
* Sends a best-effort Cease on deletion/shutdown, without a Cease retry state.
  Error packets are validated but advisory errors are not generated.
* No interoperability certification with historical EGP implementations,
  packaging validation or complete upstream FRR regression suite yet.

The initial three-file sketch remains in the original workspace `egpd/`.
This implementation is maintained in the FRR fork's `egpd/` directory.
