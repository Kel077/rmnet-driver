#include "minitest.h"

#include <string.h>

#include <list>

#include "captures.h"
#include "frames.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"

namespace {

// Owns every frame a test decodes, so each QmiMessage's tlvs span stays valid for the whole run.
std::list<std::vector<uint8_t>>& frame_store() {
  static std::list<std::vector<uint8_t>> frames;
  return frames;
}

rmnet::QmiMessage decode_bytes(std::vector<uint8_t> bytes) {
  frame_store().push_back(std::move(bytes));
  const std::vector<uint8_t>& f = frame_store().back();
  rmnet::QmiMessage m = {{rmnet::QmiService::CTL, 0, rmnet::QmiKind::Request, 0, 0}, {nullptr, 0}};
  if (!rmnet::qmi_decode({f.data(), f.size()}, &m)) {
    ::minitest::fail(__FILE__, __LINE__, "decode(): frame does not decode");
  }
  return m;
}

rmnet::QmiMessage decode(const char* hex_text) { return decode_bytes(hex(hex_text)); }

// Builds a WDS frame of `kind` with the given TLVs, each written as raw bytes.
struct RawTlv {
  uint8_t type;
  std::vector<uint8_t> value;
};
rmnet::QmiMessage wds_frame(rmnet::QmiKind kind, uint16_t msg_id, const std::vector<RawTlv>& tlvs) {
  std::vector<uint8_t> buf(256);
  rmnet::QmiBuilder b(buf.data(), buf.size(), {rmnet::QmiService::WDS, 15, kind, 4, msg_id});
  for (const RawTlv& t : tlvs) b.tlv(t.type, t.value.data(), t.value.size());
  buf.resize(b.finish());
  return decode_bytes(std::move(buf));
}

// Start Network response that failed: result 01 00 0e 00, TLV 0x10 = 02 00, TLV 0x11 = 03 00 d0 07.
rmnet::QmiMessage failed_start_frame() {
  return wds_frame(rmnet::QmiKind::Response, rmnet::kWdsStartNetwork,
                   {{0x02, {0x01, 0x00, 0x0e, 0x00}}, {0x10, {0x02, 0x00}}, {0x11, {0x03, 0x00, 0xd0, 0x07}}});
}

// Successful Get Current Settings response whose IPv4 address TLV (0x1E) is only 2 bytes.
rmnet::QmiMessage short_address_frame() {
  return wds_frame(rmnet::QmiKind::Response, rmnet::kWdsGetCurrentSettings,
                   {{0x02, {0x00, 0x00, 0x00, 0x00}}, {0x1e, {0x0a, 0x66}}});
}

// Packet Service Status indication whose status TLV (0x01) is only 1 byte.
rmnet::QmiMessage short_status_frame() {
  return wds_frame(rmnet::QmiKind::Indication, rmnet::kWdsPacketServiceStatus, {{0x01, {0x02}}});
}

}  // namespace

