// SPDX-License-Identifier: GPL-2.0-or-later
/* Experimental RFC 904 stub gateway. zebra owns RIB and kernel routes. */
#include "egp_age.h"
#include "egp_packet.h"
#include "egp_reach.h"
#include "egp_state.h"
#include "egp_update.h"
#include "lib/command.h"
#include "lib/frrevent.h"
#include "lib/json.h"
#include "lib/libfrr.h"
#include "lib/log.h"
#include "lib/network.h"
#include "lib/privs.h"
#include "lib/sigevent.h"
#include "lib/version.h"
#include "lib/vrf.h"
#include "lib/zclient.h"
#include <time.h>
#include <zebra.h>

#define MAX_PEERS 16
static const char *const states[] = {"Idle", "Acquisition", "Down", "Up", "Cease"};
struct neighbor {
	bool used, active, hello_pending, poll_pending, deleting;
	int fd;
	struct in_addr peer, local, shared;
	uint16_t as, seq, request_seq, hello_seq, poll_seq, stop_seq, hello, poll;
	enum state state;
	time_t next_hello, next_poll, last_update, last_seen, abort_at;
	struct egp_reach reach;
	struct egp_update_window updates;
	struct event *read;
	size_t count;
	struct egp_route routes[EGP_MAX_ROUTES];
	uint8_t misses[EGP_MAX_ROUTES];
	/* Observability only: never consulted by the protocol state machine. */
	uint32_t hellos_tx, hellos_rx, polls_tx, polls_rx, updates_tx, updates_rx;
	uint32_t errors_tx, errors_rx;
	time_t last_hello_rx;
};
static struct neighbor peers[MAX_PEERS];
static struct egp_route networks[EGP_MAX_ROUTES];
static size_t network_count;
static uint16_t local_as, hello_interval = 30, poll_interval = 120;
static struct event_loop *master;
static struct event *ticker;
static struct zclient *zc;
static bool shutting_down;
static FRR_NORETURN void finish(void);
static zebra_capabilities_t caps[] = {ZCAP_NET_RAW};
static struct zebra_privs_t privileges = {
#if defined(FRR_USER) && defined(FRR_GROUP)
    .user = FRR_USER,
    .group = FRR_GROUP,
#endif
#ifdef VTY_GROUP
    .vty_group = VTY_GROUP,
#endif
    .caps_p = caps,
    .cap_num_p = array_size(caps),
};
static time_t now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec;
}
/* A single deterministic candidate per prefix avoids cross-peer deletes. */
static void route_send(const struct egp_route *r, bool add)
{
	struct zapi_route api = {0};
	api.vrf_id = VRF_DEFAULT;
	api.type = ZEBRA_ROUTE_EGP;
	api.safi = SAFI_UNICAST;
	api.prefix.family = AF_INET;
	api.prefix.prefixlen = egp_classlen(r->net) * 8;
	api.prefix.u.prefix4 = r->net;
	SET_FLAG(api.message, ZAPI_MESSAGE_NEXTHOP);
	SET_FLAG(api.message, ZAPI_MESSAGE_DISTANCE);
	SET_FLAG(api.message, ZAPI_MESSAGE_METRIC);
	api.distance = 140;
	api.metric = r->distance;
	api.nexthop_num = 1;
	api.nexthops[0].type = NEXTHOP_TYPE_IPV4;
	api.nexthops[0].vrf_id = VRF_DEFAULT;
	api.nexthops[0].gate.ipv4 = r->gateway;
	SET_FLAG(api.flags, ZEBRA_FLAG_ALLOW_RECURSION);
	zclient_route_send(add ? ZEBRA_ROUTE_ADD : ZEBRA_ROUTE_DELETE, zc, &api);
}
static const struct egp_route *best(struct in_addr net)
{
	size_t i, j;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used && peers[i].state == UP)
			for (j = 0; j < peers[i].count; j++)
				if (peers[i].routes[j].net.s_addr == net.s_addr)
					return &peers[i].routes[j];
	return NULL;
}
static void replace_routes(struct neighbor *n, const struct egp_route *routes, size_t count)
{
	struct egp_route old[EGP_MAX_ROUTES];
	size_t old_count = n->count, i;
	memcpy(old, n->routes, old_count * sizeof(*old));
	n->count = count;
	if (!count)
		memset(n->misses, 0, sizeof(n->misses));
	if (count)
		memcpy(n->routes, routes, count * sizeof(*routes));
	for (i = 0; i < old_count; i++) {
		const struct egp_route *r = best(old[i].net);
		route_send(r ? r : &old[i], r != NULL);
	}
	for (i = 0; i < count; i++) {
		const struct egp_route *r = best(routes[i].net);
		if (r)
			route_send(r, true);
	}
}
static void reset(struct neighbor *n)
{
	n->reach = (struct egp_reach){0};
	n->updates = (struct egp_update_window){0};
	n->hello_pending = false;
	n->poll_pending = false;
	n->last_hello_rx = 0;
	n->hello = hello_interval;
	n->poll = poll_interval;
	n->next_hello = 0;
	n->next_poll = 0;
	replace_routes(n, NULL, 0);
}
static bool transmit_message(struct neighbor *n, struct egp_message *m)
{
	uint8_t buf[EGP_MAX_PKT];
	struct sockaddr_in dst = {.sin_family = AF_INET, .sin_addr = n->peer};
	int len = egp_encode(buf, sizeof(buf), m, n->local);
	if (len <= 0)
		return false;
	if (sendto(n->fd, buf, len, 0, (struct sockaddr *)&dst, sizeof(dst)) != len) {
		zlog_warn("EGP send to %pI4: %s", &n->peer, safe_strerror(errno));
		return false;
	}
	switch (m->type) {
	case EGP_UPDATE:
		n->updates_tx++;
		break;
	case EGP_POLL:
		n->polls_tx++;
		break;
	case EGP_REACH:
		n->hellos_tx++;
		break;
	case EGP_ERROR:
		n->errors_tx++;
		break;
	default:
		break;
	}
	return true;
}
static bool transmit(struct neighbor *n, uint8_t type, uint8_t code, uint16_t seq,
                     bool unsolicited)
{
	struct egp_message m = {0};
	m.type = type;
	m.code = code;
	m.as = local_as;
	m.seq = seq;
	m.status = n->state == UP ? EGP_STATUS_ACTIVE : EGP_STATUS_PASSIVE;
	if (unsolicited)
		m.status |= 0x80;
	if (type == EGP_ACQUIRE)
		m.status = code <= 1 ? 0 : EGP_STATUS_GOING_DOWN;
	/* Acquisition advertises local minima, not the negotiated intervals. */
	m.hello = hello_interval;
	m.poll = poll_interval;
	m.shared = n->shared;
	if (type == EGP_UPDATE) {
		m.count = network_count;
		memcpy(m.routes, networks, network_count * sizeof(*networks));
	}
	return transmit_message(n, &m);
}
/* RFC 904 A.5: an Error embeds the first 12 octets of the offending header. */
static bool send_error(struct neighbor *n, uint16_t reason, const uint8_t *hdr,
                       size_t hdr_len, uint16_t seq)
{
	struct egp_message m = {0};
	m.type = EGP_ERROR;
	m.status = n->state == UP ? EGP_STATUS_ACTIVE : EGP_STATUS_PASSIVE;
	m.as = local_as;
	m.seq = seq;
	m.reason = reason;
	if (hdr_len)
		memcpy(m.err_header, hdr, MIN(hdr_len, sizeof(m.err_header)));
	return transmit_message(n, &m);
}
static bool send_msg(struct neighbor *n, uint8_t type, uint8_t code, uint16_t seq)
{
	bool sent = transmit(n, type, code, seq, false);
	if (sent && type == EGP_UPDATE)
		n->updates.dirty = false;
	return sent;
}
static void idle(struct neighbor *n)
{
	n->state = IDLE;
	reset(n);
	n->abort_at = 0;
	if (n->deleting) {
		event_cancel(&n->read);
		close(n->fd);
		memset(n, 0, sizeof(*n));
	}
}
static void start_peer(struct neighbor *n, time_t t)
{
	n->state = egp_control_next(n->state, EGP_START);
	if (n->state == CEASE)
		return;
	reset(n);
	n->request_seq = ++n->seq;
	send_msg(n, EGP_ACQUIRE, 0, n->request_seq);
	n->next_hello = t + EGP_P3;
	n->abort_at = t + EGP_P5;
}
static void stop_peer(struct neighbor *n, bool deleting, time_t t)
{
	n->deleting |= deleting;
	n->state = egp_control_next(n->state, EGP_STOP);
	if (n->state == IDLE) {
		idle(n);
		return;
	}
	reset(n);
	n->stop_seq = ++n->seq;
	send_msg(n, EGP_ACQUIRE, 3, n->stop_seq);
	n->next_hello = t + EGP_P3;
	n->abort_at = t + EGP_P5;
}
static void reachability(struct neighbor *n, time_t t)
{
	unsigned hits = egp_reach_hits(&n->reach, t, n->hello);
	if (n->state == DOWN && hits >= (n->active ? 3U : 1U)) {
		n->state = UP;
		n->next_poll = t;
		n->updates.dirty = true;
	} else if (n->state == UP && hits <= (n->active ? 1U : 0U)) {
		n->state = DOWN;
		n->poll_pending = false;
		replace_routes(n, NULL, 0);
	}
}
static void indication(struct neighbor *n, time_t t)
{
	if (egp_reach_record(&n->reach, t, n->hello)) {
		n->last_seen = t;
		n->abort_at = t + egp_hold_interval(n->hello, EGP_P4);
	}
	reachability(n, t);
}
/* RFC 904 A.5: reason 1 covers a bad message length and invalid Type/Code/Status
 * fields. What the header cannot already rule out is a data-field problem
 * (reason 2). The rules mirror egp_decode() exactly, including the legal
 * unsolicited bit (0x80) that only Update and Error carry. */
