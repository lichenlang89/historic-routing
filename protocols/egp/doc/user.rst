.. SPDX-License-Identifier: GPL-2.0-or-later

.. _egp:

Experimental EGP
================

``egpd`` implements an experimental RFC 904 stub gateway over raw IPv4
protocol 8. Build it with ``--enable-egpd`` and use zebra, vtysh and libfrr
from the same build. Zebra owns the RIB and kernel routes. EGP routes use
type ``egp``, display code ``G`` and administrative distance 140.

Configuration
-------------

Commands are at the top configuration level::

   egp local-as 65001
   egp timers 2 6
   egp network 10.0.0.0
   egp neighbor 198.18.123.2 local-address 198.18.123.1 remote-as 65002

``egp local-as (1-65535)`` sets the local AS. ``no egp local-as [AS]``
resets it to zero, which prevents adding neighbors. Distinct local and
remote ASes and addresses on the same classful network are required.

``egp timers HELLO POLL`` sets independent minima in seconds, each 1-65535.
``no egp timers [HELLO POLL]`` restores 30/120. Direct CLI changes require
all neighbors, including pending Cease cleanup, to be removed first.
Reapplying the same values is a no-op.

``[no] egp network A.B.C.D`` controls explicit classful announcements.
These are operator assertions, independent of the local RIB and interfaces.
``no egp neighbor A.B.C.D`` starts Cease; the peer is released on a matching
acknowledgement or after its 120-second abort timer.

Observability and reload
------------------------

Use ``show ip egp neighbors [detail] [json]``,
``show ip egp neighbors A.B.C.D [json]`` and ``show ip route egp``.
The detail and JSON views expose each gateway candidate, distance, omission
count and interior/exterior list origin. ``clear ip egp neighbor A.B.C.D``
or ``clear ip egp neighbor *`` restarts acquisition.

The historic-routing package service reads ``egpd.conf`` on start and uses
``frr-reload.py --reload --daemon egpd`` on ``systemctl reload
historic-routing-egpd``. The unit supplies its installation's bindir,
confdir, writable rundir and VTY socket. Do not send SIGHUP directly.
Network-only edits keep the PID and adjacency. AS/timer changes deliberately
remove and drain old neighbors before applying globals and target neighbors;
this can take 120 seconds. Reload syntax errors return nonzero before changes.
Runtime semantic failures return nonzero and can leave a partial configuration;
correct the file or reapply the saved previous configuration and verify both
neighbors and routes. Reload is not a transaction or an implicit restart.

Protocol scope
--------------

RFC 904 section 4.4 and Appendix A.4, and RFC 888 sections 5 and 8, permit
a stub to receive multiple gateways on the common network. Both interior
and exterior lists are accepted. Network/broadcast addresses and this router's
own address are invalid next hops; an invalid Update leaves routes, omission
counts and receive credit unchanged. Each (network, gateway) candidate ages
independently; distance 255 withdraws it immediately and three accepted
omissions remove it. Ambiguous duplicate claims from one gateway are rejected.
The first surviving candidate wins in stable peer/candidate order. Distances
are not compared between ASes. Learned routes are not relayed or announced
to other neighbors.

The implementation supports the default VRF, class A/B/C IPv4 networks,
16 neighbors and 255 advertised networks or learned gateway candidates per
peer. CIDR, IPv6, authentication, route maps and full core-gateway behavior
are outside this implementation's scope. The historic protocol's classful
scope is not an implementation defect. ``redistribute egp`` name mapping
lets other daemons identify EGP routes; egpd does not import other protocols
from the local RIB. Error reasons 1-4 are generated; reason 5 and Acquisition
Refuse generation are not implemented.

Validation
----------

From the historic-routing repository root, use ``scripts/test-egp.sh`` and
``scripts/verify.sh --build-only``. The isolated Podman lab lives in
``lab/egp``: after ``./lab.sh up``, run ``test-updates``, ``test-protocol``,
``reload``, ``test-timers`` and ``test`` subcommands; finish with ``down``.
Use distinct ``LAB_NAME_PREFIX``, ``LAB_NET``, ``LAB_SUBNET``, ``LAB_IP1/2``
and ``LAB_RUNDIR`` for concurrent labs. Historical implementation
interoperability, prolonged loss/reordering/concurrency stress and SELinux
``frr_t`` execution require separate validation.
