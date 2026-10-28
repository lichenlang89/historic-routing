/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef EGP_AGE_H
#define EGP_AGE_H
#include "egp_packet.h"
/* RFC 888 section 5 leaves "several" unspecified; choose three successive
 * accepted Updates. Explicit distance 255 always withdraws immediately. */
#define EGP_OMISSION_LIMIT 3
static inline int egp_age_update(const struct egp_route *old, size_t old_count,
	const uint8_t *misses, const struct egp_message *m,
	struct egp_route *next, uint8_t *next_misses)
{
	size_t i, j, count = 0;
	if (old_count > EGP_MAX_ROUTES || m->count > EGP_MAX_ROUTES)
		return -1;
	/* Ambiguous duplicate network claims must not age or overwrite the RIB. */
	for (i = 0; i < m->count; i++)
		for (j = 0; j < i; j++)
			if (m->routes[i].net.s_addr == m->routes[j].net.s_addr)
				return -1;
	for (i = 0; i < old_count; i++) {
		for (j = 0; j < m->count; j++)
			if (old[i].net.s_addr == m->routes[j].net.s_addr)
				break;
		if (j < m->count) {
			if (m->routes[j].distance == 255)
				continue;
			next[count] = m->routes[j];
			next_misses[count++] = 0;
		} else if (misses[i] < EGP_OMISSION_LIMIT - 1) {
			next[count] = old[i];
			next_misses[count++] = misses[i] + 1;
		}
	}
	for (i = 0; i < m->count; i++) {
		if (m->routes[i].distance == 255)
			continue;
		for (j = 0; j < old_count; j++)
			if (m->routes[i].net.s_addr == old[j].net.s_addr)
				break;
		if (j < old_count)
			continue;
		if (count == EGP_MAX_ROUTES)
			return -1;
		next[count] = m->routes[i];
		next_misses[count++] = 0;
	}
	return (int)count;
}
#endif
