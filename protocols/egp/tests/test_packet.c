// SPDX-License-Identifier: GPL-2.0-or-later
#include "egp_packet.h"
#include "egp_reach.h"
#include <assert.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdio.h>

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
static void test_distances(void)
{
	/* Independent wire oracle: one gateway, three distance groups. */
	uint8_t golden[] = {
		2, 1, 0, 1, 0, 0, 0xfd, 0xe8, 0, 7, 1, 0, 192, 0, 2, 0,
		1, 3,
		7, 2, 10, 198, 51, 100,
		255, 1, 172, 16,
		0, 1, 192, 0, 3
	};
	uint8_t b[EGP_MAX_PKT];
	struct egp_message m = { .type = EGP_UPDATE, .status = 1,
		.as = 65000, .seq = 7, .count = 4 }, d;
	int len;
	size_t i;
	m.shared = addr("192.0.2.0");
	m.routes[0] = (struct egp_route){ .net = addr("10.0.0.0"), .distance = 7 };
	m.routes[1] = (struct egp_route){ .net = addr("172.16.0.0"), .distance = 255 };
	m.routes[2] = (struct egp_route){ .net = addr("198.51.100.0"), .distance = 7 };
	m.routes[3] = (struct egp_route){ .net = addr("192.0.3.0"), .distance = 0 };
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
	uint8_t golden[] = { 2, 1, 0, 1, 0, 0, 0xfd, 0xe8, 0,	7,  1,	 0,  192,
			     0, 2, 0, 1, 1, 1, 3,    10,   172, 16, 198, 51, 100 };
	uint8_t b[EGP_MAX_PKT + 1];
	struct egp_message m, d;
	int len;
	size_t i;
	test_distances();
	/* Moving-window edges, duplicates, wraparound and delayed ticks (904 4.3). */
	struct egp_reach reach = { 0 };
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
