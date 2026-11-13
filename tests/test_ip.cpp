#include "minitest.h"

#include "rmnet/ip.h"

TEST(checksum_rfc1071_example) {
  auto b = hex("00 01 f2 03 f4 f5 f6 f7");
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(b.data(), b.size())), 0x220d);
}
TEST(checksum_odd_length) {
  auto b = hex("01 02 03");                       // words 0x0102 + 0x0300 = 0x0402
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(b.data(), b.size())), 0xfbfd);
}
TEST(ipv4_header_matches_known_checksum) {         // 192.168.0.1 -> 192.168.0.199, UDP, 95 payload bytes, TTL 64
  uint8_t h[20]; const uint8_t s[4] = {192, 168, 0, 1}, d[4] = {192, 168, 0, 199};
  CHECK_EQ(rmnet::build_ipv4_header(h, sizeof h, 17, s, d, 95, 64), 20u);
  CHECK_BYTES(h, 20, "45 00 00 73 00 00 40 00 40 11 b8 61 c0 a8 00 01 c0 a8 00 c7");
  CHECK_EQ(rmnet::build_ipv4_header(h, 19, 17, s, d, 95, 64), 0u);
}
TEST(icmp4_echo_is_well_formed) {
  uint8_t p[64]; const uint8_t s[4] = {10, 102, 246, 230}, d[4] = {223, 5, 5, 5}; const uint8_t data[8] = {1,2,3,4,5,6,7,8};
  size_t n = rmnet::build_icmp4_echo(p, sizeof p, s, d, 0x1234, 7, data, 8);
  CHECK_EQ(n, 36u); CHECK_EQ(p[9], 1); CHECK_EQ(p[20], 8); CHECK_EQ(p[21], 0);
  CHECK_BYTES(p + 24, 4, "12 34 00 07");
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(p, 20)), 0);        // a valid header sums to zero
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(p + 20, 16)), 0);
}
TEST(icmp6_echo_is_well_formed) {
  uint8_t p[96]; auto s = hex("20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08"); auto d = hex("24 00 32 00 00 00 00 00 00 00 00 00 00 00 00 01");
  const uint8_t data[8] = {1,2,3,4,5,6,7,8};
  size_t n = rmnet::build_icmp6_echo(p, sizeof p, s.data(), d.data(), 0x1234, 7, data, 8);
  CHECK_EQ(n, 56u); CHECK_EQ(p[0] >> 4, 6); CHECK_EQ(p[6], 58); CHECK_EQ(p[7], 64); CHECK_EQ(p[40], 128);
  CHECK_BYTES(p + 4, 2, "00 10");
  uint16_t stored = (uint16_t)((p[42] << 8) | p[43]); p[42] = p[43] = 0;
  CHECK_EQ(rmnet::icmp6_checksum(s.data(), d.data(), p + 40, 16), stored);
}
TEST(udp4_checksum_validates) {                    // a UDP datagram with the checksum filled in sums, with its pseudo-header, to zero
  uint8_t u[12] = {0x00, 0x43, 0x00, 0x44, 0x00, 0x0c, 0, 0, 0xde, 0xad, 0xbe, 0xef};
  const uint8_t s[4] = {10, 0, 0, 1}, d[4] = {255, 255, 255, 255};
  uint16_t c = rmnet::udp4_checksum(s, d, u, sizeof u); u[6] = (uint8_t)(c >> 8); u[7] = (uint8_t)c;
  // Known answer: pseudo-header 0a00 0001 ffff ffff 0011 000c plus UDP 0043 0044 000c 0000 dead beef
  // sums to 0x3a84b, folds to 0xa84e, complements to 0x57b1.
  CHECK_EQ(c, 0x57b1);
  CHECK_EQ(rmnet::udp4_checksum(s, d, u, sizeof u), 0);
}