TEST(builders_match_capture) {
  uint8_t b[128]; size_t n;
  n = rmnet::build_ctl_sync(b, sizeof b, 1);                                   CHECK_BYTES(b, n, kCtlSyncReq);
  n = rmnet::build_ctl_get_client_id(b, sizeof b, 2, rmnet::QmiService::WDA);  CHECK_BYTES(b, n, kCtlGetWdaReq);
  n = rmnet::build_ctl_release_client_id(b, sizeof b, 5, rmnet::QmiService::WDS, 16); CHECK_BYTES(b, n, kCtlRelease6Req);
  n = rmnet::build_wda_set_data_format(b, sizeof b, 1, 1, 4, false);           CHECK_BYTES(b, n, kWdaSetFormatReq);
  n = rmnet::build_wds_bind_mux(b, sizeof b, 15, 2, 4, 0x81);                  CHECK_BYTES(b, n, kWdsBind4Req);
  n = rmnet::build_wds_set_ip_family(b, sizeof b, 15, 3, 4);                   CHECK_BYTES(b, n, kWdsFamily4Req);
  n = rmnet::build_wds_start_network(b, sizeof b, 15, 4, 1, 4);                CHECK_BYTES(b, n, kWdsStart4Req);
  n = rmnet::build_wds_get_current_settings(b, sizeof b, 15, 5);               CHECK_BYTES(b, n, kWdsSettings4Req);
  n = rmnet::build_wds_stop_network(b, sizeof b, 16, 10, 0xe2b3f370);          CHECK_BYTES(b, n, kWdsStop6Req);
}
TEST(parse_client_id) {            // decode() is a test helper: hex + qmi_decode
  rmnet::QmiService s; uint8_t c;
  CHECK(rmnet::parse_ctl_get_client_id(decode(kCtlGetWds4Resp), &s, &c));
  CHECK(s == rmnet::QmiService::WDS); CHECK_EQ(c, 15);
}
TEST(parse_data_format) {
  rmnet::DataFormat f{};
  CHECK(rmnet::parse_wda_data_format(decode(kWdaSetFormatResp), &f));
  CHECK_EQ(f.link_layer, 2u); CHECK_EQ(f.ul_agg, 5u); CHECK_EQ(f.dl_agg, 5u);
  CHECK_EQ(f.dl_max_datagrams, 32u); CHECK_EQ(f.dl_max_size, 31744u);
  CHECK_EQ(f.ul_max_datagrams, 32u); CHECK_EQ(f.ul_max_size, 16384u);
  CHECK(rmnet::data_format_usable(f));
  f.link_layer = 1; CHECK(!rmnet::data_format_usable(f));
}
TEST(data_format_without_uplink_size_unusable) {   // the capture's response without TLV 0x18 (uplink max size)
  rmnet::DataFormat f{};
  CHECK(rmnet::parse_wda_data_format(decode_bytes(without_tlv(hex(kWdaSetFormatResp), 0x18)), &f));
  CHECK_EQ(f.ul_max_size, 0u); CHECK(!rmnet::data_format_usable(f));
  CHECK(rmnet::parse_wda_data_format(decode_bytes(without_tlv(hex(kWdaSetFormatResp), 0x17)), &f));
  CHECK_EQ(f.ul_max_datagrams, 0u); CHECK(!rmnet::data_format_usable(f));
}
TEST(data_format_limits) {                          // from the capture's values: 32/31744 down, 32/16384 up
  rmnet::DataFormat ok{};
  CHECK(rmnet::parse_wda_data_format(decode(kWdaSetFormatResp), &ok));
  rmnet::DataFormat f = ok; f.ul_max_size = 1500;   CHECK(!rmnet::data_format_usable(f));
  f = ok; f.ul_max_size = 2048;                     CHECK(rmnet::data_format_usable(f));
  f = ok; f.ul_max_size = 16385;                    CHECK(!rmnet::data_format_usable(f));
  f = ok; f.dl_max_size = 31745;                    CHECK(!rmnet::data_format_usable(f));
  f = ok; f.dl_max_size = 2048;                     CHECK(rmnet::data_format_usable(f));
  f = ok; f.dl_max_size = 2047;                     CHECK(!rmnet::data_format_usable(f));
  f = ok; f.dl_max_datagrams = 0;                   CHECK(!rmnet::data_format_usable(f));
  f = ok; f.ul_max_datagrams = 0;                   CHECK(!rmnet::data_format_usable(f));
  f = ok; f.dl_max_datagrams = 1; f.ul_max_datagrams = 1; CHECK(rmnet::data_format_usable(f));
}
TEST(parse_start_network_handle) {
  uint32_t h = 0; rmnet::CallEnd e{};
  CHECK(rmnet::parse_wds_start_network(decode(kWdsStart4Resp), &h, &e)); CHECK_EQ(h, 0xe2b29ac0u);
}
TEST(parse_start_network_failure) {  // built in the test: result 01 00 0e 00, TLV 0x10 = 02 00, TLV 0x11 = 03 00 d0 07
  uint32_t h = 0; rmnet::CallEnd e{};
  CHECK(!rmnet::parse_wds_start_network(failed_start_frame(), &h, &e));
  CHECK_EQ(e.reason, 2); CHECK_EQ(e.verbose_type, 3); CHECK_EQ(e.verbose_reason, 2000);
}
TEST(parse_settings_ipv4) {
  rmnet::RuntimeSettings s{};
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings4Resp), &s));
  CHECK(s.has_v4); CHECK(!s.has_v6);
  CHECK_BYTES(s.v4_addr, 4, "0a 66 f6 e6"); CHECK_BYTES(s.v4_gateway, 4, "0a 66 f6 e5"); CHECK_BYTES(s.v4_mask, 4, "ff ff ff fc");
  CHECK_EQ(s.v4_dns_count, 2); CHECK_BYTES(s.v4_dns[0], 4, "cb 00 71 c1"); CHECK_BYTES(s.v4_dns[1], 4, "cb 00 71 d1");
  CHECK_EQ(s.mtu, 1500u);
}
TEST(parse_settings_ipv6_merges) {
  rmnet::RuntimeSettings s{};
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings4Resp), &s));
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings6Resp), &s));
  CHECK(s.has_v4); CHECK(s.has_v6); CHECK_EQ(s.v6_prefix_len, 64);
  CHECK_BYTES(s.v6_addr, 16, "20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08");
  CHECK_BYTES(s.v6_gateway, 16, "20 01 0d b8 8a f4 b2 60 a0 89 88 dc 13 7d 62 53");
  CHECK_EQ(s.v6_dns_count, 2); CHECK_BYTES(s.v6_dns[0], 16, "20 01 0d b8 20 00 00 00 02 70 00 00 00 00 00 01");
}
TEST(parse_packet_status) {
  rmnet::PacketStatus p{};
  CHECK(rmnet::parse_wds_packet_status(decode(kWdsConnected4Ind), &p));
  CHECK_EQ(p.status, 2); CHECK(!p.reconfigure); CHECK_EQ(p.family, 4);
  CHECK(rmnet::parse_wds_packet_status(decode(kWdsDisconnected6Ind), &p));
  CHECK_EQ(p.status, 1); CHECK_EQ(p.family, 6);
}
TEST(parsers_reject_short_values) {  // frames built in the test with a 2-byte TLV 0x1E, a 1-byte TLV 0x01
  rmnet::RuntimeSettings s{}; CHECK(!rmnet::parse_wds_current_settings(short_address_frame(), &s)); CHECK(!s.has_v4);
  rmnet::PacketStatus p{};    CHECK(!rmnet::parse_wds_packet_status(short_status_frame(), &p));
  uint32_t h; rmnet::CallEnd e{}; CHECK(!rmnet::parse_wds_start_network(decode(kWdsBind4Resp), &h, &e));  // success but no handle TLV
}
TEST(parse_settings_ipv4_needs_address_mask_and_gateway) {   // the capture's IPv4 reply without one TLV
  for (uint8_t missing : {0x1e, 0x20, 0x21}) {
    rmnet::RuntimeSettings s{};
    CHECK(rmnet::parse_wds_current_settings(decode_bytes(without_tlv(hex(kWdsSettings4Resp), missing)), &s));
    CHECK(!s.has_v4); CHECK_BYTES(s.v4_addr, 4, "00 00 00 00"); CHECK_EQ(s.mtu, 1500u);
  }
}