static int malformed_reason(const uint8_t *b, size_t len)
{
	static const size_t acquire_len[] = {14, 14, 10, 10, 10};
	uint8_t type = b[1], code = b[2], status = b[3];
	switch (type) {
	case EGP_ACQUIRE:
		if (code > 4 || status > 7 || len != acquire_len[code])
			return EGP_ERR_HEADER;
		/* Request/Confirm only carry the two capability modes. */
		if (code <= 1 && status > 2)
			return EGP_ERR_HEADER;
		return EGP_ERR_FIELD; /* e.g. a zero interval: bad data field */
	case EGP_REACH:
		return code <= 1 && status <= 2 && len == 10 ? EGP_ERR_FIELD : EGP_ERR_HEADER;
	case EGP_POLL:
		return !code && status <= 2 && len == 16 ? EGP_ERR_FIELD : EGP_ERR_HEADER;
	case EGP_ERROR:
		return !code && (status & 0x7f) <= 2 && len == 24 ? EGP_ERR_FIELD
		                                                  : EGP_ERR_HEADER;
	case EGP_UPDATE:
		if (code || (status & 0x7f) > 2 || len < 16)
			return EGP_ERR_HEADER;
		return EGP_ERR_FIELD;
	default:
		return EGP_ERR_HEADER;
	}
}
/* RFC 904 4.5 / A.5: report bad format, but never bad version/checksum and
 * never in response to another Error message. */
