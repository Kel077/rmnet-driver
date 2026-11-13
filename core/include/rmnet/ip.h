// Internet checksums (RFC 1071) and builders for IPv4, IPv6 and ICMP echo packets.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace rmnet {

// Running sum of big-endian 16-bit words; an odd last byte is the high byte.
uint32_t sum16(const uint8_t* data, size_t len, uint32_t acc = 0);

// Ones-complement of the folded sum. A buffer that already holds its own
// valid checksum folds to 0.
uint16_t fold_checksum(uint32_t acc);

// UDP-over-IPv4 checksum, pseudo-header included. `udp` is the whole datagram
// (header and payload) with whatever is in its checksum field summed as-is.
// A result of 0 is returned as 0; a sender must transmit it as 0xffff.
uint16_t udp4_checksum(const uint8_t src[4], const uint8_t dst[4], const uint8_t* udp, size_t len);

// ICMPv6 checksum, pseudo-header included. `icmp` is the whole message.
uint16_t icmp6_checksum(const uint8_t src[16], const uint8_t dst[16], const uint8_t* icmp, size_t len);

// All builders return the length written, or 0 if `cap` is too small or the
// lengths do not fit the header's length field.

// 20 bytes, no options, checksum filled, DF set, ID 0.
size_t build_ipv4_header(uint8_t* out, size_t cap, uint8_t proto, const uint8_t src[4], const uint8_t dst[4],
                         size_t payload_len, uint8_t ttl);

// 40 bytes, traffic class 0, flow label 0.
size_t build_ipv6_header(uint8_t* out, size_t cap, uint8_t next, const uint8_t src[16], const uint8_t dst[16],
                         size_t payload_len, uint8_t hop_limit);

// Whole IPv4 packet carrying an ICMP echo request, TTL 64.
size_t build_icmp4_echo(uint8_t* out, size_t cap, const uint8_t src[4], const uint8_t dst[4], uint16_t id,
                        uint16_t seq, const uint8_t* data, size_t n);

// Whole IPv6 packet carrying an ICMPv6 echo request, hop limit 64.
size_t build_icmp6_echo(uint8_t* out, size_t cap, const uint8_t src[16], const uint8_t dst[16], uint16_t id,
                        uint16_t seq, const uint8_t* data, size_t n);

}  // namespace rmnet
