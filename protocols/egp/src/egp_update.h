/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef EGP_UPDATE_H
#define EGP_UPDATE_H
#include <stdbool.h>
#include <stdint.h>
/* RFC 904 4.1.1 / 4.4: R follows commands, and one unsolicited Update is
 * allowed between successive Polls. A repeated Poll does not grant credit. */
struct egp_update_window {
	uint16_t reply_seq, last_poll;
	bool command_seen, poll_seen, tx_used, rx_used, dirty;
};
static inline void egp_update_command(struct egp_update_window *w, uint16_t seq, bool poll)
{
	w->command_seen = true;
	w->reply_seq = seq;
	if (poll && (!w->poll_seen || seq != w->last_poll)) {
		w->poll_seen = true;
		w->last_poll = seq;
		w->tx_used = false;
	}
}
static inline bool egp_update_matches(const struct egp_update_window *w, bool unsolicited,
                                      uint16_t seq, uint16_t current, bool pending, uint16_t poll_seq)
{
	return unsolicited ? !w->rx_used && seq == current : pending && seq == poll_seq;
}
#endif
