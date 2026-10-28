// SPDX-License-Identifier: GPL-2.0-or-later
#include "egp_age.h"
#include "egp_packet.h"
#include "egp_reach.h"
#include "egp_state.h"
#include "egp_update.h"
#include <arpa/inet.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static struct in_addr addr(const char *s)
{
	struct in_addr a;
	assert(inet_pton(AF_INET, s, &a) == 1);
	return a;
}
static void seal(uint8_t *b, size_t len)
{
	uint16_t c;
	b[4] = b[5] = 0;
	c = egp_checksum(b, len);
	b[4] = c >> 8;
	b[5] = c;
}
static void test_aging(void)
{
	struct egp_route old[EGP_MAX_ROUTES], next[EGP_MAX_ROUTES];
	uint8_t misses[EGP_MAX_ROUTES] = {0}, next_misses[EGP_MAX_ROUTES];
	struct egp_message m = {0};
	int count;
	old[0] = (struct egp_route){.net = addr("10.0.0.0"), .distance = 9};
	count = egp_age_update(old, 1, misses, &m, next, next_misses);
	assert(count == 1 && next_misses[0] == 1 && next[0].distance == 9);
	misses[0] = 1;
	assert(egp_age_update(old, 1, misses, &m, next, next_misses) == 1);
	assert(next_misses[0] == 2);
	misses[0] = 2;
	assert(egp_age_update(old, 1, misses, &m, next, next_misses) == 0);
	m.count = 1;
	m.routes[0] = old[0];
	m.routes[0].distance = 0;
	assert(egp_age_update(old, 1, misses, &m, next, next_misses) == 1);
	assert(next_misses[0] == 0 && next[0].distance == 0);
	m.routes[0].distance = 255;
	misses[0] = 0;
	assert(egp_age_update(old, 1, misses, &m, next, next_misses) == 0);
	m.routes[1] = (struct egp_route){.net = addr("172.16.0.0"), .distance = 7};
	m.count = 2;
	assert(egp_age_update(old, 1, misses, &m, next, next_misses) == 1);
	assert(next[0].net.s_addr == m.routes[1].net.s_addr && next_misses[0] == 0);
	m.routes[1] = m.routes[0];
	assert(egp_age_update(old, 1, misses, &m, next, next_misses) < 0);
	/* Retained omissions plus new networks cannot exceed the resource limit. */
	for (size_t i = 0; i < EGP_MAX_ROUTES; i++) {
		old[i].net.s_addr = htonl(0xc6120000U + (i << 8));
		misses[i] = 0;
	}
	m.count = 1;
	m.routes[0] = (struct egp_route){.net = addr("10.0.0.0"), .distance = 1};
	assert(egp_age_update(old, EGP_MAX_ROUTES, misses, &m, next, next_misses) < 0);
}
static void test_distances(void)
{
	/* Independent wire oracle: one gateway, three distance groups. */
	uint8_t golden[] = {
	    2, 1, 0, 1, 0, 0, 0xfd, 0xe8, 0, 7, 1, 0, 192, 0, 2, 0,
	    1, 3,
	    7, 2, 10, 198, 51, 100,
	    255, 1, 172, 16,
	    0, 1, 192, 0, 3};
	uint8_t b[EGP_MAX_PKT];
	struct egp_message m = {.type = EGP_UPDATE, .status = 1, .as = 65000, .seq = 7, .count = 4}, d;
	int len;
	size_t i;
	m.shared = addr("192.0.2.0");
	m.routes[0] = (struct egp_route){.net = addr("10.0.0.0"), .distance = 7};
	m.routes[1] = (struct egp_route){.net = addr("172.16.0.0"), .distance = 255};
	m.routes[2] = (struct egp_route){.net = addr("198.51.100.0"), .distance = 7};
	m.routes[3] = (struct egp_route){.net = addr("192.0.3.0"), .distance = 0};
	seal(golden, sizeof(golden));
	len = egp_encode(b, sizeof(b), &m, addr("192.0.2.1"));
	assert(len == sizeof(golden) && !memcmp(b, golden, sizeof(golden)));
	assert(!egp_decode(golden, sizeof(golden), &d) && d.count == 4);
	assert(d.routes[0].distance == 7 && d.routes[1].distance == 7);
	assert(d.routes[2].distance == 255 && d.routes[3].distance == 0);
	assert(d.routes[1].net.s_addr == m.routes[2].net.s_addr);
	assert(d.routes[2].net.s_addr == m.routes[1].net.s_addr);
	/* Exercise one-byte group/net counters at the 255-route limit. */
	m.count = EGP_MAX_ROUTES;
	for (i = 0; i < m.count; i++) {
		m.routes[i].net.s_addr = htonl(0xc6120000U + (i << 8));
		m.routes[i].distance = i ? i - 1 : 255;
	}
	len = egp_encode(b, sizeof(b), &m, addr("192.0.2.1"));
	assert(len == 18 + 5 * EGP_MAX_ROUTES && b[17] == 255);
	assert(!egp_decode(b, len, &d) && d.count == EGP_MAX_ROUTES);
	for (i = 0; i < m.count; i++) {
		assert(d.routes[i].distance == m.routes[i].distance);
		assert(d.routes[i].net.s_addr == m.routes[i].net.s_addr);
		m.routes[i].distance = 255;
	}
	len = egp_encode(b, sizeof(b), &m, addr("192.0.2.1"));
	assert(len == 20 + 3 * EGP_MAX_ROUTES && b[17] == 1 && b[19] == 255);
	assert(!egp_decode(b, len, &d) && d.count == EGP_MAX_ROUTES);
	for (i = 0; i < d.count; i++)
		assert(d.routes[i].distance == 255);
	/* Invalid networks in a later member of a group must still be rejected. */
	m.routes[m.count - 1].net = addr("198.18.1.1");
	assert(egp_encode(b, sizeof(b), &m, addr("192.0.2.1")) < 0);
}
int main(void)
{
	/* Hand-written RFC 904 NR: one internal gateway 192.0.2.1,
	 * one distance, three classful networks (10, 172.16, 198.51.100). */
	uint8_t golden[] = {2, 1, 0, 1, 0, 0, 0xfd, 0xe8, 0, 7, 1, 0, 192,
	                    0, 2, 0, 1, 1, 1, 3, 10, 172, 16, 198, 51, 100};
	uint8_t b[EGP_MAX_PKT + 1];
	struct egp_message m, d;
	int len;
	size_t i;
	test_distances();
	test_aging();
	struct egp_update_window window = {0};
	/* First reply is free; a duplicate reply and a triggered Update share credit. */
	egp_update_command(&window, 7, true);
	assert(egp_update_can_reply(&window));
	egp_update_replied(&window);
	assert(egp_update_can_reply(&window) && !window.tx_used);
	egp_update_command(&window, 7, true);
	egp_update_replied(&window);
	assert(window.tx_used && !egp_update_can_reply(&window));
	egp_update_command(&window, 7, true);
	assert(!egp_update_can_reply(&window));
	egp_update_command(&window, 8, true);
	assert(!window.replied && !window.tx_used && egp_update_can_reply(&window));
	egp_update_replied(&window);
	window.tx_used = true; /* A triggered Update has already used the extra reply. */
	assert(!egp_update_can_reply(&window));
	window = (struct egp_update_window){0};
	assert(egp_update_matches(&window, true, 7, 7, false, 0));
	assert(!egp_update_matches(&window, true, 6, 7, true, 6));
	window.rx_used = true;
	assert(!egp_update_matches(&window, true, 7, 7, true, 7));
	assert(egp_update_matches(&window, false, 7, 8, true, 7));
	assert(!egp_update_matches(&window, false, 7, 8, false, 7));
	egp_update_command(&window, 65535, true);
	window.tx_used = true;
	egp_update_command(&window, 65535, true);
	assert(window.tx_used);
	egp_update_command(&window, 0, false);
	assert(window.tx_used && window.reply_seq == 0);
	egp_update_command(&window, 0, true);
	assert(!window.tx_used && window.last_poll == 0);
	/* Moving-window edges, duplicates, wraparound and delayed ticks (904 4.3). */
	struct egp_reach reach = {0};
	assert(egp_reach_record(&reach, 0, 2));
	assert(!egp_reach_record(&reach, 1, 2));
	assert(egp_reach_record(&reach, 2, 2));
	assert(egp_reach_record(&reach, 4, 2));
	assert(egp_reach_hits(&reach, 4, 2) == 3);
	assert(egp_reach_hits(&reach, 8, 2) == 2);
	assert(egp_reach_hits(&reach, 10, 2) == 1);
	assert(egp_reach_hits(&reach, 12, 2) == 0);
	assert(egp_reach_record(&reach, 100, 2));
	assert(egp_reach_record(&reach, 102, 2));
	assert(egp_reach_hits(&reach, 102, 2) == 2);
	for (enum state s = IDLE; s <= CEASE; s++) {
		assert(egp_control_next(s, EGP_CEASE) == IDLE);
		assert(egp_control_next(s, EGP_CEASE_ACK) == (s == CEASE ? IDLE : s));
		assert(egp_control_next(s, EGP_START) == (s == CEASE ? CEASE : ACQUISITION));
	}
	assert(egp_control_next(ACQUISITION, EGP_REFUSE) == IDLE);
	assert(egp_control_next(UP, EGP_REFUSE) == UP);
	assert(egp_control_next(UP, EGP_CONFIRM) == UP);
	assert(egp_control_next(DOWN, EGP_STOP) == CEASE);
	assert(egp_control_next(UP, EGP_STOP) == CEASE);
	assert(egp_control_next(CEASE, EGP_STOP) == IDLE);
	assert(!egp_abort_due(CEASE, 120, 119));
	assert(egp_abort_due(CEASE, 120, 120));
	assert(!egp_abort_due(IDLE, 120, 121));
	/* Defaults stay unchanged; slow Hellos need the complete four-T1 window. */
	assert(egp_hold_interval(30, EGP_P5) == EGP_P5);
	assert(egp_hold_interval(90, EGP_P5) == 360);
	assert(!egp_abort_due(DOWN, egp_hold_interval(90, EGP_P5), 120));
	assert(egp_abort_due(DOWN, egp_hold_interval(90, EGP_P5), 360));
	assert(egp_hold_interval(90, EGP_P4) == EGP_P4);
	assert(egp_hold_interval(65535, EGP_P4) == 262140);
	seal(golden, sizeof(golden));
	assert(egp_decode(golden, sizeof(golden), &m) == 0);
	assert(m.count == 3 && m.as == 65000 && m.seq == 7);
	assert(m.routes[0].net.s_addr == addr("10.0.0.0").s_addr);
	assert(m.routes[1].net.s_addr == addr("172.16.0.0").s_addr);
	assert(m.routes[2].net.s_addr == addr("198.51.100.0").s_addr);
	len = egp_encode(b + 1, EGP_MAX_PKT, &m, addr("192.0.2.1"));
	assert(len == sizeof(golden) && !memcmp(b + 1, golden, len));
	assert(!egp_decode(b + 1, len, &d)); /* deliberately unaligned */
	for (i = 0; i < sizeof(golden); i++) {
		memcpy(b, golden, i);
		if (i >= 10)
			seal(b, i);
		assert(egp_decode(b, i, &d) < 0);
	}
	memcpy(b, golden, sizeof(golden));
	b[19] = 255;
	seal(b, sizeof(golden));
	assert(egp_decode(b, sizeof(golden), &d) < 0);
	memcpy(b, golden, sizeof(golden));
	b[20] = 240;
	seal(b, sizeof(golden));
	assert(egp_decode(b, sizeof(golden), &d) < 0);
	m.count = 0;
	len = egp_encode(b, EGP_MAX_PKT, &m, addr("192.0.2.1"));
	assert(len == 16 && !egp_decode(b, len, &d) && !d.count);
	m.type = EGP_POLL;
	len = egp_encode(b, EGP_MAX_PKT, &m, addr("192.0.2.1"));
	assert(len == 16 && !b[10] && !b[11] && !egp_decode(b, len, &d));
	m.type = EGP_ACQUIRE;
	m.hello = 30;
	m.poll = 120;
	len = egp_encode(b, EGP_MAX_PKT, &m, addr("192.0.2.1"));
	assert(len == 14 && !egp_decode(b, len, &d));
	/* RFC 904 negotiates S1 and S2 independently, including S2 < S1. */
	for (m.code = 0; m.code <= 1; m.code++) {
		m.hello = 30;
		m.poll = 10;
		len = egp_encode(b, EGP_MAX_PKT, &m, addr("192.0.2.1"));
		assert(len == 14 && !egp_decode(b, len, &d));
		assert(d.hello == 30 && d.poll == 10);
		b[10] = b[11] = 0;
		seal(b, len);
		assert(egp_decode(b, len, &d) < 0);
		b[11] = 30;
		b[12] = b[13] = 0;
		seal(b, len);
		assert(egp_decode(b, len, &d) < 0);
	}
	m.code = 3;
	len = egp_encode(b, EGP_MAX_PKT, &m, addr("192.0.2.1"));
	assert(len == 10 && !egp_decode(b, len, &d));
	m.type = EGP_REACH;
	m.code = 0;
	len = egp_encode(b, EGP_MAX_PKT, &m, addr("192.0.2.1"));
	assert(len == 10 && b[1] == 5 && !egp_decode(b, len, &d));
	b[9] ^= 1;
	assert(egp_decode(b, len, &d) < 0);
	assert(!egp_network(addr("10.0.0.1")) && !egp_classlen(addr("224.0.0.0")));
	/* Exercise all message lengths with deterministic random bytes under ASan. */
	unsigned seed = 1;
	for (i = 0; i <= EGP_MAX_PKT; i++) {
		size_t j;
		for (j = 0; j < i; j++) {
			seed = seed * 1103515245 + 12345;
			b[j] = seed >> 24;
		}
		if (i >= 10) {
			b[0] = 2;
			seal(b, i);
		}
		(void)egp_decode(b, i, &d);
	}
	puts("EGP codec: golden wire format, bounds, checksum and unaligned tests passed");
	return 0;
}
