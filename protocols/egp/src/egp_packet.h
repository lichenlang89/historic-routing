// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef EGP_PACKET_H
#define EGP_PACKET_H
#include <stddef.h>
#include <stdint.h>
#include <netinet/in.h>
#define EGP_MAX_PKT    1500
#define EGP_MAX_ROUTES 255
#define EGP_UPDATE     1
#define EGP_POLL       2
#define EGP_ACQUIRE    3
#define EGP_REACH      5
#define EGP_ERROR      8
struct egp_route {
	struct in_addr net, gateway;
	uint8_t distance;
};
struct egp_message {
	uint8_t type, code, status;
	uint16_t as, seq, hello, poll;
	struct in_addr shared;
	size_t count;
	struct egp_route routes[EGP_MAX_ROUTES];
};
int egp_classlen(struct in_addr addr);
int egp_network(struct in_addr addr);
uint16_t egp_checksum(const uint8_t *buf, size_t len);
int egp_decode(const uint8_t *buf, size_t len, struct egp_message *msg);
int egp_encode(uint8_t *buf, size_t cap, const struct egp_message *msg, struct in_addr local);
#endif
