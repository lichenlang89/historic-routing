#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -Eeuo pipefail
HR_SCRIPT=test-egp.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
hr_proto_load egp
cd "$HR_REPO_ROOT"
sha256sum -c patches/frr/SHA256SUMS
sha256sum -c protocols/egp/evidence/SOURCES.sha256
./scripts/check-allocations.sh
tmp="$(mktemp -d)"
trap 'rm -f "$tmp/test-egp"; rmdir "$tmp"' EXIT
sources=()
for f in $P_SOURCES; do
    case "$f" in
        "$P_DAEMON.c") ;;
        *.c) sources+=("protocols/egp/src/$f") ;;
    esac
done
"${CC:-cc}" -std=c11 -g -O1 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -Iprotocols/egp/src "${sources[@]}" protocols/egp/tests/test_packet.c \
    -o "$tmp/test-egp"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$tmp/test-egp"