static void report_malformed(struct neighbor *n, const uint8_t *b, size_t len)
{
	uint16_t seq;
	if (len < 10 || b[0] != 2 || b[1] == EGP_ERROR || egp_checksum(b, len))
		return;
	seq = (uint16_t)((b[8] << 8) | b[9]);
	send_error(n, malformed_reason(b, len), b, len, seq);
}
static void receive(struct event *event)
{
	struct neighbor *n = EVENT_ARG(event);
	uint8_t buf[2048];
	struct sockaddr_in src;
	socklen_t slen = sizeof(src);
	struct egp_message m;
	ssize_t len = recvfrom(n->fd, buf, sizeof(buf), 0, (struct sockaddr *)&src, &slen);
	size_t ihl, i;
	const uint8_t *egp;
	size_t egplen;
	struct egp_route next[EGP_MAX_ROUTES];
	uint8_t next_misses[EGP_MAX_ROUTES];
	int count;
	bool unsolicited;
	time_t t = now();
	event_add_read(master, receive, n, n->fd, &n->read);
	if (len < 20 || src.sin_addr.s_addr != n->peer.s_addr || (buf[0] >> 4) != 4)
		return;
	ihl = (buf[0] & 15) * 4;
	if (ihl < 20 || (size_t)len < ihl || memcmp(buf + 16, &n->local, 4))
		return;
	egp = buf + ihl;
	egplen = (size_t)len - ihl;
	if (egp_decode(egp, egplen, &m)) {
		report_malformed(n, egp, egplen);
		return;
	}
	if (m.as != n->as)
		return;
	if (m.type == EGP_ERROR) {
		/* RFC 904 4.5: advisory only; no state change and no reply. */
		n->errors_rx++;
		return;
	}
	if (m.type == EGP_ACQUIRE) {
		if (m.code == 3) {
			send_msg(n, EGP_ACQUIRE, 4, m.seq);
			idle(n);
			return;
		}
		if (m.code == 4 && n->state == CEASE && m.seq == n->stop_seq) {
			idle(n);
			return;
		}
		if (m.code == 2 && n->state == ACQUISITION && m.seq == n->request_seq) {
			idle(n);
			return;
		}
		if (m.code > 1 ||
		    (m.code == 1 && (n->state != ACQUISITION || m.seq != n->request_seq)))
			return;
		if (n->state == CEASE || shutting_down) {
			if (m.code == 0)
				send_msg(n, EGP_ACQUIRE, 3, n->stop_seq);
			return;
		}
		n->state = DOWN;
		reset(n);
		if (m.code == 0)
			egp_update_command(&n->updates, m.seq, false);
		n->hello = MAX(hello_interval, m.hello);
		n->poll = MAX(poll_interval, m.poll);
		/* Advertise both modes; RFC 904 section 4.1.3 capability table. */
		n->active = m.status == 2 || (m.status == 0 && local_as < n->as);
		n->last_seen = t;
		n->abort_at = t + egp_hold_interval(n->hello, EGP_P5);
		if (m.code == 0)
			send_msg(n, EGP_ACQUIRE, 1, m.seq);
		/* A Confirm is an active-mode reachability indication (3.3). */
		if (m.code == 1 && n->active)
			indication(n, t);
		if (n->active) {
			n->hello_seq = n->seq;
			n->hello_pending = true;
			send_msg(n, EGP_REACH, 0, n->hello_seq);
		}
		n->next_hello = t + n->hello;
		return;
	}
	if (n->state != DOWN && n->state != UP)
		return;
	if (m.type == EGP_REACH) {
		if (!m.code) {
			/* RFC 904 A.5 reason 4: two Hellos inside half the minimum
			 * interval. Half instead of the full interval so that an
			 * independent peer clock jitter cannot produce false Errors;
			 * a one-second floor keeps sub-second bursts visible even
			 * when the negotiated Hello is one second. */
			time_t min_gap = (time_t)MAX(1U, (unsigned)n->hello / 2);
			if (n->last_hello_rx && t - n->last_hello_rx < min_gap) {
				send_error(n, EGP_ERR_RATE, egp, egplen, m.seq);
				return;
			}
			n->last_hello_rx = t;
			n->hellos_rx++;
			egp_update_command(&n->updates, m.seq, false);
			if (!n->active && m.status == 1)
				indication(n, t);
			send_msg(n, EGP_REACH, 1, m.seq);
		} else if (n->active && n->hello_pending && m.seq == n->hello_seq) {
			n->hello_pending = false;
			indication(n, t);
		}
		return;
	}
	if (m.shared.s_addr != n->shared.s_addr) {
		send_error(n, m.type == EGP_POLL ? EGP_ERR_NOINFO : EGP_ERR_FIELD, egp,
		           egplen, m.seq);
		return;
	}
	if (m.type == EGP_POLL) {
		n->polls_rx++;
		egp_update_command(&n->updates, m.seq, true);
		if (!n->active && m.status == 1)
			indication(n, t);
		if (n->state == UP && egp_update_can_reply(&n->updates) &&
		    send_msg(n, EGP_UPDATE, 0, m.seq))
			egp_update_replied(&n->updates);
		return;
	}
	unsolicited = (m.status & 0x80) != 0;
	if (n->state != UP || m.type != EGP_UPDATE ||
	    !egp_update_matches(&n->updates, unsolicited, m.seq, n->seq,
	                        n->poll_pending, n->poll_seq))
		return;
	n->updates_rx++;
	/* Stub-only: accept sender gateway, reject third-party transit claims.
	 * RFC 888 section 5: distance 255 withdraws that net, not the Update. */
	for (i = 0; i < m.count; i++) {
		if (m.routes[i].gateway.s_addr != n->peer.s_addr)
			return;
	}
	count = egp_age_update(n->routes, n->count, n->misses, &m, next, next_misses);
	if (count < 0)
		return;
	if (unsolicited)
		n->updates.rx_used = true;
	else
		n->poll_pending = false;
	if (n->active || (m.status & 0x7f) == 1)
		indication(n, t);
	if (n->state != UP)
		return;
	n->last_update = t;
	replace_routes(n, next, count);
	memcpy(n->misses, next_misses, count);
}
static void tick(struct event *event)
{
	time_t t = now();
	size_t i;
	(void)event;
	for (i = 0; i < MAX_PEERS; i++) {
		struct neighbor *n = &peers[i];
		if (!n->used)
			continue;
		if (egp_abort_due(n->state, n->abort_at, t)) {
			stop_peer(n, n->deleting, t);
			continue;
		}
		if (n->state == IDLE)
			continue;
		if (n->state == ACQUISITION || n->state == CEASE) {
			if (t >= n->next_hello) {
				send_msg(n, EGP_ACQUIRE, n->state == CEASE ? 3 : 0,
				         n->state == CEASE ? n->stop_seq : n->request_seq);
				n->next_hello = t + EGP_P3;
			}
			continue;
		}
		reachability(n, t);
		if (t >= n->next_hello) {
			if (n->active) {
				n->hello_seq = n->seq;
				n->hello_pending = true;
				send_msg(n, EGP_REACH, 0, n->hello_seq);
			}
			n->next_hello = t + n->hello;
		}
		if (n->count && t - n->last_update > 3 * n->poll)
			replace_routes(n, NULL, 0);
		if (n->state == UP && t >= n->next_poll) {
			n->poll_seq = ++n->seq;
			n->poll_pending = true;
			n->updates.rx_used = false;
			send_msg(n, EGP_POLL, 0, n->poll_seq);
			n->next_poll = t + n->poll;
		}
		if (n->state == UP && n->updates.dirty && !n->updates.tx_used &&
		    n->updates.command_seen &&
		    transmit(n, EGP_UPDATE, 0, n->updates.reply_seq, true)) {
			n->updates.tx_used = true;
			n->updates.dirty = false;
		}
	}
	if (shutting_down) {
		for (i = 0; i < MAX_PEERS; i++)
			if (peers[i].used)
				break;
		if (i == MAX_PEERS)
			finish();
	}
	event_add_timer(master, tick, NULL, 1, &ticker);
}
static void connected(struct zclient *client)
{
	size_t i, j;
	zclient_send_reg_requests(client, VRF_DEFAULT);
	for (i = 0; i < MAX_PEERS; i++)
		for (j = 0; j < peers[i].count; j++) {
			const struct egp_route *r = best(peers[i].routes[j].net);
			if (r)
				route_send(r, true);
		}
}
static void remove_peer(struct neighbor *n)
{
	stop_peer(n, true, now());
}
DEFUN(egp_as, egp_as_cmd, "egp local-as (1-65535)", "EGP\nLocal autonomous system\nAS number\n")
{
	size_t i;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used) {
			vty_out(vty, "Remove neighbors before changing AS\n");
			return CMD_WARNING_CONFIG_FAILED;
		}
	local_as = strtoul(argv[2]->arg, NULL, 10);
	return CMD_SUCCESS;
}
DEFUN(egp_timers, egp_timers_cmd, "egp timers (1-65535) (1-65535)", "EGP\nTimers (seconds)\nHello interval\nPoll interval\n")
{
	unsigned h = strtoul(argv[2]->arg, NULL, 10), p = strtoul(argv[3]->arg, NULL, 10);
	size_t i;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used) {
			vty_out(vty, "Remove neighbors before changing timers\n");
			return CMD_WARNING_CONFIG_FAILED;
		}
	hello_interval = h;
	poll_interval = p;
	return CMD_SUCCESS;
}
DEFUN(egp_peer, egp_peer_cmd, "egp neighbor A.B.C.D local-address A.B.C.D remote-as (1-65535)",
      "EGP\nNeighbor\nPeer IPv4\nLocal source\nLocal IPv4\nRemote AS\nAS number\n")
{
	struct in_addr peer, local;
	struct sockaddr_in bindaddr = {.sin_family = AF_INET};
	struct neighbor *n = NULL;
	unsigned as = strtoul(argv[6]->arg, NULL, 10);
	int k, fd = -1;
	size_t i;
	inet_pton(AF_INET, argv[2]->arg, &peer);
	inet_pton(AF_INET, argv[4]->arg, &local);
	k = egp_classlen(local);
	if (!local_as || as == local_as || !k || memcmp(&peer, &local, k) ||
	    peer.s_addr == local.s_addr) {
		vty_out(vty,
		        "Set local-as first; distinct ASes and peers on the same classful network required\n");
		return CMD_WARNING_CONFIG_FAILED;
	}
	for (i = 0; i < MAX_PEERS; i++) {
		if (peers[i].used && peers[i].peer.s_addr == peer.s_addr)
			return CMD_WARNING_CONFIG_FAILED;
		if (!peers[i].used && !n)
			n = &peers[i];
	}
	if (!n)
		return CMD_WARNING_CONFIG_FAILED;
	frr_with_privs(&privileges)
	{
		fd = socket(AF_INET, SOCK_RAW, 8);
	}
	if (fd < 0) {
		vty_out(vty, "Raw socket: %s\n", safe_strerror(errno));
		return CMD_WARNING_CONFIG_FAILED;
	}
	bindaddr.sin_addr = local;
	if (bind(fd, (struct sockaddr *)&bindaddr, sizeof(bindaddr)) < 0 ||
	    set_nonblocking(fd) < 0) {
		vty_out(vty, "Bind local source: %s\n", safe_strerror(errno));
		close(fd);
		return CMD_WARNING_CONFIG_FAILED;
	}
	n->used = true;
	n->fd = fd;
	n->peer = peer;
	n->local = local;
	n->as = as;
	n->shared.s_addr = htonl(ntohl(local.s_addr) & (0xffffffffU << (32 - k * 8)));
	start_peer(n, now());
	event_add_read(master, receive, n, fd, &n->read);
	return CMD_SUCCESS;
}
DEFUN(clear_egp_peer, clear_egp_peer_cmd, "clear ip egp neighbor A.B.C.D",
      CLEAR_STR IP_STR "EGP\nRestart neighbor acquisition\nPeer IPv4\n")
{
	struct in_addr peer;
	size_t i;
	inet_pton(AF_INET, argv[4]->arg, &peer);
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used && peers[i].peer.s_addr == peer.s_addr) {
			if (peers[i].state == CEASE || shutting_down)
				return CMD_WARNING;
			start_peer(&peers[i], now());
		}
	return CMD_SUCCESS;
}
DEFUN(clear_egp_all, clear_egp_all_cmd, "clear ip egp neighbor *",
      CLEAR_STR IP_STR "EGP\nRestart all neighbor acquisitions\nAll neighbors\n")
{
	size_t i;
	for (i = 0; i < MAX_PEERS; i++) {
		if (!peers[i].used || peers[i].state == CEASE || shutting_down)
			continue;
		start_peer(&peers[i], now());
	}
	return CMD_SUCCESS;
}
DEFUN(no_egp_peer, no_egp_peer_cmd, "no egp neighbor A.B.C.D", NO_STR "EGP\nNeighbor\nPeer IPv4\n")
{
	struct in_addr peer;
	size_t i;
	inet_pton(AF_INET, argv[3]->arg, &peer);
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used && peers[i].peer.s_addr == peer.s_addr)
			remove_peer(&peers[i]);
	return CMD_SUCCESS;
}
DEFUN(egp_network_cmd_fn, egp_network_cmd, "[no] egp network A.B.C.D", NO_STR "EGP\nAdvertise classful network\nNetwork address (no host bits)\n")
{
	bool no = !strcmp(argv[0]->text, "no");
	bool changed = false;
	struct in_addr net;
	size_t i;
	inet_pton(AF_INET, argv[argc - 1]->arg, &net);
	if (!egp_network(net)) {
		vty_out(vty, "EGP requires a class A/B/C network address\n");
		return CMD_WARNING_CONFIG_FAILED;
	}
	for (i = 0; i < network_count; i++)
		if (networks[i].net.s_addr == net.s_addr)
			break;
	if (no && i < network_count) {
		memmove(&networks[i], &networks[i + 1],
		        (network_count - i - 1) * sizeof(*networks));
		network_count--;
		changed = true;
	}
	if (!no && i == network_count) {
		if (network_count == EGP_MAX_ROUTES)
			return CMD_WARNING_CONFIG_FAILED;
		networks[network_count++] = (struct egp_route){.net = net, .distance = 1};
		changed = true;
	}
	if (changed)
		for (i = 0; i < MAX_PEERS; i++)
			if (peers[i].used && peers[i].state == UP)
				peers[i].updates.dirty = true;
	return CMD_SUCCESS;
}
static struct neighbor *find_peer(struct in_addr peer)
{
	size_t i;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used && peers[i].peer.s_addr == peer.s_addr)
			return &peers[i];
	return NULL;
}
static const char *state_name(const struct neighbor *n)
{
	return states[n->state];
}
static void peer_prefixes_text(struct vty *vty, const struct neighbor *n, time_t t)
{
	size_t i;
	for (i = 0; i < n->count; i++)
		vty_out(vty, "  prefix %pI4/%u distance %u gateway %pI4 misses %u age %llds\n",
		        &n->routes[i].net, egp_classlen(n->routes[i].net) * 8,
		        n->routes[i].distance, &n->routes[i].gateway, n->misses[i],
		        (long long)(n->last_update ? t - n->last_update : -1));
}
static void peer_detail_text(struct vty *vty, const struct neighbor *n, time_t t)
{
	vty_out(vty, "Peer %pI4 AS %u\n", &n->peer, n->as);
	vty_out(vty, "  local-address %pI4, state %s, mode %s\n", &n->local, state_name(n),
	        n->active ? "active" : "passive");
	vty_out(vty,
	        "  timers hello %u poll %u; next hello %llds, next poll %llds, abort in %llds\n",
	        n->hello, n->poll, (long long)(n->next_hello > t ? n->next_hello - t : 0),
	        (long long)(n->next_poll > t ? n->next_poll - t : 0),
	        (long long)(n->abort_at > t ? n->abort_at - t : 0));
	vty_out(vty, "  counters tx/rx: hello %u/%u, poll %u/%u, update %u/%u\n", n->hellos_tx,
	        n->hellos_rx, n->polls_tx, n->polls_rx, n->updates_tx, n->updates_rx);
	vty_out(vty, "  errors tx/rx: %u/%u\n", n->errors_tx, n->errors_rx);
	vty_out(vty, "  prefixes %zu, last update %llds ago\n", n->count,
	        (long long)(n->last_update ? t - n->last_update : -1));
	peer_prefixes_text(vty, n, t);
}
static struct json_object *peer_json(const struct neighbor *n, time_t t)
{
	struct json_object *o = json_object_new_object();
	struct json_object *arr = json_object_new_array();
	char buf[INET_ADDRSTRLEN], pbuf[INET_ADDRSTRLEN + 5];
	size_t i;
	for (i = 0; i < n->count; i++) {
		struct json_object *r = json_object_new_object();
		snprintf(pbuf, sizeof(pbuf), "%s/%u",
		         inet_ntop(AF_INET, &n->routes[i].net, buf, sizeof(buf)),
		         egp_classlen(n->routes[i].net) * 8);
		json_object_string_add(r, "prefix", pbuf);
		json_object_int_add(r, "distance", n->routes[i].distance);
		json_object_string_add(r, "gateway",
		                       inet_ntop(AF_INET, &n->routes[i].gateway, buf,
		                                 sizeof(buf)));
		json_object_int_add(r, "misses", n->misses[i]);
		json_object_array_add(arr, r);
	}
	json_object_string_add(o, "address", inet_ntop(AF_INET, &n->peer, buf, sizeof(buf)));
	json_object_int_add(o, "as", n->as);
	json_object_string_add(o, "state", state_name(n));
	json_object_string_add(o, "mode", n->active ? "active" : "passive");
	json_object_int_add(o, "hello", n->hello);
	json_object_int_add(o, "poll", n->poll);
	json_object_int_add(o, "prefixCount", n->count);
	json_object_int_add(o, "helloTx", n->hellos_tx);
	json_object_int_add(o, "helloRx", n->hellos_rx);
	json_object_int_add(o, "pollTx", n->polls_tx);
	json_object_int_add(o, "pollRx", n->polls_rx);
	json_object_int_add(o, "updateTx", n->updates_tx);
	json_object_int_add(o, "updateRx", n->updates_rx);
	json_object_int_add(o, "errorTx", n->errors_tx);
	json_object_int_add(o, "errorRx", n->errors_rx);
	json_object_int_add(o, "lastUpdateAge",
	                    n->last_update ? (int)(t - n->last_update) : -1);
	json_object_object_add(o, "prefixes", arr);
	return o;
}
static void neighbors_text(struct vty *vty, bool detail, time_t t)
{
	size_t i;
	vty_out(vty, "EGP local AS %u, zebra %s, %zu network(s) configured\n", local_as,
	        zc->sock >= 0 ? "connected" : "disconnected", network_count);
	if (!detail)
		vty_out(vty, "Peer             AS     State        Mode     Prefixes\n");
	for (i = 0; i < MAX_PEERS; i++) {
		if (!peers[i].used)
			continue;
		if (detail) {
			peer_detail_text(vty, &peers[i], t);
			continue;
		}
		vty_out(vty, "%pI4 %u %s %s %zu\n", &peers[i].peer, peers[i].as,
		        state_name(&peers[i]), peers[i].active ? "active" : "passive",
		        peers[i].count);
	}
}
DEFUN(show_egp, show_egp_cmd, "show ip egp neighbors [detail] [json]",
      SHOW_STR IP_STR "EGP\nNeighbors\nPer-neighbor detail\nJSON output\n")
{
	int idx = 0;
	bool detail = argv_find(argv, argc, "detail", &idx);
	bool as_json = argv_find(argv, argc, "json", &idx);
	time_t t = now();
	size_t i;
	if (as_json) {
		struct json_object *top = json_object_new_object();
		struct json_object *arr = json_object_new_array();
		json_object_int_add(top, "localAs", local_as);
		json_object_int_add(top, "zebraConnected", zc->sock >= 0 ? 1 : 0);
		json_object_int_add(top, "configuredNetworks", network_count);
		for (i = 0; i < MAX_PEERS; i++)
			if (peers[i].used)
				json_object_array_add(arr, peer_json(&peers[i], t));
		json_object_object_add(top, "peers", arr);
		vty_json(vty, top);
		return CMD_SUCCESS;
	}
	neighbors_text(vty, detail, t);
	return CMD_SUCCESS;
}
DEFUN(show_egp_peer, show_egp_peer_cmd, "show ip egp neighbors A.B.C.D [json]",
      SHOW_STR IP_STR "EGP\nNeighbors\nPeer IPv4\nJSON output\n")
{
	int idx = 0;
	bool as_json = argv_find(argv, argc, "json", &idx);
	struct neighbor *n;
	struct in_addr addr;
	time_t t = now();
	inet_pton(AF_INET, argv[4]->arg, &addr);
	n = find_peer(addr);
	if (!n) {
		vty_out(vty, "No such EGP neighbor\n");
		return CMD_WARNING;
	}
	if (as_json) {
		struct json_object *o = peer_json(n, t);
		vty_json(vty, o);
		return CMD_SUCCESS;
	}
	peer_detail_text(vty, n, t);
	return CMD_SUCCESS;
}
static int config_write(struct vty *vty)
{
	size_t i;
	int wrote = 0;
	if (local_as) {
		vty_out(vty, "egp local-as %u\n", local_as);
		wrote = 1;
	}
	if (hello_interval != 30 || poll_interval != 120) {
		vty_out(vty, "egp timers %u %u\n", hello_interval, poll_interval);
		wrote = 1;
	}
	for (i = 0; i < network_count; i++) {
		vty_out(vty, "egp network %pI4\n", &networks[i].net);
		wrote = 1;
	}
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used && !peers[i].deleting) {
			vty_out(vty, "egp neighbor %pI4 local-address %pI4 remote-as %u\n",
			        &peers[i].peer, &peers[i].local, peers[i].as);
			wrote = 1;
		}
	return wrote;
}
static struct cmd_node egp_node = {.name = "egp",
                                   .node = EGP_NODE,
                                   .parent_node = CONFIG_NODE,
                                   .prompt = "",
                                   .config_write = config_write};
