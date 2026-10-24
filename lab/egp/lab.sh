#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
# Isolated Podman lab. Set PREFIX to a matching Linux installation.
PREFIX=${PREFIX:-/root/frr-egp-build/prefix}
IMAGE=${IMAGE:-localhost/frr-23837-base:20261022}
action=${1:-status}
rsh() { local n=$1; shift; podman exec "egp-lab-r$n" "$@"; }
vty() { local n=$1; shift; rsh "$n" env LD_LIBRARY_PATH=/build/prefix/lib:/build/prefix/lib/frr /build/prefix/bin/vtysh "$@"; }
case "$action" in
up)
  if podman container exists egp-lab-r1 || podman container exists egp-lab-r2; then
    echo 'Lab already exists; use status or down first.' >&2; exit 1
  fi
  podman network create --internal --subnet 198.18.123.0/24 egp-lab-net
  for n in 1 2; do
    podman run -d --name "egp-lab-r$n" --network egp-lab-net --ip "198.18.123.$n" \
      --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN --security-opt label=disable \
      --tmpfs /build/prefix/etc:rw,mode=1777 --tmpfs /build/prefix/var:rw,mode=1777 -v "$PREFIX:/build/prefix:ro" "$IMAGE" sleep infinity
    rsh "$n" mkdir -p /tmp/egp /tmp/run /build/prefix/var/lib/frr /build/prefix/var/run/frr /build/prefix/etc/frr
    rsh "$n" touch /build/prefix/etc/frr/frr.conf /build/prefix/etc/frr/vtysh.conf
    rsh "$n" sh -c 'printf "hostname egp-lab\nlog file /tmp/zebra.log\n" > /tmp/zebra.conf'
    if [[ $n == 1 ]]; then net=10.0.0.0; host=10.0.0.1/8; peer=2; else net=172.16.0.0; host=172.16.0.1/16; peer=1; fi
    rsh "$n" ip link add stub0 type dummy
    rsh "$n" ip addr add "$host" dev stub0
    rsh "$n" ip link set stub0 up
    rsh "$n" sh -c "printf 'hostname egp-r$n\nlog file /tmp/egpd.log\negp local-as 6500$n\negp timers 2 6\negp network $net\negp neighbor 198.18.123.$peer local-address 198.18.123.$n remote-as 6500$peer\n' > /tmp/egpd.conf"
    for daemon in zebra egpd; do
      rsh "$n" env LD_LIBRARY_PATH=/build/prefix/lib:/build/prefix/lib/frr \
        "/build/prefix/sbin/$daemon" -d -u root -g root -f "/tmp/$daemon.conf" \
        -i "/tmp/$daemon.pid" -z /tmp/zserv.api --vty_socket /tmp/run
    done
  done
  echo 'Lab started. Allow about 15 seconds, then run: lab.sh status'
  ;;
status)
  for n in 1 2; do
    echo "Router $n"
    vty "$n" --vty_socket /tmp/run -d egpd -c 'show ip egp neighbors'
    vty "$n" --vty_socket /tmp/run -d zebra -c 'show ip route egp'
    rsh "$n" ip -4 route
  done
  ;;
vty)
  n=${2:?router number 1 or 2}; [[ $n == 1 || $n == 2 ]]
  podman exec -it "egp-lab-r$n" env LD_LIBRARY_PATH=/build/prefix/lib:/build/prefix/lib/frr \
    /build/prefix/bin/vtysh --vty_socket /tmp/run
  ;;
down)
  for n in 1 2; do if podman container exists "egp-lab-r$n"; then podman rm -f "egp-lab-r$n"; fi; done
  podman network rm egp-lab-net
  ;;
*) echo 'Usage: lab.sh {up|status|vty 1|vty 2|down}' >&2; exit 1 ;;
esac
