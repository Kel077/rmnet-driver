// Builders for the Ethernet frames tests feed to the Ethernet emulator.
// Addresses are given as text: IPv4 dotted ("10.102.246.230"), MAC as hex ("02 68 7a 43 12 f6").
#pragma once

#include <stdint.h>
#include <stddef.h>

#include <cstdio>
#include <cstdlib>
#include <string>
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

// Broadcast DHCP client message (BOOTP op 1) from the host MAC: IPv4 from ciaddr (or 0.0.0.0)
// to 255.255.255.255, UDP 68 to 67 with a valid checksum. Options: 53 `type`, then 50 with
// `requested_ip` unless it is empty, then 255. An empty `ciaddr` leaves ciaddr zero.
inline std::vector<uint8_t> dhcp_client(uint8_t type, uint32_t xid, const char* requested_ip, const char* ciaddr) {
  std::vector<uint8_t> ci = *ciaddr ? ipv4(ciaddr) : std::vector<uint8_t>(4, 0);
  std::vector<uint8_t> b(236, 0);
  b[0] = 1;  // op BOOTREQUEST
  b[1] = 1;  // htype Ethernet
  b[2] = 6;  // hlen
  b[4] = (uint8_t)(xid >> 24); b[5] = (uint8_t)(xid >> 16); b[6] = (uint8_t)(xid >> 8); b[7] = (uint8_t)xid;
  for (int i = 0; i < 4; ++i) b[12 + i] = ci[i];
  std::vector<uint8_t> hm = mac(kHostMac);
  for (int i = 0; i < 6; ++i) b[28 + i] = hm[i];
  std::vector<uint8_t> opts = {0x63, 0x82, 0x53, 0x63, 53, 1, type};
  if (*requested_ip) {
    std::vector<uint8_t> r = ipv4(requested_ip);
    opts.push_back(50); opts.push_back(4); opts.insert(opts.end(), r.begin(), r.end());
  }
  opts.push_back(255);
  b.insert(b.end(), opts.begin(), opts.end());

  std::vector<uint8_t> src = ci, dst = ipv4("255.255.255.255");
  size_t udp_len = 8 + b.size();
  std::vector<uint8_t> pkt(20);
  rmnet::build_ipv4_header(pkt.data(), pkt.size(), 17, src.data(), dst.data(), udp_len, 64);
  uint8_t udp[8] = {0, 68, 0, 67, (uint8_t)(udp_len >> 8), (uint8_t)udp_len, 0, 0};
  pkt.insert(pkt.end(), udp, udp + 8);
  pkt.insert(pkt.end(), b.begin(), b.end());
  uint16_t c = rmnet::udp4_checksum(src.data(), dst.data(), pkt.data() + 20, udp_len);
  if (c == 0) c = 0xffff;
  pkt[26] = (uint8_t)(c >> 8); pkt[27] = (uint8_t)c;
  return eth("ff ff ff ff ff ff", kHostMac, 0x0800, pkt);
}

// What a test needs to see of a DHCP reply frame. Addresses are dotted text, "" when absent;
// numbers are 0 when absent.
struct DhcpReply {
  int op = 0;
  uint32_t xid = 0;
  std::string yiaddr;
  uint8_t chaddr[16] = {};
  int type = 0;  // option 53
  std::string server_id;
  uint32_t lease = 0;
  std::string mask, router;
  std::vector<std::string> dns;
  int mtu = 0;
  std::string ip_src, ip_dst;
  bool checksums_ok = false;  // IPv4 header and UDP (pseudo-header included); a zero UDP checksum fails
};

inline std::string dotted(const uint8_t* a) {
  char buf[16];
  std::snprintf(buf, sizeof buf, "%u.%u.%u.%u", a[0], a[1], a[2], a[3]);
  return buf;
}

// Parses an Ethernet frame carrying IPv4/UDP/DHCP. Stops at the first thing out of bounds,
// leaving the remaining fields at their defaults.
inline DhcpReply parse_dhcp_reply(const uint8_t* bytes, size_t len) {
  DhcpReply d;
  if (len < 14 + 20) return d;
  const uint8_t* ip = bytes + 14;
  size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
  size_t total = (size_t)(ip[2] << 8 | ip[3]);
  if (ihl < 20 || total < ihl + 8 || 14 + total > len || ip[9] != 17) return d;
  d.ip_src = dotted(ip + 12);
  d.ip_dst = dotted(ip + 16);
  const uint8_t* udp = ip + ihl;
  size_t udp_len = (size_t)(udp[4] << 8 | udp[5]);
  if (udp_len < 8 || ihl + udp_len > total) return d;
  bool ip_ok = rmnet::fold_checksum(rmnet::sum16(ip, ihl)) == 0;
  bool udp_ok = (udp[6] | udp[7]) != 0 && rmnet::udp4_checksum(ip + 12, ip + 16, udp, udp_len) == 0;
  d.checksums_ok = ip_ok && udp_ok;
  const uint8_t* b = udp + 8;
  size_t blen = udp_len - 8;
  if (blen < 240) return d;
  d.op = b[0];
  d.xid = (uint32_t)b[4] << 24 | (uint32_t)b[5] << 16 | (uint32_t)b[6] << 8 | b[7];
  d.yiaddr = dotted(b + 16);
  for (int i = 0; i < 16; ++i) d.chaddr[i] = b[28 + i];
  for (size_t i = 240; i < blen;) {
    uint8_t code = b[i];
    if (code == 0) { ++i; continue; }
    if (code == 255 || i + 1 >= blen) break;
    size_t n = b[i + 1];
    const uint8_t* v = b + i + 2;
    if (i + 2 + n > blen) break;
    switch (code) {
      case 53: if (n == 1) d.type = v[0]; break;
      case 54: if (n == 4) d.server_id = dotted(v); break;
      case 51: if (n == 4) d.lease = (uint32_t)v[0] << 24 | (uint32_t)v[1] << 16 | (uint32_t)v[2] << 8 | v[3]; break;
      case 1: if (n == 4) d.mask = dotted(v); break;
      case 3: if (n >= 4) d.router = dotted(v); break;
      case 6: for (size_t k = 0; k + 4 <= n; k += 4) d.dns.push_back(dotted(v + k)); break;
      case 26: if (n == 2) d.mtu = v[0] << 8 | v[1]; break;
      default: break;
    }
    i += 2 + n;
  }
  return d;
}