// In-band flow control: request TLV 0x1A, response TLV 0x1B (one byte each).

TEST(set_data_format_without_flow_control_is_the_recorded_request) {
  uint8_t b[128];
  size_t n = rmnet::build_wda_set_data_format(b, sizeof b, 1, 1, 4, false);
  CHECK_BYTES(b, n, kWdaSetFormatReq);
}
TEST(set_data_format_with_flow_control_adds_one_tlv) {   // 1a 01 00 01 after the endpoint TLV
  uint8_t b[128];
  size_t n = rmnet::build_wda_set_data_format(b, sizeof b, 1, 1, 4, true);
  CHECK_BYTES(b, n, kWdaSetFormatReqFlow);
}
TEST(data_format_reports_the_modems_flow_control) {
  rmnet::DataFormat f{};
  CHECK(rmnet::parse_wda_data_format(decode(kWdaSetFormatResp), &f));        // ends 1b 01 00 00
  CHECK_EQ(f.flow_control, 0);
  std::vector<uint8_t> on = hex(kWdaSetFormatResp); on.back() = 0x01;        // ends 1b 01 00 01
  f.flow_control = 7;
  CHECK(rmnet::parse_wda_data_format(decode_bytes(on), &f)); CHECK_EQ(f.flow_control, 1);
  f.flow_control = 7;
  CHECK(rmnet::parse_wda_data_format(decode_bytes(without_tlv(on, 0x1b)), &f)); CHECK_EQ(f.flow_control, 0);
  // Two bytes, 1b 02 00 01 00: the TLV that ends the frame grows by one, and both lengths with it.
  std::vector<uint8_t> two = on; two.push_back(0x00);
  two[two.size() - 4] = 0x02; two[1] += 1; two[11] += 1;
  CHECK(!rmnet::parse_wda_data_format(decode_bytes(two), &f));
  CHECK(rmnet::data_format_usable(f));                                        // f is the last good parse
}