static FRR_NORETURN void finish(void)
{
	size_t i;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used) {
			peers[i].deleting = true;
			idle(&peers[i]);
		}
	event_cancel(&ticker);
	zclient_stop(zc);
	zclient_free(zc);
	vrf_terminate();
	frr_fini();
	exit(0);
}
static void terminate(void)
{
	size_t i;
	if (shutting_down)
		finish();
	shutting_down = true;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used)
			remove_peer(&peers[i]);
}
static void rotate(void)
{
	zlog_rotate();
}
static struct frr_signal_t signals[] = {
    {.signal = SIGINT, .handler = terminate},
    {.signal = SIGTERM, .handler = terminate},
    {.signal = SIGUSR1, .handler = rotate},
};
FRR_DAEMON_INFO(egpd, EGP, .vty_port = 0, .proghelp = "Experimental EGP stub gateway",
                .signals = signals, .n_signals = array_size(signals), .privs = &privileges);
int main(int argc, char **argv)
{
	int opt;
	frr_preinit(&egpd_di, argc, argv);
	while ((opt = frr_getopt(argc, argv, NULL)) != EOF)
		if (opt != 0)
			frr_help_exit(1);
	master = frr_init();
	vrf_init(NULL, NULL, NULL, NULL);
	zc = zclient_new(master, &zclient_options_default, NULL, 0);
	zclient_init(zc, ZEBRA_ROUTE_EGP, 0, &privileges);
	zc->zebra_connected = connected;
	install_node(&egp_node);
	install_element(CONFIG_NODE, &egp_as_cmd);
	install_element(CONFIG_NODE, &egp_timers_cmd);
	install_element(CONFIG_NODE, &egp_peer_cmd);
	install_element(CONFIG_NODE, &no_egp_peer_cmd);
	install_element(CONFIG_NODE, &egp_network_cmd);
	install_element(VIEW_NODE, &show_egp_cmd);
	install_element(VIEW_NODE, &show_egp_peer_cmd);
	install_element(ENABLE_NODE, &clear_egp_peer_cmd);
	install_element(ENABLE_NODE, &clear_egp_all_cmd);
	event_add_timer(master, tick, NULL, 1, &ticker);
	frr_config_fork();
	frr_run(master);
	return 0;
}
