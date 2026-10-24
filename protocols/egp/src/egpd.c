// SPDX-License-Identifier: GPL-2.0-or-later
/* Experimental RFC 904 stub gateway. zebra owns RIB and kernel routes. */
#include <zebra.h>
#include "lib/version.h"
#include "lib/command.h"
#include "lib/frrevent.h"
#include "lib/libfrr.h"
#include "lib/log.h"
#include "lib/privs.h"
#include "lib/sigevent.h"
#include "lib/zclient.h"
#include "lib/vrf.h"
#include "lib/network.h"
#include "egp_packet.h"
#include <time.h>

#define MAX_PEERS 16
enum state { IDLE, ACQUISITION, DOWN, UP };
static const char *const states[] = { "Idle", "Acquisition", "Down", "Up" };
struct neighbor {
	bool used, active, answered, poll_pending;
	int fd;
	struct in_addr peer, local, shared;
	uint16_t as, seq, request_seq, hello_seq, poll_seq, hello, poll;
	enum state state;
	time_t next_hello, next_poll, last_update, last_seen;
	unsigned history;
	struct event *read;
	size_t count;
	struct egp_route routes[EGP_MAX_ROUTES];
};
static struct neighbor peers[MAX_PEERS];
static struct egp_route networks[EGP_MAX_ROUTES];
static size_t network_count;
static uint16_t local_as, hello_interval = 30, poll_interval = 120;
static struct event_loop *master;
static struct event *ticker;
static struct zclient *zc;
static zebra_capabilities_t caps[] = { ZCAP_NET_RAW };
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
	struct zapi_route api = { 0 };
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
	n->state = ACQUISITION;
	n->history = 0;
	n->answered = false;
	n->poll_pending = false;
	n->hello = hello_interval;
	n->poll = poll_interval;
	n->next_hello = 0;
	n->next_poll = 0;
	replace_routes(n, NULL, 0);
}
static void send_msg(struct neighbor *n, uint8_t type, uint8_t code, uint16_t seq)
{
	uint8_t buf[EGP_MAX_PKT];
	struct egp_message m = { 0 };
	struct sockaddr_in dst = { .sin_family = AF_INET, .sin_addr = n->peer };
	int len;
	m.type = type;
	m.code = code;
	m.as = local_as;
	m.seq = seq;
	m.status = n->state == UP ? 1 : 2;
	if (type == EGP_ACQUIRE)
		m.status = code <= 1 ? 0 : 5;
	m.hello = n->hello;
	m.poll = n->poll;
	m.shared = n->shared;
	if (type == EGP_UPDATE) {
		m.count = network_count;
		memcpy(m.routes, networks, network_count * sizeof(*networks));
	}
	len = egp_encode(buf, sizeof(buf), &m, n->local);
	if (len > 0 && sendto(n->fd, buf, len, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0)
		zlog_warn("EGP send to %pI4: %s", &n->peer, safe_strerror(errno));
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
	time_t t = now();
	event_add_read(master, receive, n, n->fd, &n->read);
	if (len < 20 || src.sin_addr.s_addr != n->peer.s_addr || (buf[0] >> 4) != 4)
		return;
	ihl = (buf[0] & 15) * 4;
	if (ihl < 20 || (size_t)len < ihl || memcmp(buf + 16, &n->local, 4) ||
	    egp_decode(buf + ihl, len - ihl, &m) || m.as != n->as)
		return;
	if (m.type == EGP_ACQUIRE) {
		if (m.code == 3) {
			send_msg(n, EGP_ACQUIRE, 4, m.seq);
			reset(n);
			n->next_hello = t + n->hello;
			return;
		}
		if (m.code == 2 && n->state == ACQUISITION && m.seq == n->request_seq) {
			n->next_hello = t + n->hello;
			return;
		}
		if (m.code > 1 ||
		    (m.code == 1 && (n->state != ACQUISITION || m.seq != n->request_seq)))
			return;
		reset(n);
		n->hello = MAX(hello_interval, m.hello);
		n->poll = MAX(poll_interval, m.poll);
		/* Advertise both modes; RFC 904 section 4.1.3 capability table. */
		n->active = m.status == 2 || (m.status == 0 && local_as < n->as);
		n->state = DOWN;
		n->last_seen = t;
		if (m.code == 0)
			send_msg(n, EGP_ACQUIRE, 1, m.seq);
		return;
	}
	if (n->state != DOWN && n->state != UP)
		return;
	if (m.type == EGP_REACH) {
		if (!m.code) {
			if (!n->active && m.status == 1) {
				n->answered = true;
				n->last_seen = t;
			}
			if (!n->active && m.status == 1)
				n->state = UP;
			send_msg(n, EGP_REACH, 1, m.seq);
		} else if (n->active && m.seq == n->hello_seq) {
			n->answered = true;
			n->last_seen = t;
		}
		return;
	}
	if (n->state != UP || m.shared.s_addr != n->shared.s_addr)
		return;
	if (m.type == EGP_POLL) {
		send_msg(n, EGP_UPDATE, 0, m.seq);
		return;
	}
	if (m.type != EGP_UPDATE || m.status != 1 || !n->poll_pending || m.seq != n->poll_seq)
		return;
	/* Stub-only: accept sender gateway, reject third-party transit claims. */
	for (i = 0; i < m.count; i++) {
		if (m.routes[i].gateway.s_addr != n->peer.s_addr || m.routes[i].distance == 255)
			return;
	}
	n->poll_pending = false;
	n->last_update = t;
	replace_routes(n, m.routes, m.count);
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
		if (n->state == ACQUISITION) {
			if (t >= n->next_hello) {
				n->active = local_as < n->as;
				n->request_seq = ++n->seq;
				send_msg(n, EGP_ACQUIRE, 0, n->request_seq);
				n->next_hello = t + n->hello;
			}
			continue;
		}
		if (t >= n->next_hello) {
			n->history = ((n->history << 1) | n->answered) & 15;
			n->answered = false;
			if (n->active) {
				int hits = __builtin_popcount(n->history);
				if (n->state == DOWN && hits >= 3)
					n->state = UP;
				if (n->state == UP && hits <= 1) {
					n->state = DOWN;
					replace_routes(n, NULL, 0);
				}
				n->hello_seq = ++n->seq;
				send_msg(n, EGP_REACH, 0, n->hello_seq);
			} else if (t - n->last_seen >= 4 * n->hello) {
				n->state = DOWN;
				replace_routes(n, NULL, 0);
			}
			n->next_hello = t + n->hello;
		}
		if (t - n->last_seen > MAX(120, 8 * n->hello)) {
			reset(n);
			continue;
		}
		if (n->count && t - n->last_update > 3 * n->poll)
			replace_routes(n, NULL, 0);
		if (n->state == UP && t >= n->next_poll) {
			n->poll_seq = ++n->seq;
			n->poll_pending = true;
			send_msg(n, EGP_POLL, 0, n->poll_seq);
			n->next_poll = t + n->poll;
		}
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
	send_msg(n, EGP_ACQUIRE, 3, ++n->seq);
	n->state = IDLE;
	replace_routes(n, NULL, 0);
	event_cancel(&n->read);
	close(n->fd);
	memset(n, 0, sizeof(*n));
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
	if (p < h)
		return CMD_WARNING_CONFIG_FAILED;
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
	struct sockaddr_in bindaddr = { .sin_family = AF_INET };
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
	frr_with_privs (&privileges) {
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
	reset(n);
	event_add_read(master, receive, n, fd, &n->read);
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
	}
	if (!no && i == network_count) {
		if (network_count == EGP_MAX_ROUTES)
			return CMD_WARNING_CONFIG_FAILED;
		networks[network_count++].net = net;
	}
	return CMD_SUCCESS;
}
DEFUN(show_egp, show_egp_cmd, "show ip egp neighbors", SHOW_STR IP_STR "EGP\nNeighbors\n")
{
	size_t i;
	vty_out(vty,
		"EGP local AS %u, zebra %s\nPeer             AS     State        Mode     Routes\n",
		local_as, zc->sock >= 0 ? "connected" : "disconnected");
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used)
			vty_out(vty, "%pI4 %u %s %s %zu\n", &peers[i].peer, peers[i].as,
				states[peers[i].state], peers[i].active ? "active" : "passive",
				peers[i].count);
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
		if (peers[i].used) {
			vty_out(vty, "egp neighbor %pI4 local-address %pI4 remote-as %u\n",
				&peers[i].peer, &peers[i].local, peers[i].as);
			wrote = 1;
		}
	return wrote;
}
static struct cmd_node egp_node = { .name = "egp",
				    .node = EGP_NODE,
				    .parent_node = CONFIG_NODE,
				    .prompt = "",
				    .config_write = config_write };
static FRR_NORETURN void terminate(void)
{
	size_t i;
	for (i = 0; i < MAX_PEERS; i++)
		if (peers[i].used)
			remove_peer(&peers[i]);
	event_cancel(&ticker);
	zclient_stop(zc);
	zclient_free(zc);
	vrf_terminate();
	frr_fini();
	exit(0);
}
static void rotate(void)
{
	zlog_rotate();
}
static struct frr_signal_t signals[] = {
	{ .signal = SIGINT, .handler = terminate },
	{ .signal = SIGTERM, .handler = terminate },
	{ .signal = SIGUSR1, .handler = rotate },
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
	event_add_timer(master, tick, NULL, 1, &ticker);
	frr_config_fork();
	frr_run(master);
	return 0;
}
