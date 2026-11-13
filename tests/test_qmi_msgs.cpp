#include "minitest.h"

#include <list>

#include "captures.h"
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
  n = rmnet::build_wda_set_data_format(b, sizeof b, 1, 1, 4);                  CHECK_BYTES(b, n, kWdaSetFormatReq);
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
