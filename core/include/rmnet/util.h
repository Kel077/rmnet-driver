// Small helpers the driver uses for its log lines and published properties: address text and a
// rate limit for repeated events. In Core so they are tested; the text is exactly what the driver
// printed before they moved here.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/qmi_msgs.h"

namespace rmnet {

// The number of set bits in an IPv4 netmask (network byte order): 255.255.255.252 gives 30.
uint8_t prefix_length(const uint8_t mask[4]);

// "a.b.c.d/n gw e.f.g.h" from the IPv4 address, mask and gateway, as snprintf into out[cap].
void format_ipv4(const RuntimeSettings& s, char* out, size_t cap);

// The IPv6 address in RFC 5952 text form (the longest run of two or more zero groups, the first if
// two are equal, shortened to ::), then "/n". Text that does not fit is cut short; out is always
// NUL-terminated when cap is above 0.
void format_ipv6(const RuntimeSettings& s, char* out, size_t cap);

// Rate limit for repeated events: true when n is a power of two (1, 2, 4, 8, ...), so the first
// ones are logged in full, then ever more rarely. The counters carry the rest.
inline bool worth(uint64_t n) { return n != 0 && (n & (n - 1)) == 0; }

}  // namespace rmnet
