#include "rmnet/ip.h"

#include <string.h>

namespace rmnet {

namespace {

constexpr size_t kIpv4HeaderLen = 20;
constexpr size_t kIpv6HeaderLen = 40;
constexpr size_t kEchoHeaderLen = 8;  // type, code, checksum, identifier, sequence

constexpr uint8_t kProtoIcmp = 1;
constexpr uint8_t kProtoUdp = 17;
constexpr uint8_t kProtoIcmp6 = 58;

constexpr uint8_t kIcmp4EchoRequest = 8;
constexpr uint8_t kIcmp6EchoRequest = 128;

constexpr uint8_t kDefaultHopLimit = 64;

void put16(uint8_t* p, uint16_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)v;
}

// Pseudo-header length and protocol words; the addresses are summed by the caller.
uint32_t sum_len_proto(uint32_t acc, size_t len, uint8_t proto) {
  acc += (uint32_t)((len >> 16) & 0xffff);
  acc += (uint32_t)(len & 0xffff);
  acc += proto;
  return acc;
}

// Writes an echo request header plus data at `out` and fills its checksum
// over `pseudo` (the pseudo-header sum, 0 for ICMPv4).
void write_echo(uint8_t* out, uint8_t type, uint16_t id, uint16_t seq, const uint8_t* data, size_t n,
                uint32_t pseudo) {
  out[0] = type;
  out[1] = 0;
  put16(out + 2, 0);
  put16(out + 4, id);
  put16(out + 6, seq);
  if (n) memcpy(out + kEchoHeaderLen, data, n);
  put16(out + 2, fold_checksum(sum16(out, kEchoHeaderLen + n, pseudo)));
}

}  // namespace

uint32_t sum16(const uint8_t* data, size_t len, uint32_t acc) {
  size_t i = 0;
  for (; i + 1 < len; i += 2) {
    acc += (uint32_t)((data[i] << 8) | data[i + 1]);
    acc = (acc & 0xffff) + (acc >> 16);  // keep the carry folded so long buffers cannot overflow
  }
  if (i < len) {
    acc += (uint32_t)(data[i] << 8);
    acc = (acc & 0xffff) + (acc >> 16);
  }
  return acc;
}

uint16_t fold_checksum(uint32_t acc) {
  while (acc >> 16) acc = (acc & 0xffff) + (acc >> 16);
  return (uint16_t)~acc;
}

uint16_t udp4_checksum(const uint8_t src[4], const uint8_t dst[4], const uint8_t* udp, size_t len) {
  uint32_t acc = sum16(src, 4);
  acc = sum16(dst, 4, acc);
  acc = sum_len_proto(acc, len, kProtoUdp);
  return fold_checksum(sum16(udp, len, acc));
}

uint16_t icmp6_checksum(const uint8_t src[16], const uint8_t dst[16], const uint8_t* icmp, size_t len) {
  uint32_t acc = sum16(src, 16);
  acc = sum16(dst, 16, acc);
  acc = sum_len_proto(acc, len, kProtoIcmp6);
  return fold_checksum(sum16(icmp, len, acc));
}

size_t build_ipv4_header(uint8_t* out, size_t cap, uint8_t proto, const uint8_t src[4], const uint8_t dst[4],
                         size_t payload_len, uint8_t ttl) {
  if (cap < kIpv4HeaderLen || payload_len > 0xffff - kIpv4HeaderLen) return 0;
  out[0] = 0x45;  // version 4, IHL 5 words
  out[1] = 0;     // DSCP/ECN
  put16(out + 2, (uint16_t)(kIpv4HeaderLen + payload_len));
  put16(out + 4, 0);       // identification
  put16(out + 6, 0x4000);  // flags: DF; fragment offset 0
  out[8] = ttl;
  out[9] = proto;
  put16(out + 10, 0);
  memcpy(out + 12, src, 4);
  memcpy(out + 16, dst, 4);
  put16(out + 10, fold_checksum(sum16(out, kIpv4HeaderLen)));
  return kIpv4HeaderLen;
}

size_t build_ipv6_header(uint8_t* out, size_t cap, uint8_t next, const uint8_t src[16], const uint8_t dst[16],
                         size_t payload_len, uint8_t hop_limit) {
  if (cap < kIpv6HeaderLen || payload_len > 0xffff) return 0;
  out[0] = 0x60;  // version 6, traffic class 0
  out[1] = 0;     // traffic class / flow label 0
  out[2] = 0;
  out[3] = 0;
  put16(out + 4, (uint16_t)payload_len);
  out[6] = next;
  out[7] = hop_limit;
  memcpy(out + 8, src, 16);
  memcpy(out + 24, dst, 16);
  return kIpv6HeaderLen;
}

size_t build_icmp4_echo(uint8_t* out, size_t cap, const uint8_t src[4], const uint8_t dst[4], uint16_t id,
                        uint16_t seq, const uint8_t* data, size_t n) {
  if (n > 0xffff - kIpv4HeaderLen - kEchoHeaderLen) return 0;
  size_t icmp_len = kEchoHeaderLen + n;
  size_t total = kIpv4HeaderLen + icmp_len;
  if (cap < total) return 0;
  build_ipv4_header(out, cap, kProtoIcmp, src, dst, icmp_len, kDefaultHopLimit);
  write_echo(out + kIpv4HeaderLen, kIcmp4EchoRequest, id, seq, data, n, 0);
  return total;
}

size_t build_icmp6_echo(uint8_t* out, size_t cap, const uint8_t src[16], const uint8_t dst[16], uint16_t id,
                        uint16_t seq, const uint8_t* data, size_t n) {
  if (n > 0xffff - kEchoHeaderLen) return 0;
  size_t icmp_len = kEchoHeaderLen + n;
  size_t total = kIpv6HeaderLen + icmp_len;
  if (cap < total) return 0;
  build_ipv6_header(out, cap, kProtoIcmp6, src, dst, icmp_len, kDefaultHopLimit);
  uint32_t pseudo = sum_len_proto(sum16(dst, 16, sum16(src, 16)), icmp_len, kProtoIcmp6);
  write_echo(out + kIpv6HeaderLen, kIcmp6EchoRequest, id, seq, data, n, pseudo);
  return total;
}

}  // namespace rmnet
