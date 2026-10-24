// SPDX-License-Identifier: GPL-2.0-or-later
/* RFC 904 Appendix A. Byte access also works on unaligned datagrams. */
#include "egp_packet.h"
#include <string.h>
#include <arpa/inet.h>

static uint16_t get16(const uint8_t *p)
{
	return (p[0] << 8) | p[1];
}
static void put16(uint8_t *p, uint16_t v)
{
	p[0] = v >> 8;
	p[1] = v;
}
int egp_classlen(struct in_addr a)
{
	unsigned n = ntohl(a.s_addr) >> 24;
	if (n == 0 || n == 127 || n >= 224)
		return 0;
	return n < 128 ? 1 : n < 192 ? 2 : 3;
}
int egp_network(struct in_addr a)
{
	int n = egp_classlen(a);
	return n && !(ntohl(a.s_addr) & (0xffffffffU >> (n * 8)));
}
uint16_t egp_checksum(const uint8_t *p, size_t len)
{
	uint32_t sum = 0;
	while (len > 1) {
		sum += get16(p);
		p += 2;
		len -= 2;
	}
	if (len)
		sum += *p << 8;
	while (sum >> 16)
		sum = (sum & 65535) + (sum >> 16);
	return (uint16_t)~sum;
}
int egp_decode(const uint8_t *b, size_t len, struct egp_message *m)
{
	size_t pos = 16;
	unsigned g, d, r, ng, nd, nr;
	int n;
	struct in_addr gw;
	if (len < 10 || len > EGP_MAX_PKT || b[0] != 2 || egp_checksum(b, len))
		return -1;
	memset(m, 0, sizeof(*m));
	m->type = b[1];
	m->code = b[2];
	m->status = b[3];
	m->as = get16(b + 6);
	m->seq = get16(b + 8);
	if (m->type == EGP_ACQUIRE) {
		if (m->code > 4 || m->status > 7)
			return -1;
		if (m->code <= 1) {
			if (len != 14 || m->status > 2)
				return -1;
			m->hello = get16(b + 10);
			m->poll = get16(b + 12);
			return m->hello && m->poll >= m->hello ? 0 : -1;
		}
		return len == 10 ? 0 : -1;
	}
	if ((m->status & 0x7f) > 2)
		return -1;
	if (m->type == EGP_REACH)
		return len == 10 && m->code <= 1 && m->status <= 2 ? 0 : -1;
	if (m->type == EGP_ERROR)
		return len == 24 && !m->code ? 0 : -1;
	if (m->code || len < 16)
		return -1;
	memcpy(&m->shared, b + 12, 4);
	if (!egp_network(m->shared))
		return -1;
	if (m->type == EGP_POLL)
		return len == 16 && !b[10] && !b[11] && m->status <= 2 ? 0 : -1;
	if (m->type != EGP_UPDATE)
		return -1;
	n = egp_classlen(m->shared);
	ng = b[10] + b[11];
	for (g = 0; g < ng; g++) {
		if (pos + 4 - n + 1 > len)
			return -1;
		gw = m->shared;
		memcpy((uint8_t *)&gw + n, b + pos, 4 - n);
		pos += 4 - n;
		nd = b[pos++];
		for (d = 0; d < nd; d++) {
			uint8_t distance;
			if (pos + 2 > len)
				return -1;
			distance = b[pos++];
			nr = b[pos++];
			for (r = 0; r < nr; r++) {
				struct in_addr net = { 0 };
				int k;
				if (pos == len || m->count == EGP_MAX_ROUTES)
					return -1;
				memcpy(&net, b + pos, 1);
				k = egp_classlen(net);
				if (!k || pos + k > len)
					return -1;
				memcpy(&net, b + pos, k);
				pos += k;
				m->routes[m->count++] = (struct egp_route){ net, gw, distance };
			}
		}
	}
	return pos == len ? 0 : -1;
}
int egp_encode(uint8_t *b, size_t cap, const struct egp_message *m, struct in_addr local)
{
	size_t len = 10, i;
	int n = 0;
	if (cap < EGP_MAX_PKT || m->count > EGP_MAX_ROUTES)
		return -1;
	memset(b, 0, cap);
	b[0] = 2;
	b[1] = m->type;
	b[2] = m->code;
	b[3] = m->status;
	put16(b + 6, m->as);
	put16(b + 8, m->seq);
	if (m->type == EGP_ACQUIRE && m->code <= 1) {
		len = 14;
		put16(b + 10, m->hello);
		put16(b + 12, m->poll);
	} else if (m->type == EGP_POLL || m->type == EGP_UPDATE) {
		if (!egp_network(m->shared))
			return -1;
		len = 16;
		memcpy(b + 12, &m->shared, 4);
		if (m->type == EGP_UPDATE && m->count) {
			n = egp_classlen(m->shared);
			if (memcmp(&local, &m->shared, n))
				return -1;
			b[10] = 1;
			memcpy(b + len, (const uint8_t *)&local + n, 4 - n);
			len += 4 - n;
			b[len++] = 1;
			b[len++] = 1;
			b[len++] = m->count;
			for (i = 0; i < m->count; i++) {
				n = egp_classlen(m->routes[i].net);
				if (!egp_network(m->routes[i].net) || len + n > cap)
					return -1;
				memcpy(b + len, &m->routes[i].net, n);
				len += n;
			}
		}
	} else if (m->type != EGP_REACH && m->type != EGP_ACQUIRE)
		return -1;
	put16(b + 4, egp_checksum(b, len));
	return len;
}
