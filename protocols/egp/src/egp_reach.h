/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef EGP_REACH_H
#define EGP_REACH_H
#include <stdbool.h>
#include <time.h>

/* RFC 904 section 4.3: four T1 intervals; at most one indication per T1.
 * Keep timestamps so delayed event-loop ticks cannot extend the window. */
struct egp_reach {
	time_t seen[4];
	unsigned count, next;
};
static inline bool egp_reach_record(struct egp_reach *r, time_t t, unsigned hello)
{
	if (r->count && t - r->seen[(r->next + 3) % 4] < (time_t)hello)
		return false;
	r->seen[r->next] = t;
	r->next = (r->next + 1) % 4;
	if (r->count < 4)
		r->count++;
	return true;
}
static inline unsigned egp_reach_hits(const struct egp_reach *r, time_t t, unsigned hello)
{
	unsigned i, hits = 0;
	for (i = 0; i < r->count; i++)
		if (t >= r->seen[i] && t - r->seen[i] < (time_t)(4 * hello))
			hits++;
	return hits;
}
#endif
