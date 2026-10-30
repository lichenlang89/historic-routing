.. SPDX-License-Identifier: GPL-2.0-or-later

EGPD
====

.. include:: defines.rst
.. |DAEMON| replace:: egpd

SYNOPSIS
--------

|DAEMON| |synopsis-options-hv|

|DAEMON| |synopsis-options|

DESCRIPTION
-----------

``egpd`` is the experimental historic-routing RFC 904 stub gateway.
It uses raw IPv4 protocol 8 and sends learned routes to a matching Zebra
over ZAPI. Zebra, libfrr and vtysh must come from the same build.

Configure ``egp local-as``, ``egp timers``, ``egp network`` and
``egp neighbor`` at the top configuration level. Defaults are AS 0 and
Hello/Poll 30/120 seconds. ``no egp local-as`` and ``no egp timers`` reset
these defaults after all neighbors finish Cease cleanup.

OPTIONS
-------

.. include:: common-options.rst

RELOADING
---------

The historic-routing systemd unit reloads ``egpd.conf`` using the matching
``frr-reload.py --reload --daemon egpd`` with explicit installation and
socket paths. SIGHUP is not a reload interface. Network-only edits preserve
adjacency; AS/timer changes rebuild affected adjacencies while preserving
the process PID and may wait for the 120-second Cease abort. Syntax errors
fail before changes; semantic errors may partially apply. Reapply a saved
configuration to recover and inspect neighbors and RIB/kernel routes.

LIMITATIONS
-----------

Default VRF, classful IPv4, 16 peers and 255 gateway candidates per peer.
Interior/exterior gateways on the common network are accepted, with stable
candidate selection rather than distance comparison across ASes. This is
not a core relay and does not import other protocols from the local RIB.
No CIDR, IPv6 or authentication. Use isolated experimental networks.

FILES
-----

|INSTALL_PREFIX_SBIN|/egpd
   Daemon binary.

|INSTALL_PREFIX_ETC|/egpd.conf
   Independent daemon configuration, used by the package service.

.. include:: epilogue.rst