// Pinned behaviour (the deferred list of 2026-11-13).

namespace {

const std::vector<uint8_t> kResultOk = {0x00, 0x00, 0x00, 0x00};

rmnet::QmiMessage settings_frame(const std::vector<RawTlv>& tlvs) {
  return wds_frame(rmnet::QmiKind::Response, rmnet::kWdsGetCurrentSettings, tlvs);
}

}  // namespace

TEST(settings_reply_with_a_short_ipv6_or_mtu_tlv_is_rejected) {
  // Each TLV at its layout's size parses; one byte shorter, the whole reply is rejected. IPv6
  // address and gateway: 16 address bytes, then the prefix length. IPv6 DNS: 16. MTU: u32le.
  const struct { uint8_t type; size_t len; } layouts[] = {{0x25, 17}, {0x26, 17}, {0x27, 16}, {0x28, 16}, {0x29, 4}};
  for (const auto& l : layouts) {
    rmnet::RuntimeSettings whole{}, cut{};
    CHECK(rmnet::parse_wds_current_settings(settings_frame({{0x02, kResultOk}, {l.type, std::vector<uint8_t>(l.len, 0x01)}}), &whole));
    CHECK(!rmnet::parse_wds_current_settings(settings_frame({{0x02, kResultOk}, {l.type, std::vector<uint8_t>(l.len - 1, 0x01)}}), &cut));
    CHECK(!cut.has_v6); CHECK_EQ(cut.v6_dns_count, 0); CHECK_EQ(cut.mtu, 0u);
  }
}
TEST(ipv6_settings_reply_leaves_the_ipv4_dns_servers_as_they_were) {
  rmnet::RuntimeSettings s{};
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings4Resp), &s));
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings6Resp), &s));   // no TLV 0x15 or 0x16
  CHECK_EQ(s.v4_dns_count, 2);
  CHECK_BYTES(s.v4_dns[0], 4, "cb 00 71 c1"); CHECK_BYTES(s.v4_dns[1], 4, "cb 00 71 d1");
}
TEST(failed_settings_parse_leaves_every_field_unchanged) {
  // A reply with every TLV the parser takes, each well formed and different from what *out holds,
  // then a 3-byte MTU: it fails after everything else was read. *out starts as a byte pattern
  // (padding included) with neither family, and must come back byte for byte.
  std::vector<RawTlv> tlvs = {
      {0x02, kResultOk},
      {0x1e, {0xe6, 0xf6, 0x66, 0x0a}}, {0x20, {0xe5, 0xf6, 0x66, 0x0a}}, {0x21, {0xfc, 0xff, 0xff, 0xff}},
      {0x15, {0xc1, 0x71, 0x00, 0xcb}}, {0x16, {0xd1, 0x71, 0x00, 0xcb}},
      {0x25, std::vector<uint8_t>(17, 0x24)}, {0x26, std::vector<uint8_t>(17, 0x26)},
      {0x27, std::vector<uint8_t>(16, 0x27)}, {0x28, std::vector<uint8_t>(16, 0x28)},
      {0x29, {0xdc, 0x05, 0x00}}};
  rmnet::RuntimeSettings s;
  memset(&s, 0x5a, sizeof s); s.has_v4 = false; s.has_v6 = false;
  uint8_t before[sizeof s]; memcpy(before, &s, sizeof s);
  CHECK(!rmnet::parse_wds_current_settings(settings_frame(tlvs), &s));
  CHECK(memcmp(&s, before, sizeof s) == 0);
  // The same TLVs with a whole MTU but a failed result: unchanged too.
  std::vector<RawTlv> failed = tlvs;
  failed.front().value = {0x01, 0x00, 0x0e, 0x00}; failed.back().value = {0xdc, 0x05, 0x00, 0x00};
  CHECK(!rmnet::parse_wds_current_settings(settings_frame(failed), &s));
  CHECK(memcmp(&s, before, sizeof s) == 0);
  // With a whole MTU and a good result the reply parses and changes them all.
  tlvs.back().value = {0xdc, 0x05, 0x00, 0x00};
  CHECK(rmnet::parse_wds_current_settings(settings_frame(tlvs), &s));
  CHECK(s.has_v4); CHECK(s.has_v6); CHECK_EQ(s.v4_dns_count, 2); CHECK_EQ(s.v6_dns_count, 2); CHECK_EQ(s.mtu, 1500u);
  CHECK_BYTES(s.v4_addr, 4, "0a 66 f6 e6"); CHECK_BYTES(s.v4_dns[1], 4, "cb 00 71 d1"); CHECK_EQ(s.v6_prefix_len, 0x24);
}

