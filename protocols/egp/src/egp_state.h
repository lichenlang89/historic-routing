/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef EGP_STATE_H
#define EGP_STATE_H
#include <time.h>
enum state { IDLE,
	     ACQUISITION,
	     DOWN,
	     UP,
	     CEASE };
enum egp_control { EGP_START,
	           EGP_STOP,
	           EGP_REQUEST,
	           EGP_CONFIRM,
	           EGP_REFUSE,
	           EGP_CEASE,
	           EGP_CEASE_ACK };
enum { EGP_P3 = 30,
       EGP_P4 = 3600,
       EGP_P5 = 120 };
/* P4/P5 are suggested minima, not caps on the negotiated reachability window.
 * A passive peer must have time to receive the active peer's first Up Hello. */
static inline unsigned egp_hold_interval(unsigned hello, unsigned minimum)
{
	unsigned window = 4U * hello;
	return window > minimum ? window : minimum;
}
/* RFC 904 section 3.4. Request assumes acquisition is accepted. */
static inline enum state egp_control_next(enum state s, enum egp_control e)
{
	static const enum state next[5][7] = {
	    {ACQUISITION, IDLE, DOWN, IDLE, IDLE, IDLE, IDLE},
	    {ACQUISITION, IDLE, DOWN, DOWN, IDLE, IDLE, ACQUISITION},
	    {ACQUISITION, CEASE, DOWN, DOWN, DOWN, IDLE, DOWN},
	    {ACQUISITION, CEASE, DOWN, UP, UP, IDLE, UP},
	    {CEASE, IDLE, CEASE, CEASE, CEASE, IDLE, IDLE}};
	return next[s][e];
}
static inline int egp_abort_due(enum state s, time_t deadline, time_t t)
{
	return s != IDLE && deadline && t >= deadline;
}
#endif
