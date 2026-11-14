#include "minitest.h"

#include <string.h>

#include "frames.h"
#include "rmnet/ethernet.h"

TEST(macs_are_stable_local_and_distinct) {
  auto m = rmnet::derive_macs("bfeed1a5");
  CHECK_BYTES(m.host, 6, "02 68 7a 43 12 f6"); CHECK_BYTES(m.router, 6, "02 68 7a 43 12 f7");
  CHECK_BYTES(rmnet::derive_macs("other").host, 6, "02 61 c2 56 2a 54");
}
TEST(wrap_rx_adds_header) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  auto p4 = hex("45 00 00 14 00 00 40 00 40 01 00 00 df 05 05 05 0a 66 f6 e6"); uint8_t out[64];
  CHECK_EQ(e.wrap_rx(p4.data(), p4.size(), out, sizeof out), 34u);
  CHECK_BYTES(out, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 00"); CHECK_BYTES(out + 14, 20, "45 00 00 14 00 00 40 00 40 01 00 00 df 05 05 05 0a 66 f6 e6");
  std::vector<uint8_t> p6(40, 0); p6[0] = 0x60; p6[6] = 17;
  CHECK_EQ(e.wrap_rx(p6.data(), p6.size(), out, sizeof out), 54u); CHECK_BYTES(out + 12, 2, "86 dd");
}
TEST(wrap_rx_drops_garbage) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  uint8_t out[64]; auto bad = hex("30 00 00 00");
  CHECK_EQ(e.wrap_rx(bad.data(), bad.size(), out, sizeof out), 0u);
  CHECK_EQ(e.wrap_rx(bad.data(), 0, out, sizeof out), 0u);
  auto p4 = hex("45 00 00 14 00 00 40 00 40 01 00 00 df 05 05 05 0a 66 f6 e6");
  CHECK_EQ(e.wrap_rx(p4.data(), p4.size(), out, 20), 0u);
}
TEST(tx_ipv4_unicast_is_forwarded) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  auto f = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, hex("aa bb")); uint8_t r[128];
  auto t = e.handle_tx(f.data(), f.size(), r, sizeof r);
  CHECK(t.action == rmnet::TxAction::Forward); CHECK(t.ip.data == f.data() + 14); CHECK_EQ(t.ip.len, f.size() - 14);
}
TEST(tx_ipv4_dropped_on_ipv6_only_link) {          // the Mac's link-local IPv4 must not reach the modem
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); s.has_v4 = false; e.set_link(&s);
  uint8_t r[128];
  for (const char* src : {"169.254.12.34", "10.102.246.230"}) {
    auto f = ipv4_udp(src, "1.1.1.1", 5000, 53, hex("aa bb"));
    CHECK(e.handle_tx(f.data(), f.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  }
  auto echo = icmp6("2001:db8:8af4:b260:1111:2222:3333:4444", "2400:3200::1", 128, hex("12 34 00 01"));
  CHECK(e.handle_tx(echo.data(), echo.size(), r, sizeof r).action == rmnet::TxAction::Forward);  // IPv6 still goes
}
TEST(tx_drops_what_cannot_go_upstream) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto lldp = eth("01 80 c2 00 00 0e", "02 68 7a 43 12 f6", 0x88cc, hex("00 00"));
  CHECK(e.handle_tx(lldp.data(), lldp.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(lldp.data(), 10, r, sizeof r).action == rmnet::TxAction::Drop);
  auto bcast = ipv4_udp("10.102.246.230", "255.255.255.255", 5000, 9999, hex("aa"));
  CHECK(e.handle_tx(bcast.data(), bcast.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto mdns = ipv4_udp("10.102.246.230", "224.0.0.251", 5353, 5353, hex("aa"));
  CHECK(e.handle_tx(mdns.data(), mdns.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(arp_request_gets_router_mac) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  for (const char* target : {"10.102.246.229", "8.8.8.8"}) {
    auto q = arp_request("02 68 7a 43 12 f6", "10.102.246.230", target);
    auto t = e.handle_tx(q.data(), q.size(), r, sizeof r);
    CHECK(t.action == rmnet::TxAction::Reply); CHECK_EQ(t.reply_len, 42u);
    CHECK_BYTES(r, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 06");
    CHECK_BYTES(r + 14, 8, "00 01 08 00 06 04 00 02");
    CHECK_BYTES(r + 22, 6, "02 68 7a 43 12 f7"); CHECK(memcmp(r + 28, q.data() + 38, 4) == 0);   // sender IP = requested IP
    CHECK_BYTES(r + 32, 6, "02 68 7a 43 12 f6"); CHECK_BYTES(r + 38, 4, "0a 66 f6 e6");
  }
}
TEST(arp_probe_and_announcement_get_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto probe = arp_request("02 68 7a 43 12 f6", "0.0.0.0", "10.102.246.230");
  CHECK(e.handle_tx(probe.data(), probe.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto announce = arp_request("02 68 7a 43 12 f6", "10.102.246.230", "10.102.246.230");
  CHECK(e.handle_tx(announce.data(), announce.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(arp_for_own_address_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto q = arp_request("02 68 7a 43 12 f6", "192.168.225.141", "10.102.246.230");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(arp_while_link_down_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[128];
  auto q = arp_request("02 68 7a 43 12 f6", "10.102.246.230", "10.102.246.229");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto s = link_settings(); e.set_link(&s); e.set_link(nullptr);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}

// Pinned behaviour (the deferred list of 2026-11-13): lengths, versions and ARP's refusals.

static const char* kHostGlobal6 = "2001:db8:8af4:b260:1111:2222:3333:4444";

TEST(ethernet_padding_is_trimmed_before_forwarding) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto f4 = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, hex("aa bb"));    // 44 bytes, IPv4 total length 30
  f4.resize(60, 0x00);                                                        // padded to Ethernet's minimum frame
  auto t = e.handle_tx(f4.data(), f4.size(), r, sizeof r);
  CHECK(t.action == rmnet::TxAction::Forward); CHECK(t.ip.data == f4.data() + 14); CHECK_EQ(t.ip.len, 30u);
  auto f6 = icmp6(kHostGlobal6, "2400:3200::1", 128, hex("12 34 00 01"));     // IPv6 payload length 8
  size_t whole = f6.size(); f6.resize(whole + 6, 0x00);                       // 6 bytes after the payload
  t = e.handle_tx(f6.data(), f6.size(), r, sizeof r);
  CHECK(t.action == rmnet::TxAction::Forward); CHECK(t.ip.data == f6.data() + 14); CHECK_EQ(t.ip.len, whole - 14);
}
TEST(ip_length_larger_than_the_frame_is_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto f4 = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, hex("aa bb"));    // total length 30
  CHECK(e.handle_tx(f4.data(), f4.size() - 1, r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(f4.data(), f4.size(), r, sizeof r).action == rmnet::TxAction::Forward);
  auto f6 = icmp6(kHostGlobal6, "2400:3200::1", 128, hex("12 34 00 01"));     // payload length 8
  CHECK(e.handle_tx(f6.data(), f6.size() - 1, r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(f6.data(), f6.size(), r, sizeof r).action == rmnet::TxAction::Forward);
}
TEST(ip_version_not_matching_the_ethertype_is_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  // IPv4 under the IPv6 EtherType, 68 bytes: read as IPv6, its payload length (the IPv4
  // identification) is 0 and it would be forwarded, but for its version.
  auto v4 = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, std::vector<uint8_t>(40, 0xaa));
  CHECK(e.handle_tx(v4.data(), v4.size(), r, sizeof r).action == rmnet::TxAction::Forward);
  auto as6 = v4; as6[12] = 0x86; as6[13] = 0xdd;
  CHECK(e.handle_tx(as6.data(), as6.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  // IPv6 under the IPv4 EtherType, its flow label set so the bytes IPv4 reads as the total length say
  // 48 (the whole packet): read as IPv4 it would be forwarded, but for its version.
  auto v6 = icmp6(kHostGlobal6, "2400:3200::1", 128, hex("12 34 00 01"));
  v6[14 + 2] = 0x00; v6[14 + 3] = 0x30;
  CHECK(e.handle_tx(v6.data(), v6.size(), r, sizeof r).action == rmnet::TxAction::Forward);
  auto as4 = v6; as4[12] = 0x08; as4[13] = 0x00;
  CHECK(e.handle_tx(as4.data(), as4.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(short_ipv4_is_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto f = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, hex("aa bb"));
  CHECK(e.handle_tx(f.data(), 14 + 19, r, sizeof r).action == rmnet::TxAction::Drop);    // 19 bytes: less than a header
  auto g = f; g[14 + 2] = 0x00; g[14 + 3] = 19;                               // total length 19: less than its header
  CHECK(e.handle_tx(g.data(), g.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(f.data(), f.size(), r, sizeof r).action == rmnet::TxAction::Forward);
}
TEST(malformed_arp_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto q = arp_request("02 68 7a 43 12 f6", "10.102.246.230", "10.102.246.229");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Reply);   // as built: answered
  CHECK(e.handle_tx(q.data(), 14 + 27, r, sizeof r).action == rmnet::TxAction::Drop);     // shorter than the 28-byte body
  const struct { size_t at; uint8_t value; } changes[] = {
      {14 + 1, 0x06},  // hardware type 6, not Ethernet (1)
      {14 + 3, 0x06},  // protocol type 0x0806, not IPv4 (0x0800)
      {14 + 4, 0x08},  // hardware address length 8, not 6
      {14 + 5, 0x10},  // protocol address length 16, not 4
      {14 + 7, 0x02},  // operation 2, a reply, not a request
  };
  for (const auto& c : changes) {
    auto bad = q; bad[c.at] = c.value;
    CHECK(e.handle_tx(bad.data(), bad.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  }
}
TEST(arp_reply_buffer_too_small_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  auto q = arp_request("02 68 7a 43 12 f6", "10.102.246.230", "10.102.246.229");
  uint8_t r[64]; memset(r, 0xee, sizeof r);
  CHECK(e.handle_tx(q.data(), q.size(), r, 41).action == rmnet::TxAction::Drop);          // a reply is 14 + 28 = 42 bytes
  CHECK(std::all_of(r, r + sizeof r, [](uint8_t b) { return b == 0xee; }));
  auto t = e.handle_tx(q.data(), q.size(), r, 42);
  CHECK(t.action == rmnet::TxAction::Reply); CHECK_EQ(t.reply_len, 42u);
}
