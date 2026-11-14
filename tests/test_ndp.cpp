#include "minitest.h"

#include "frames.h"
#include "rmnet/ethernet.h"

static const char* kHostLL = "fe80::1839:e0b6:5dbb:6797";
static const char* kHostGlobal = "2001:db8:8af4:b260:1111:2222:3333:4444";

TEST(router_solicit_gets_router_advert) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = router_solicit(kHostLL);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
  auto d = parse_nd_reply(r, t.reply_len);
  CHECK(d.checksum_ok); CHECK_EQ(d.type, 134); CHECK_EQ(d.hop_limit, 255);
  CHECK_BYTES(d.eth_dst, 6, "02 68 7a 43 12 f6"); CHECK_EQ(d.ip_src, "fe80::1"); CHECK_EQ(d.ip_dst, kHostLL);
  CHECK_EQ(d.cur_hop_limit, 64); CHECK_EQ(d.flags, 0); CHECK_EQ(d.router_lifetime, 1800);
  CHECK_BYTES(d.source_lla, 6, "02 68 7a 43 12 f7"); CHECK_EQ(d.mtu, 1500u);
  CHECK_EQ(d.prefix, "2001:db8:8af4:b260::"); CHECK_EQ(d.prefix_len, 64); CHECK_EQ(d.prefix_flags, 0xc0);
  CHECK_EQ(d.valid_lifetime, 7200u); CHECK_EQ(d.preferred_lifetime, 3600u);
  CHECK_EQ(d.rdnss_lifetime, 1800u);
  REQUIRE(d.rdnss.size() == 2); CHECK_EQ(d.rdnss[0], "2001:db8:2000:0:270::1");
}
TEST(router_solicit_from_unspecified_goes_to_all_nodes) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = router_solicit("::");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK_EQ(parse_nd_reply(r, t.reply_len).ip_dst, "ff02::1");
}
TEST(unsolicited_router_advert) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[256];
  CHECK_EQ(e.make_router_advert(r, sizeof r), 0u);
  auto s = link_settings(); e.set_link(&s);
  size_t n = e.make_router_advert(r, sizeof r); auto d = parse_nd_reply(r, n);
  CHECK(d.checksum_ok); CHECK_EQ(d.type, 134); CHECK_EQ(d.ip_dst, "ff02::1"); CHECK_BYTES(d.eth_dst, 6, "33 33 00 00 00 01");
  s.has_v6 = false; e.set_link(&s); CHECK_EQ(e.make_router_advert(r, sizeof r), 0u);
}
TEST(neighbour_solicit_gets_advert_with_router_mac) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  for (const char* target : {"fe80::1", "2001:db8:8af4:b260:a089:88dc:137d:6253"}) {
    auto q = neighbour_solicit(kHostGlobal, target);
    auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
    auto d = parse_nd_reply(r, t.reply_len);
    CHECK(d.checksum_ok); CHECK_EQ(d.type, 136); CHECK_EQ(d.hop_limit, 255); CHECK_EQ(d.na_flags, 0xe0);
    CHECK_EQ(d.target, target); CHECK_EQ(d.ip_src, target); CHECK_EQ(d.ip_dst, kHostGlobal);
    CHECK_BYTES(d.target_lla, 6, "02 68 7a 43 12 f7"); CHECK_BYTES(d.eth_dst, 6, "02 68 7a 43 12 f6");
  }
}
TEST(neighbour_solicit_for_unspecified_or_loopback_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  for (const char* target : {"::", "::1"}) {
    auto q = neighbour_solicit(kHostGlobal, target);
    CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  }
  for (const char* target : {"fe80::1", "2001:db8:8af4:b260:a089:88dc:137d:6253"}) {  // still answered
    auto q = neighbour_solicit(kHostGlobal, target);
    CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Reply);
  }
}
TEST(dad_solicit_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = neighbour_solicit("::", kHostGlobal);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(rs_without_ipv6_link_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); s.has_v6 = false; e.set_link(&s); uint8_t r[256];
  auto q = router_solicit(kHostLL);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto ns = neighbour_solicit(kHostGlobal, "fe80::1");
  CHECK(e.handle_tx(ns.data(), ns.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(ipv6_multicast_dropped_unicast_forwarded) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto mld = icmp6(kHostLL, "ff02::16", 143, hex("00 00 00 00"));
  CHECK(e.handle_tx(mld.data(), mld.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto echo = icmp6(kHostGlobal, "2400:3200::1", 128, hex("12 34 00 01"));
  auto t = e.handle_tx(echo.data(), echo.size(), r, sizeof r);
  CHECK(t.action == rmnet::TxAction::Forward); CHECK_EQ(t.ip.len, echo.size() - 14);
}
TEST(truncated_nd_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = neighbour_solicit(kHostGlobal, "fe80::1");
  CHECK(e.handle_tx(q.data(), 14 + 40 + 10, r, sizeof r).action == rmnet::TxAction::Drop);          // cut inside the solicitation
  uint8_t tiny[40]; auto rs = router_solicit(kHostLL);
  CHECK(e.handle_tx(rs.data(), rs.size(), tiny, sizeof tiny).action == rmnet::TxAction::Drop);      // reply buffer too small
}
// `frame` (Ethernet + IPv6) cut to `icmp_len` ICMPv6 bytes, with the IPv6 payload length to match,
// so the emulator's IPv6 length check passes and the ND length check is what drops it.
static std::vector<uint8_t> cut_icmp6(std::vector<uint8_t> frame, size_t icmp_len) {
  frame.resize(14 + 40 + icmp_len);
  frame[14 + 4] = (uint8_t)(icmp_len >> 8); frame[14 + 5] = (uint8_t)icmp_len;
  return frame;
}
TEST(truncated_nd_with_matching_length_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto ns = cut_icmp6(neighbour_solicit(kHostGlobal, "fe80::1"), 10);              // shorter than the 24-byte solicitation
  CHECK(e.handle_tx(ns.data(), ns.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto rs = cut_icmp6(router_solicit(kHostLL), 4);                                  // shorter than the 8-byte solicitation
  CHECK(e.handle_tx(rs.data(), rs.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(router_advert_from_network_dropped_on_rx) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t out[256];
  auto ra = icmp6("fe80::a089:88dc:137d:6253", "ff02::1", 134, hex("40 00 07 08 00 00 00 00 00 00 00 00"));
  CHECK_EQ(e.wrap_rx(ra.data() + 14, ra.size() - 14, out, sizeof out), 0u);
  auto echo = icmp6("2400:3200::1", kHostGlobal, 129, hex("12 34 00 01"));
  CHECK_EQ(e.wrap_rx(echo.data() + 14, echo.size() - 14, out, sizeof out), echo.size());
}

// Pinned behaviour (the deferred list of 2026-11-13).

TEST(neighbour_solicit_for_a_multicast_target_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  for (const char* target : {"ff02::1", "ff02::1:ff00:1", "ff05::1:3"}) {
    auto q = neighbour_solicit(kHostGlobal, target);
    CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  }
}
TEST(advertisement_buffer_one_byte_short_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  std::vector<uint8_t> r(256, 0xee);
  auto untouched = [&] { return std::all_of(r.begin(), r.end(), [](uint8_t b) { return b == 0xee; }); };
  // Neighbour advertisement: 14 + 40 + 24 + 8 (target link-layer address) = 86 bytes.
  auto ns = neighbour_solicit(kHostGlobal, "fe80::1");
  CHECK(e.handle_tx(ns.data(), ns.size(), r.data(), 85).action == rmnet::TxAction::Drop); CHECK(untouched());
  auto t = e.handle_tx(ns.data(), ns.size(), r.data(), 86);
  CHECK(t.action == rmnet::TxAction::Reply); CHECK_EQ(t.reply_len, 86u);
  // Router advertisement for these settings: 14 + 40 + 16, then source link-layer address 8, MTU 8,
  // prefix 32 and RDNSS with two servers 40, so 158 bytes; answered or unsolicited.
  std::fill(r.begin(), r.end(), 0xee);
  auto rs = router_solicit(kHostLL);
  CHECK(e.handle_tx(rs.data(), rs.size(), r.data(), 157).action == rmnet::TxAction::Drop); CHECK(untouched());
  t = e.handle_tx(rs.data(), rs.size(), r.data(), 158);
  CHECK(t.action == rmnet::TxAction::Reply); CHECK_EQ(t.reply_len, 158u);
  std::fill(r.begin(), r.end(), 0xee);
  CHECK_EQ(e.make_router_advert(r.data(), 157), 0u); CHECK(untouched());
  CHECK_EQ(e.make_router_advert(r.data(), 158), 158u);
}
TEST(ipv6_unicast_dropped_on_ipv4_only_link) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); s.has_v6 = false; e.set_link(&s); uint8_t r[256];
  auto echo = icmp6(kHostGlobal, "2400:3200::1", 128, hex("12 34 00 01"));
  CHECK(e.handle_tx(echo.data(), echo.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto v4 = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, hex("aa bb"));
  CHECK(e.handle_tx(v4.data(), v4.size(), r, sizeof r).action == rmnet::TxAction::Forward);   // IPv4 still goes
}
TEST(non_icmpv6_packet_whose_payload_starts_with_134_reaches_the_host) {
  // From the network: IPv6 UDP (next header 17) from port 0x8601, so its first payload byte is 134,
  // a router advertisement's type. Only ICMPv6 router advertisements are kept from the host.
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t out[256];
  auto src = ipv6("2400:3200::1"), dst = ipv6(kHostGlobal);
  std::vector<uint8_t> p(40);
  REQUIRE(rmnet::build_ipv6_header(p.data(), p.size(), 17, src.data(), dst.data(), 8, 64) == 40u);
  const uint8_t udp[8] = {0x86, 0x01, 0x00, 0x35, 0x00, 0x08, 0x00, 0x00};
  p.insert(p.end(), udp, udp + 8);
  CHECK_EQ(e.wrap_rx(p.data(), p.size(), out, sizeof out), 14 + p.size());
  CHECK(std::equal(p.begin(), p.end(), out + 14));
  p[6] = 58;                                                                  // as ICMPv6 it is a router advertisement
  CHECK_EQ(e.wrap_rx(p.data(), p.size(), out, sizeof out), 0u);
}
