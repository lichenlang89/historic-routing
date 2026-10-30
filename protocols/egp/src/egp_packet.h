// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef EGP_PACKET_H
#define EGP_PACKET_H
#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>
#define EGP_MAX_PKT 1500
#define EGP_MAX_ROUTES 255
/* RFC 904 A.1: Hello/Poll are 16-bit; treat anything above a day as nonsense. */
#define EGP_MAX_INTERVAL 86400
#define EGP_UPDATE 1
#define EGP_POLL 2
#define EGP_ACQUIRE 3
#define EGP_REACH 5
#define EGP_ERROR 8
/* RFC 904 A.5 Reason codes. */
#define EGP_ERR_HEADER 1
#define EGP_ERR_FIELD 2
#define EGP_ERR_NOINFO 3
#define EGP_ERR_RATE 4
#define EGP_ERR_NO_RESPONSE 5
/* RFC 904 A.1 acquisition status codes used by Refuse. */
#define EGP_STATUS_ACTIVE 1
#define EGP_STATUS_PASSIVE 2
#define EGP_STATUS_RESOURCES 3
#define EGP_STATUS_ADMIN 4
#define EGP_STATUS_GOING_DOWN 5
#define EGP_STATUS_PARAM 6
#define EGP_STATUS_VIOLATION 7
struct egp_route {
	struct in_addr net, gateway;
	uint8_t distance;
};
struct egp_message {
	uint8_t type, code, status;
	uint16_t as, seq, hello, poll;
	struct in_addr shared;
	/* Error messages (RFC 904 A.5): reason plus the offending 12-octet header. */
	uint16_t reason;
	uint8_t err_header[12];
	size_t count;
	struct egp_route routes[EGP_MAX_ROUTES];
};
int egp_classlen(struct in_addr addr);
int egp_network(struct in_addr addr);
uint16_t egp_checksum(const uint8_t *buf, size_t len);
int egp_decode(const uint8_t *buf, size_t len, struct egp_message *msg);
int egp_encode(uint8_t *buf, size_t cap, const struct egp_message *msg, struct in_addr local);
#endif
