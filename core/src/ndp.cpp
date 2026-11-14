// The emulated router's side of IPv6 neighbour discovery (RFC 4861, RDNSS RFC 8106).
// The router is fe80::1 at the router MAC. It answers router solicitations with
// an advertisement built from the modem's settings, and neighbour solicitations
// with the router MAC whatever unicast address they ask for, so all traffic goes
// to the emulated router. Duplicate-address checks (source ::) and solicitations
// for a multicast target, ::, or ::1 get no answer.
#include <string.h>

#include "rmnet/ethernet.h"
#include "rmnet/ip.h"

#include "ethernet_internal.h"

namespace rmnet {

using namespace eth_internal;

namespace {

constexpr uint8_t kNextHeaderIcmp6 = 58;
constexpr uint8_t kHopLimit = 255;  // RFC 4861 requires 255 on every ND message

constexpr uint8_t kRouterSolicit = 133;
constexpr uint8_t kRouterAdvert = 134;
constexpr uint8_t kNeighbourSolicit = 135;
constexpr uint8_t kNeighbourAdvert = 136;

// ICMPv6 message lengths before options.
constexpr size_t kRsLen = 8;   // type code checksum reserved
constexpr size_t kRaLen = 16;  // type code checksum hop-limit flags lifetime reachable retransmit
constexpr size_t kNsLen = 24;  // type code checksum reserved target
constexpr size_t kNaLen = 24;  // type code checksum flags+reserved target

constexpr uint8_t kOptSourceLla = 1;
constexpr uint8_t kOptTargetLla = 2;
constexpr uint8_t kOptPrefix = 3;
constexpr uint8_t kOptMtu = 5;
constexpr uint8_t kOptRdnss = 25;
constexpr size_t kLlaOptLen = 8;
constexpr size_t kMtuOptLen = 8;
constexpr size_t kPrefixOptLen = 32;
constexpr size_t kRdnssHeaderLen = 8;

constexpr uint8_t kCurHopLimit = 64;
constexpr uint16_t kRouterLifetime = 1800;
constexpr uint8_t kPrefixLen = 64;
constexpr uint8_t kPrefixFlags = 0xC0;  // on-link, autonomous
constexpr uint32_t kValidLifetime = 7200;
constexpr uint32_t kPreferredLifetime = 3600;
constexpr uint32_t kRdnssLifetime = 1800;
constexpr uint8_t kNaFlags = 0xE0;  // router, solicited, override
constexpr uint32_t kMinIpv6Mtu = 1280;

constexpr size_t kMaxDns = 2;
constexpr size_t kNaFrameLen = kEthHeaderLen + kIpv6HeaderLen + kNaLen + kLlaOptLen;

const uint8_t kRouterIp[16] = {0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
const uint8_t kAllNodesIp[16] = {0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
const uint8_t kAllNodesMac[6] = {0x33, 0x33, 0, 0, 0, 1};
const uint8_t kUnspecifiedIp[16] = {};
const uint8_t kLoopbackIp[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};

uint8_t* put_lla_option(uint8_t* o, uint8_t type, const uint8_t mac[6]) {
  o[0] = type;
  o[1] = kLlaOptLen / 8;
  memcpy(o + 2, mac, 6);
  return o + kLlaOptLen;
}

// Fills the IPv6 header in front of `icmp` and the ICMPv6 checksum.
void finish_icmp6(uint8_t* ip, const uint8_t src[16], const uint8_t dst[16], size_t icmp_len) {
  build_ipv6_header(ip, kIpv6HeaderLen, kNextHeaderIcmp6, src, dst, icmp_len, kHopLimit);
  uint8_t* icmp = ip + kIpv6HeaderLen;
  put16(icmp + 2, 0);
  put16(icmp + 2, icmp6_checksum(src, dst, icmp, icmp_len));
}

}  // namespace

bool EthernetEmulator::is_nd_solicit(const uint8_t* ip, size_t len) {
  if (len <= kIpv6HeaderLen || ip[6] != kNextHeaderIcmp6) return false;
  uint8_t type = ip[kIpv6HeaderLen];
  return type == kRouterSolicit || type == kNeighbourSolicit;
}

bool EthernetEmulator::is_router_advert(const uint8_t* ip, size_t len) {
  return len > kIpv6HeaderLen && (ip[0] >> 4) == 6 && ip[6] == kNextHeaderIcmp6 && ip[kIpv6HeaderLen] == kRouterAdvert;
}

// The caller must not pass addresses that lie inside `out`.
size_t EthernetEmulator::write_router_advert(uint8_t* out, size_t cap, const uint8_t eth_dst[6],
                                             const uint8_t ip_dst[16]) const {
  size_t dns_count = link_.v6_dns_count < kMaxDns ? link_.v6_dns_count : kMaxDns;
  bool has_mtu = link_.mtu >= kMinIpv6Mtu;
  size_t icmp_len = kRaLen + kLlaOptLen + (has_mtu ? kMtuOptLen : 0) + kPrefixOptLen +
                    (dns_count ? kRdnssHeaderLen + 16 * dns_count : 0);
  size_t frame_len = kEthHeaderLen + kIpv6HeaderLen + icmp_len;
  if (cap < frame_len) return 0;

  uint8_t* ip = out + kEthHeaderLen;
  uint8_t* icmp = ip + kIpv6HeaderLen;
  memset(icmp, 0, icmp_len);
  icmp[0] = kRouterAdvert;
  icmp[4] = kCurHopLimit;
  icmp[5] = 0;  // flags: no managed or other configuration
  put16(icmp + 6, kRouterLifetime);
  // Reachable time and retransmit timer stay 0 (unspecified).

  uint8_t* o = put_lla_option(icmp + kRaLen, kOptSourceLla, macs_.router);
  if (has_mtu) {
    o[0] = kOptMtu;
    o[1] = kMtuOptLen / 8;
    put32(o + 4, link_.mtu);
    o += kMtuOptLen;
  }
  // Always a /64, whatever v6_prefix_len says: the modem's network assigns the device a /64
  // (the recorded settings report 64), and SLAAC on Ethernet needs a 64-bit prefix to form an
  // address, so a different length would leave the host without a global address.
  o[0] = kOptPrefix;
  o[1] = kPrefixOptLen / 8;
  o[2] = kPrefixLen;
  o[3] = kPrefixFlags;
  put32(o + 4, kValidLifetime);
  put32(o + 8, kPreferredLifetime);
  memcpy(o + 16, link_.v6_addr, 8);  // first 64 bits; the rest and both reserved fields stay 0
  o += kPrefixOptLen;
  if (dns_count) {
    o[0] = kOptRdnss;
    o[1] = (uint8_t)((kRdnssHeaderLen + 16 * dns_count) / 8);
    put32(o + 4, kRdnssLifetime);
    for (size_t i = 0; i < dns_count; ++i) memcpy(o + kRdnssHeaderLen + 16 * i, link_.v6_dns[i], 16);
  }

  finish_icmp6(ip, kRouterIp, ip_dst, icmp_len);
  write_header(out, eth_dst, kEtherTypeIpv6);
  return frame_len;
}

size_t EthernetEmulator::make_router_advert(uint8_t* out, size_t cap) {
  if (!link_up_ || !link_.has_v6) return 0;
  return write_router_advert(out, cap, kAllNodesMac, kAllNodesIp);
}

// Router solicitation: advertisement to the soliciting address, or to all nodes
// from an unspecified source. Neighbour solicitation: advertisement of the router
// MAC for whatever target was asked, except for duplicate-address checks (source
// ::), which get no answer so the host keeps its address. Options are ignored.
TxResult EthernetEmulator::tx_nd(const uint8_t* ip, size_t len, uint8_t* reply, size_t cap) {
  const uint8_t* icmp = ip + kIpv6HeaderLen;
  size_t icmp_len = len - kIpv6HeaderLen;
  // Copied first so the reply is correct even if the caller passes the frame's own buffer as reply.
  uint8_t src[16];
  memcpy(src, ip + 8, 16);
  bool unspecified = memcmp(src, kUnspecifiedIp, 16) == 0;

  if (icmp[0] == kRouterSolicit) {
    if (icmp_len < kRsLen) return drop();
    size_t n = write_router_advert(reply, cap, macs_.host, unspecified ? kAllNodesIp : src);
    return n ? replied(n) : drop();
  }

  // Neighbour solicitation.
  if (icmp_len < kNsLen || unspecified) return drop();
  uint8_t target[16];
  memcpy(target, icmp + 8, 16);
  if (target[0] == 0xff) return drop();  // a multicast target is invalid (RFC 4861 7.1.1)
  if (memcmp(target, kUnspecifiedIp, 16) == 0 || memcmp(target, kLoopbackIp, 16) == 0) {
    return drop();  // :: and ::1 are never assigned to an interface (RFC 4291 2.5.2, 2.5.3)
  }
  if (cap < kNaFrameLen) return drop();

  uint8_t* out_ip = reply + kEthHeaderLen;
  uint8_t* na = out_ip + kIpv6HeaderLen;
  memset(na, 0, kNaLen);
  na[0] = kNeighbourAdvert;
  na[4] = kNaFlags;
  memcpy(na + 8, target, 16);
  put_lla_option(na + kNaLen, kOptTargetLla, macs_.router);
  finish_icmp6(out_ip, target, src, kNaLen + kLlaOptLen);
  write_header(reply, macs_.host, kEtherTypeIpv6);
  return replied(kNaFrameLen);
}

}  // namespace rmnet
