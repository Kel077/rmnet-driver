// The emulated router's DHCP server (RFC 2131, options RFC 2132). It hands the
// host the address settings the modem returned, so DHCP never reaches the modem.
#include <string.h>

#include "rmnet/ethernet.h"
#include "rmnet/ip.h"

#include "ethernet_internal.h"

namespace rmnet {

using namespace eth_internal;

namespace {

constexpr size_t kUdpHeaderLen = 8;
constexpr uint8_t kProtoUdp = 17;
constexpr uint16_t kPortServer = 67;
constexpr uint16_t kPortClient = 68;
constexpr uint8_t kTtl = 64;

// BOOTP fixed part: op htype hlen hops xid secs flags ciaddr yiaddr siaddr giaddr chaddr sname file.
constexpr size_t kBootpFixedLen = 236;
constexpr size_t kOffXid = 4;
constexpr size_t kOffFlags = 10;
constexpr size_t kOffCiaddr = 12;
constexpr size_t kOffYiaddr = 16;
constexpr size_t kOffChaddr = 28;
constexpr size_t kChaddrLen = 16;
constexpr size_t kOptionsStart = kBootpFixedLen + 4;  // after the magic cookie
constexpr size_t kMinBootpLen = 300;                  // what clients expect at least (RFC 1542)
constexpr uint8_t kMagicCookie[4] = {0x63, 0x82, 0x53, 0x63};

constexpr uint8_t kOpRequest = 1;
constexpr uint8_t kOpReply = 2;
constexpr uint8_t kHtypeEthernet = 1;
constexpr uint8_t kHlenEthernet = 6;

constexpr uint8_t kOptPad = 0;
constexpr uint8_t kOptMask = 1;
constexpr uint8_t kOptRouter = 3;
constexpr uint8_t kOptDns = 6;
constexpr uint8_t kOptMtu = 26;
constexpr uint8_t kOptRequestedIp = 50;
constexpr uint8_t kOptLease = 51;
constexpr uint8_t kOptMessageType = 53;
constexpr uint8_t kOptServerId = 54;
constexpr uint8_t kOptEnd = 255;

constexpr uint8_t kDiscover = 1;
constexpr uint8_t kOffer = 2;
constexpr uint8_t kRequest = 3;
constexpr uint8_t kAck = 5;
constexpr uint8_t kNak = 6;
constexpr uint8_t kInform = 8;

constexpr uint32_t kLeaseSeconds = 3600;
constexpr uint32_t kMinMtu = 68;  // RFC 2132 option 26 minimum

// Option bytes of the largest reply: 53, 54, 51, 1, 3, 6 (two servers), 26, 255.
constexpr size_t kMaxOptionsLen = 3 + 6 + 6 + 6 + 6 + 10 + 4 + 1;
constexpr size_t kReplyBootpLen =
    kOptionsStart + kMaxOptionsLen > kMinBootpLen ? kOptionsStart + kMaxOptionsLen : kMinBootpLen;
constexpr size_t kReplyFrameLen = kEthHeaderLen + kIpv4HeaderLen + kUdpHeaderLen + kReplyBootpLen;

const uint8_t kBroadcastIp[4] = {255, 255, 255, 255};

// The fields of a client message the reply needs, copied out so the reply
// may be written over the request.
struct ClientMessage {
  uint8_t type;
  uint8_t xid[4];
  uint8_t flags[2];
  uint8_t ciaddr[4];
  uint8_t chaddr[kChaddrLen];
  bool has_requested_ip;
  uint8_t requested_ip[4];
};

// Parses a BOOTP request with the magic cookie and option 53. False if malformed.
bool parse_client_message(const uint8_t* b, size_t len, ClientMessage* m) {
  if (len < kOptionsStart || b[0] != kOpRequest || memcmp(b + kBootpFixedLen, kMagicCookie, 4) != 0) {
    return false;
  }
  bool has_type = false;
  m->has_requested_ip = false;
  for (size_t i = kOptionsStart; i < len;) {
    uint8_t code = b[i];
    if (code == kOptPad) {
      ++i;
      continue;
    }
    if (code == kOptEnd) break;
    if (len - i < 2 || len - i - 2 < b[i + 1]) return false;  // option runs past the message
    uint8_t n = b[i + 1];
    const uint8_t* v = b + i + 2;
    if (code == kOptMessageType) {
      if (n != 1) return false;
      m->type = v[0];
      has_type = true;
    } else if (code == kOptRequestedIp) {
      if (n != 4) return false;
      memcpy(m->requested_ip, v, 4);
      m->has_requested_ip = true;
    }
    i += 2 + (size_t)n;
  }
  if (!has_type) return false;
  memcpy(m->xid, b + kOffXid, 4);
  memcpy(m->flags, b + kOffFlags, 2);
  memcpy(m->ciaddr, b + kOffCiaddr, 4);
  memcpy(m->chaddr, b + kOffChaddr, kChaddrLen);
  return true;
}

uint8_t* put_option(uint8_t* o, uint8_t code, const uint8_t* value, uint8_t n) {
  o[0] = code;
  o[1] = n;
  memcpy(o + 2, value, n);
  return o + 2 + n;
}

}  // namespace

bool EthernetEmulator::is_dhcp_client(const uint8_t* ip, size_t len) {
  size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
  bool first_fragment = (get16(ip + 6) & 0x1fff) == 0;
  return ip[9] == kProtoUdp && first_fragment && ihl >= kIpv4HeaderLen && len >= ihl + kUdpHeaderLen &&
         get16(ip + ihl) == kPortClient && get16(ip + ihl + 2) == kPortServer;
}

// Answers DISCOVER with OFFER, REQUEST with ACK or NAK, and INFORM with ACK.
// Every reply is broadcast from the gateway address. Anything else is dropped.
TxResult EthernetEmulator::tx_dhcp(const uint8_t*, const uint8_t* ip, size_t len, uint8_t* reply, size_t cap) {
  if (!link_.has_v4) return drop();
  size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
  const uint8_t* udp = ip + ihl;
  size_t udp_len = get16(udp + 4);
  if (udp_len < kUdpHeaderLen || udp_len > len - ihl) return drop();
  ClientMessage m;
  if (!parse_client_message(udp + kUdpHeaderLen, udp_len - kUdpHeaderLen, &m)) return drop();

  uint8_t type;
  bool give_address = true;  // yiaddr and lease
  switch (m.type) {
    case kDiscover: type = kOffer; break;
    case kRequest: {
      const uint8_t* asked = m.has_requested_ip ? m.requested_ip : m.ciaddr;
      type = memcmp(asked, link_.v4_addr, 4) == 0 ? kAck : kNak;
      break;
    }
    case kInform: type = kAck; give_address = false; break;
    default: return drop();
  }
  if (cap < kReplyFrameLen) return drop();

  memset(reply, 0, kReplyFrameLen);
  uint8_t* out_ip = reply + kEthHeaderLen;
  uint8_t* out_udp = out_ip + kIpv4HeaderLen;
  uint8_t* b = out_udp + kUdpHeaderLen;

  b[0] = kOpReply;
  b[1] = kHtypeEthernet;
  b[2] = kHlenEthernet;
  memcpy(b + kOffXid, m.xid, 4);
  memcpy(b + kOffFlags, m.flags, 2);
  if (give_address && type != kNak) memcpy(b + kOffYiaddr, link_.v4_addr, 4);
  memcpy(b + kOffChaddr, m.chaddr, kChaddrLen);
  memcpy(b + kBootpFixedLen, kMagicCookie, 4);

  uint8_t* o = b + kOptionsStart;
  o = put_option(o, kOptMessageType, &type, 1);
  o = put_option(o, kOptServerId, link_.v4_gateway, 4);
  if (type != kNak) {
    if (give_address) {
      uint8_t lease[4];
      put32(lease, kLeaseSeconds);
      o = put_option(o, kOptLease, lease, 4);
    }
    o = put_option(o, kOptMask, link_.v4_mask, 4);
    o = put_option(o, kOptRouter, link_.v4_gateway, 4);
    uint8_t dns_count = link_.v4_dns_count < 2 ? link_.v4_dns_count : 2;
    if (dns_count > 0) {
      *o++ = kOptDns;
      *o++ = (uint8_t)(4 * dns_count);
      for (uint8_t i = 0; i < dns_count; ++i, o += 4) memcpy(o, link_.v4_dns[i], 4);
    }
    if (link_.mtu >= kMinMtu && link_.mtu <= 0xffff) {
      uint8_t mtu[2];
      put16(mtu, (uint16_t)link_.mtu);
      o = put_option(o, kOptMtu, mtu, 2);
    }
  }
  *o = kOptEnd;

  size_t out_udp_len = kUdpHeaderLen + kReplyBootpLen;
  put16(out_udp, kPortServer);
  put16(out_udp + 2, kPortClient);
  put16(out_udp + 4, (uint16_t)out_udp_len);
  uint16_t sum = udp4_checksum(link_.v4_gateway, kBroadcastIp, out_udp, out_udp_len);
  put16(out_udp + 6, sum == 0 ? 0xffff : sum);  // 0 on the wire would mean "no checksum"

  build_ipv4_header(out_ip, kIpv4HeaderLen, kProtoUdp, link_.v4_gateway, kBroadcastIp, out_udp_len, kTtl);
  write_header(reply, macs_.host, kEtherTypeIpv4);
  return replied(kReplyFrameLen);
}

}  // namespace rmnet
