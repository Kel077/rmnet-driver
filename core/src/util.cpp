#include "rmnet/util.h"

#include <stdio.h>

namespace rmnet {

uint8_t prefix_length(const uint8_t mask[4]) {
  uint8_t n = 0;
  for (int i = 0; i < 4; i++) {
    for (int b = 7; b >= 0; b--) {
      if (mask[i] & (1u << b)) n++;
    }
  }
  return n;
}

void format_ipv4(const RuntimeSettings& s, char* out, size_t cap) {
  snprintf(out, cap, "%u.%u.%u.%u/%u gw %u.%u.%u.%u", s.v4_addr[0], s.v4_addr[1], s.v4_addr[2], s.v4_addr[3],
           prefix_length(s.v4_mask), s.v4_gateway[0], s.v4_gateway[1], s.v4_gateway[2], s.v4_gateway[3]);
}

void format_ipv6(const RuntimeSettings& s, char* out, size_t cap) {
  uint16_t g[8];
  for (int i = 0; i < 8; i++) g[i] = static_cast<uint16_t>(s.v6_addr[2 * i] << 8 | s.v6_addr[2 * i + 1]);
  int best = -1, best_len = 0;
  for (int i = 0; i < 8;) {
    if (g[i] != 0) {
      i++;
      continue;
    }
    int j = i;
    while (j < 8 && g[j] == 0) j++;
    if (j - i > best_len && j - i >= 2) {
      best = i;
      best_len = j - i;
    }
    i = j;
  }
  size_t n = 0;
  for (int i = 0; i < 8 && n < cap; i++) {
    if (i == best) {
      n += static_cast<size_t>(snprintf(out + n, cap - n, "::"));
      i += best_len - 1;
      continue;
    }
    bool sep = i > 0 && !(best >= 0 && i == best + best_len);
    n += static_cast<size_t>(snprintf(out + n, cap - n, sep ? ":%x" : "%x", g[i]));
  }
  if (n < cap) snprintf(out + n, cap - n, "/%u", s.v6_prefix_len);
}

}  // namespace rmnet