// One DNS server: the unused second slot is zero, not whatever the parser's stack held. A reply with
// two servers is parsed just before, so its second server sits where the parser's local array is
// (each call's frame starts at the same place) and a copy of an unset slot would show it.
TEST(settings_reply_with_one_ipv4_dns_server_leaves_the_second_slot_zero) {
  rmnet::QmiMessage two = decode(kWdsSettings4Resp);  // TLVs 0x15 and 0x16
  rmnet::QmiMessage one = settings_frame({{0x02, kResultOk}, {0x15, {0xc1, 0x71, 0x00, 0xcb}}});
  rmnet::RuntimeSettings scratch{}, s;
  memset(&s, 0xee, sizeof s); s.has_v4 = false; s.has_v6 = false;
  CHECK(rmnet::parse_wds_current_settings(two, &scratch));
  CHECK(rmnet::parse_wds_current_settings(one, &s));
  CHECK_EQ(s.v4_dns_count, 1);
  CHECK_BYTES(s.v4_dns[0], 4, "cb 00 71 c1");
  CHECK_BYTES(s.v4_dns[1], 4, "00 00 00 00");
}
TEST(settings_reply_with_one_ipv6_dns_server_leaves_the_second_slot_zero) {
  rmnet::QmiMessage two = decode(kWdsSettings6Resp);  // TLVs 0x27 and 0x28
  rmnet::QmiMessage one = settings_frame({{0x02, kResultOk}, {0x27, std::vector<uint8_t>(16, 0x27)}});
  rmnet::RuntimeSettings scratch{}, s;
  memset(&s, 0xee, sizeof s); s.has_v4 = false; s.has_v6 = false;
  CHECK(rmnet::parse_wds_current_settings(two, &scratch));
  CHECK(rmnet::parse_wds_current_settings(one, &s));
  CHECK_EQ(s.v6_dns_count, 1);
  CHECK_BYTES(s.v6_dns[0], 16, "27 27 27 27 27 27 27 27 27 27 27 27 27 27 27 27");
  CHECK_BYTES(s.v6_dns[1], 16, "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00");
}
