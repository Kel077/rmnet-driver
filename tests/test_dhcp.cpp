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
  CHECK_EQ(d.router, "10.102.246.229"); CHECK_EQ(d.dns.size(), 2u); CHECK_EQ(d.dns[0], "203.0.113.193"); CHECK_EQ(d.mtu, 1500);
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
