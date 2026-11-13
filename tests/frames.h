// Builders for the Ethernet frames tests feed to the Ethernet emulator.
// Addresses are given as text: IPv4 dotted ("10.102.246.230"), MAC as hex ("02 68 7a 43 12 f6").
#pragma once

#include <stdint.h>
#include <stddef.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

#include "captures.h"
#include "minitest.h"
#include "rmnet/ip.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"

// The MACs derive_macs("bfeed1a5") gives.
inline const char* kHostMac = "02 68 7a 43 12 f6";
inline const char* kRouterMac = "02 68 7a 43 12 f7";

// Six bytes from hex text. Aborts on anything else.
inline std::vector<uint8_t> mac(const char* text) {
  std::vector<uint8_t> m = hex(text);
  if (m.size() != 6) {
    std::fprintf(stderr, "mac(): \"%s\" is not 6 bytes\n", text);
    std::abort();
  }
  return m;
}

// Four bytes from dotted-decimal text. Aborts on malformed text.
inline std::vector<uint8_t> ipv4(const char* text) {
  unsigned a, b, c, d;
  char rest;
  if (std::sscanf(text, "%u.%u.%u.%u%c", &a, &b, &c, &d, &rest) != 4 || a > 255 || b > 255 || c > 255 || d > 255) {
    std::fprintf(stderr, "ipv4(): malformed address \"%s\"\n", text);
    std::abort();
  }
  return {(uint8_t)a, (uint8_t)b, (uint8_t)c, (uint8_t)d};
}

// Ethernet II frame: destination, source, EtherType, payload.
inline std::vector<uint8_t> eth(const char* dst, const char* src, uint16_t ethertype,
                                const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> f = mac(dst);
  std::vector<uint8_t> s = mac(src);
  f.insert(f.end(), s.begin(), s.end());
  f.push_back((uint8_t)(ethertype >> 8));
  f.push_back((uint8_t)ethertype);
  f.insert(f.end(), payload.begin(), payload.end());
  return f;
}

// Broadcast ARP request (Ethernet/IPv4) from sender_mac asking for target_ip; target MAC zero.
inline std::vector<uint8_t> arp_request(const char* sender_mac, const char* sender_ip, const char* target_ip) {
  std::vector<uint8_t> p = hex("00 01 08 00 06 04 00 01");
  std::vector<uint8_t> sm = mac(sender_mac), si = ipv4(sender_ip), ti = ipv4(target_ip);
  p.insert(p.end(), sm.begin(), sm.end());
  p.insert(p.end(), si.begin(), si.end());
  p.insert(p.end(), 6, 0);
  p.insert(p.end(), ti.begin(), ti.end());
  return eth("ff ff ff ff ff ff", sender_mac, 0x0806, p);
}

// Ethernet frame from the host MAC to the router MAC carrying an IPv4 UDP datagram.
// The IPv4 header checksum is valid; the UDP checksum is 0 (not computed).
inline std::vector<uint8_t> ipv4_udp(const char* src, const char* dst, uint16_t sport, uint16_t dport,
                                     const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> s = ipv4(src), d = ipv4(dst);
  size_t udp_len = 8 + payload.size();
  std::vector<uint8_t> pkt(20);
  if (rmnet::build_ipv4_header(pkt.data(), pkt.size(), 17, s.data(), d.data(), udp_len, 64) != 20) {
    std::fprintf(stderr, "ipv4_udp(): payload too large\n");
    std::abort();
  }
  uint8_t udp[8] = {(uint8_t)(sport >> 8), (uint8_t)sport, (uint8_t)(dport >> 8), (uint8_t)dport,
                    (uint8_t)(udp_len >> 8), (uint8_t)udp_len, 0, 0};
  pkt.insert(pkt.end(), udp, udp + 8);
  pkt.insert(pkt.end(), payload.begin(), payload.end());
  return eth(kRouterMac, kHostMac, 0x0800, pkt);
}

// The link settings the modem reported in the recorded Get Current Settings replies (IPv4 and IPv6).
inline rmnet::RuntimeSettings link_settings() {
  rmnet::RuntimeSettings s{};
  for (const char* text : {kWdsSettings4Resp, kWdsSettings6Resp}) {
    std::vector<uint8_t> f = hex(text);
    rmnet::QmiMessage m{};
    if (!rmnet::qmi_decode({f.data(), f.size()}, &m) || !rmnet::parse_wds_current_settings(m, &s)) {
      std::fprintf(stderr, "link_settings(): recorded settings do not parse\n");
      std::abort();
    }
  }
  return s;
}
