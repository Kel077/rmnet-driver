#include "minitest.h"

#include "frames.h"
#include "rmnet/ethernet.h"

TEST(discover_gets_offer_with_modem_settings) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(1, 0x12345678, "", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
  CHECK_BYTES(r, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 00");
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.ip_src, "10.102.246.229"); CHECK_EQ(d.ip_dst, "255.255.255.255");
  CHECK_EQ(d.op, 2); CHECK_EQ(d.xid, 0x12345678u); CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "10.102.246.230");
  CHECK_BYTES(d.chaddr, 6, "02 68 7a 43 12 f6");
  CHECK_EQ(d.server_id, "10.102.246.229"); CHECK_EQ(d.lease, 3600u); CHECK_EQ(d.mask, "255.255.255.252");
  CHECK_EQ(d.router, "10.102.246.229"); CHECK_EQ(d.mtu, 1500);
  REQUIRE(d.dns.size() == 2); CHECK_EQ(d.dns[0], "203.0.113.193");
}
TEST(request_for_our_address_gets_ack) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 7, "10.102.246.230", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "10.102.246.230"); CHECK_EQ(d.lease, 3600u);
}
TEST(renewal_with_ciaddr_gets_ack) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 8, "", "10.102.246.230");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK_EQ(parse_dhcp_reply(r, t.reply_len).type, 5);
}
TEST(request_for_other_address_gets_nak) {          // macOS re-asking for its old ECM lease
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 9, "192.168.225.141", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 6); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.server_id, "10.102.246.229");
}
TEST(inform_gets_ack_without_lease) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(8, 10, "", "10.102.246.230");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.dns.size(), 2u);
}
TEST(dhcp_while_link_down_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[600];
  auto q = dhcp_client(1, 1, "", "");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto s = link_settings(); s.has_v4 = false; e.set_link(&s);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
// A dhcp_client() frame cut to `bootp_len` BOOTP bytes, with the IPv4 total length, IPv4 header
// checksum, UDP length and UDP checksum rewritten to match, so it passes the IPv4 and UDP checks.
static std::vector<uint8_t> refit(std::vector<uint8_t> frame, size_t bootp_len) {
  frame.resize(14 + 20 + 8 + bootp_len);
  uint8_t* ip = frame.data() + 14;
  uint8_t* udp = ip + 20;
  size_t total = 20 + 8 + bootp_len, udp_len = 8 + bootp_len;
  ip[2] = (uint8_t)(total >> 8); ip[3] = (uint8_t)total;
  ip[10] = ip[11] = 0;
  uint16_t c = rmnet::fold_checksum(rmnet::sum16(ip, 20)); ip[10] = (uint8_t)(c >> 8); ip[11] = (uint8_t)c;
  udp[4] = (uint8_t)(udp_len >> 8); udp[5] = (uint8_t)udp_len;
  udp[6] = udp[7] = 0;
  c = rmnet::udp4_checksum(ip + 12, ip + 16, udp, udp_len); if (c == 0) c = 0xffff;
  udp[6] = (uint8_t)(c >> 8); udp[7] = (uint8_t)c;
  return frame;
}
TEST(malformed_dhcp_with_matching_lengths_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 1, "10.102.246.230", "");               // options: cookie, 53 1 3, 50 4 <address>, 255
  size_t bootp = q.size() - 14 - 20 - 8;
  auto whole = refit(q, bootp);                                    // unchanged length: still answered
  CHECK(e.handle_tx(whole.data(), whole.size(), r, sizeof r).action == rmnet::TxAction::Reply);
  auto cut = refit(q, 100);                                        // cut inside BOOTP, before the cookie
  CHECK(e.handle_tx(cut.data(), cut.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto overrun = refit(q, 240 + 3 + 2 + 2);                        // option 50 says 4 bytes, 2 remain
  CHECK(e.handle_tx(overrun.data(), overrun.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto untyped = q; for (size_t i = 0; i < 3; ++i) untyped[14 + 20 + 8 + 240 + i] = 0;  // option 53 becomes padding
  untyped = refit(untyped, bootp);
  CHECK(e.handle_tx(untyped.data(), untyped.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(malformed_dhcp_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(1, 1, "", "");
  auto no_cookie = q; no_cookie[14 + 20 + 8 + 236] ^= 0xff;
  CHECK(e.handle_tx(no_cookie.data(), no_cookie.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(q.data(), 14 + 20 + 8 + 100, r, sizeof r).action == rmnet::TxAction::Drop);      // cut inside BOOTP
  auto release = dhcp_client(7, 1, "", "10.102.246.230");
  CHECK(e.handle_tx(release.data(), release.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  uint8_t small[100]; CHECK(e.handle_tx(q.data(), q.size(), small, sizeof small).action == rmnet::TxAction::Drop);  // reply buffer too small
}

// Pinned behaviour (the deferred list of 2026-11-13).

TEST(udp_checksum_computing_to_zero_is_sent_as_ffff) {
  // Two DISCOVERs' replies differ only in the xid they echo. With xid 0 the UDP checksum is c; the
  // xid 0000:c adds c to the ones'-complement sum, which then folds to 0xffff, so the checksum
  // computes to 0 and goes out as 0xffff (0 on the wire would mean "no checksum").
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto first = dhcp_client(1, 0, "", "");
  auto t = e.handle_tx(first.data(), first.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  uint16_t c = static_cast<uint16_t>(r[40] << 8 | r[41]);                    // the UDP checksum: 14 + 20 + 6
  CHECK(c != 0xffff);                                                         // an ordinary one
  auto q = dhcp_client(1, c, "", "");
  t = e.handle_tx(q.data(), q.size(), r, sizeof r); REQUIRE(t.action == rmnet::TxAction::Reply);
  CHECK_BYTES(r + 40, 2, "ff ff");
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.xid, c); CHECK(d.checksums_ok);                                  // 0xffff checks as 0 would
}
