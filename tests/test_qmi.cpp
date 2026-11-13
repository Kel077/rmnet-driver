#include "minitest.h"

#include "captures.h"
#include "rmnet/qmi.h"

TEST(decode_ctl_sync_response) {
  auto f = hex(kCtlSyncResp); rmnet::QmiMessage m;
  CHECK(rmnet::qmi_decode({f.data(), f.size()}, &m));
  CHECK(m.hdr.service == rmnet::QmiService::CTL); CHECK_EQ(m.hdr.client, 0);
  CHECK(m.hdr.kind == rmnet::QmiKind::Response); CHECK_EQ(m.hdr.txid, 1); CHECK_EQ(m.hdr.msg_id, 0x0027);
  CHECK_EQ(m.tlvs.len, 7u);
  auto r = rmnet::qmi_result(m); CHECK(r.present); CHECK(r.ok); CHECK_EQ(r.error, 0);
}
TEST(decode_wds_indication) {
  auto f = hex(kWdsConnected4Ind); rmnet::QmiMessage m;
  CHECK(rmnet::qmi_decode({f.data(), f.size()}, &m));
  CHECK(m.hdr.service == rmnet::QmiService::WDS); CHECK_EQ(m.hdr.client, 15);
  CHECK(m.hdr.kind == rmnet::QmiKind::Indication); CHECK_EQ(m.hdr.txid, 1); CHECK_EQ(m.hdr.msg_id, 0x0022);
  rmnet::Span v; CHECK(rmnet::qmi_find_tlv(m.tlvs, 0x12, &v)); CHECK_EQ(v.len, 1u); CHECK_EQ(v.data[0], 4);
  CHECK(!rmnet::qmi_find_tlv(m.tlvs, 0x99, &v));
  CHECK(!rmnet::qmi_result(m).present);
}
TEST(decode_rejects_truncated) {
  auto f = hex(kCtlSyncResp); rmnet::QmiMessage m;
  CHECK(!rmnet::qmi_decode({f.data(), f.size() - 1}, &m));           // shorter than its length field
  auto g = f; g[0] = 0x02; CHECK(!rmnet::qmi_decode({g.data(), g.size()}, &m));   // wrong marker
  auto h = f; h[13] = 0x09; CHECK(!rmnet::qmi_decode({h.data(), h.size()}, &m));  // TLV length 9 overruns
  CHECK(!rmnet::qmi_decode({f.data(), 3}, &m));
}
TEST(frame_length_splits_a_read) {
  auto a = hex(kCtlSyncResp), b = hex(kWdsConnected4Ind);
  std::vector<uint8_t> both(a); both.insert(both.end(), b.begin(), b.end());
  CHECK_EQ(rmnet::qmi_frame_length({both.data(), both.size()}), a.size());
  CHECK_EQ(rmnet::qmi_frame_length({both.data() + a.size(), both.size() - a.size()}), b.size());
  CHECK_EQ(rmnet::qmi_frame_length({a.data(), a.size() - 1}), 0u);
  CHECK_EQ(rmnet::qmi_frame_length({a.data(), 2}), 0u);
  auto bad = a; bad[0] = 0x02; CHECK_EQ(rmnet::qmi_frame_length({bad.data(), bad.size()}), 0u);
}
TEST(build_matches_capture_ctl) {
  uint8_t buf[64]; uint8_t svc = 0x1a;
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::CTL, 0, rmnet::QmiKind::Request, 2, 0x0022});
  b.tlv(0x01, &svc, 1);
  size_t n = b.finish(); CHECK_BYTES(buf, n, kCtlGetWdaReq);
}
TEST(build_matches_capture_service) {
  uint8_t buf[64];
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::WDS, 15, rmnet::QmiKind::Request, 3, 0x004D});
  b.tlv_u8(0x01, 4);
  size_t n = b.finish(); CHECK_BYTES(buf, n, kWdsFamily4Req);
}
TEST(builder_overflow_returns_zero) {
  uint8_t buf[10];
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::WDS, 1, rmnet::QmiKind::Request, 1, 0x0020});
  b.tlv_u32(0x10, 1); CHECK_EQ(b.finish(), 0u);
}
TEST(result_reports_error) {
  uint8_t buf[64]; const uint8_t res[4] = {0x01, 0x00, 0x1a, 0x00};
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::WDS, 15, rmnet::QmiKind::Response, 4, 0x0020});
  b.tlv(0x02, res, 4); size_t n = b.finish();
  rmnet::QmiMessage m; CHECK(rmnet::qmi_decode({buf, n}, &m));
  auto r = rmnet::qmi_result(m); CHECK(r.present); CHECK(!r.ok); CHECK_EQ(r.error, 0x001a);
}
