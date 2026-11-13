#include "minitest.h"

#include "captures.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "rmnet/session.h"

namespace {

// Records what the session sends and reports.
struct FakeModem : rmnet::SessionDelegate {
  std::vector<std::vector<uint8_t>> sent;
  int ups = 0;
  int downs = 0;
  rmnet::LinkConfig cfg = {};

  void send_qmi(const uint8_t* data, size_t len) override { sent.emplace_back(data, data + len); }
  void link_up(const rmnet::LinkConfig& c) override {
    ++ups;
    cfg = c;
  }
  void link_down() override { ++downs; }

  const std::vector<uint8_t>& last() const {
    static const std::vector<uint8_t> none;
    return sent.empty() ? none : sent.back();
  }
  // Transaction ID of the last sent frame: 8 bits for CTL (service byte 4 is 0), else 16 bits.
  uint16_t last_txid() const {
    const std::vector<uint8_t>& f = last();
    if (f.size() < 9) return 0;
    if (f[4] == 0) return f[7];
    return static_cast<uint16_t>(f[7] | f[8] << 8);
  }
};

void feed_frame(rmnet::Session& s, const std::vector<uint8_t>& f, uint64_t now) {
  s.on_qmi(f.data(), f.size(), now);
}

void feed(rmnet::Session& s, const char* hex_text, uint64_t now) { feed_frame(s, hex(hex_text), now); }

// A captured non-CTL frame with its 16-bit transaction ID replaced.
std::vector<uint8_t> with_txid(const char* hex_text, uint16_t txid) {
  std::vector<uint8_t> f = hex(hex_text);
  f[7] = static_cast<uint8_t>(txid);
  f[8] = static_cast<uint8_t>(txid >> 8);
  return f;
}

// The capture's responses, in the order bring-up asks for them.
const char* const kBringUpResponses[] = {
    kCtlSyncResp,    kCtlGetWdaResp,   kWdaSetFormatResp, kCtlGetWds4Resp,  kWdsBind4Resp,
    kWdsFamily4Resp, kWdsStart4Resp,   kWdsSettings4Resp, kCtlGetWds6Resp,  kWdsBind6Resp,
    kWdsFamily6Resp, kWdsStart6Resp,   kWdsSettings6Resp};

// Starts at time 0 and replays responses at time 100 up to and including `last_response`.
void bring_up_to(rmnet::Session& s, FakeModem& m, const char* last_response) {
  (void)m;
  s.start(0);
  for (const char* r : kBringUpResponses) {
    feed(s, r, 100);
    if (r == last_response) return;
  }
}

void bring_up_fully(rmnet::Session& s, FakeModem& m) { bring_up_to(s, m, kWdsSettings6Resp); }

// A Start Network response on WDS `client` with transaction `txid` that failed with `error`.
std::vector<uint8_t> start_error_frame(uint8_t client, uint16_t txid, uint16_t error) {
  std::vector<uint8_t> buf(64);
  rmnet::QmiBuilder b(buf.data(), buf.size(),
                      {rmnet::QmiService::WDS, client, rmnet::QmiKind::Response, txid,
                       rmnet::kWdsStartNetwork});
  const uint8_t result[4] = {0x01, 0x00, static_cast<uint8_t>(error), static_cast<uint8_t>(error >> 8)};
  b.tlv(0x02, result, sizeof result);
  buf.resize(b.finish());
  buf[3] = 0x80;  // from the modem
  return buf;
}

std::vector<uint8_t> failed_start_frame(uint8_t client, uint16_t txid) {
  return start_error_frame(client, txid, rmnet::kQmiErrCallFailed);
}

std::vector<uint8_t> no_effect_start_frame(uint8_t client, uint16_t txid) {
  return start_error_frame(client, txid, rmnet::kQmiErrNoEffect);
}

// Answers the IPv6 client, bind and family requests from the capture, then fails the start.
void fail_v6_too(rmnet::Session& s, FakeModem& m, uint64_t now) {
  feed(s, kCtlGetWds6Resp, now);
  feed_frame(s, with_txid(kWdsBind6Resp, m.last_txid()), now);
  feed_frame(s, with_txid(kWdsFamily6Resp, m.last_txid()), now);
  feed_frame(s, failed_start_frame(16, m.last_txid()), now);
}

std::vector<uint8_t> settings4_response_with_txid(uint16_t txid) {
  return with_txid(kWdsSettings4Resp, txid);
}

}  // namespace

TEST(happy_path_brings_link_up_dual_stack) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  const char* script[][2] = {
    {kCtlSyncReq, kCtlSyncResp}, {kCtlGetWdaReq, kCtlGetWdaResp}, {kWdaSetFormatReq, kWdaSetFormatResp},
    {kCtlGetWds4Req, kCtlGetWds4Resp}, {kWdsBind4Req, kWdsBind4Resp}, {kWdsFamily4Req, kWdsFamily4Resp},
    {kWdsStart4Req, kWdsStart4Resp}, {kWdsSettings4Req, kWdsSettings4Resp},
    {kCtlGetWds6Req, kCtlGetWds6Resp}, {kWdsBind6Req, kWdsBind6Resp}, {kWdsFamily6Req, kWdsFamily6Resp},
    {kWdsStart6Req, kWdsStart6Resp}, {kWdsSettings6Req, kWdsSettings6Resp}};
  for (auto& step : script) { CHECK_BYTES(m.last(), step[0]); feed(s, step[1], 100); }
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1); CHECK_EQ(m.downs, 0);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 e6"); CHECK_EQ(m.cfg.settings.mtu, 1500u);
  CHECK_EQ(m.cfg.format.dl_max_size, 31744u);
}

TEST(connected_indication_during_bring_up_is_harmless) {   // the capture has one between start and settings
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsStart4Resp);
  size_t sent = m.sent.size(); feed(s, kWdsConnected4Ind, 100);
  CHECK_EQ(m.sent.size(), sent); CHECK_EQ(m.downs, 0);
}

TEST(sync_is_resent_until_answered_then_gives_up) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  s.tick(1999); CHECK_EQ(m.sent.size(), 1u);
  s.tick(2000); CHECK_EQ(m.sent.size(), 2u); CHECK_EQ(m.sent[1][7], 2);      // CTL transaction ID 2
  for (uint64_t t = 4000; t <= 60000; t += 2000) s.tick(t);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.ups, 0);
}

TEST(ignores_response_with_wrong_txid) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  auto stale = hex(kCtlSyncResp); stale[7] = 9;
  s.on_qmi(stale.data(), stale.size(), 10);
  CHECK(s.state() == rmnet::SessionState::Syncing); CHECK_EQ(m.sent.size(), 1u);
}

TEST(v6_failure_still_links_up_v4_only) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily6Resp);
  feed_frame(s, failed_start_frame(16, 8), 100);                              // client 16, transaction 8, CallFailed
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK(m.cfg.settings.has_v4); CHECK(!m.cfg.settings.has_v6);
}

TEST(start_network_no_effect_is_adopted) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily4Resp);
  feed_frame(s, no_effect_start_frame(15, 4), 100);
  CHECK_BYTES(m.last(), kWdsSettings4Req);
}

TEST(both_families_fail_backs_off_and_redials) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily4Resp);
  feed_frame(s, failed_start_frame(15, 4), 100);
  /* IPv6 attempt: answer client, bind, family from the capture, then fail the start */
  fail_v6_too(s, m, 100);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.ups, 0);
  size_t sent = m.sent.size(); s.tick(2099); CHECK_EQ(m.sent.size(), sent);
  s.tick(2100); CHECK(s.state() == rmnet::SessionState::Syncing);
  CHECK_EQ(m.last()[8], 0x27);                                               // a sync request went out
}

TEST(unusable_data_format_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWdaResp);
  auto f = hex(kWdaSetFormatResp); f[27] = 0x01;                              // link layer 1 instead of 2
  s.on_qmi(f.data(), f.size(), 100);
  CHECK(s.state() == rmnet::SessionState::Backoff);
}

TEST(request_timeout_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWdaResp);    // set data format now outstanding at t=100
  s.tick(10099); CHECK(s.state() == rmnet::SessionState::Configuring);
  s.tick(10100); CHECK(s.state() == rmnet::SessionState::Backoff);
}

TEST(disconnect_indication_takes_link_down_and_redials) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  feed(s, kWdsDisconnected4Ind, 5000);
  CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Backoff);
  feed(s, kWdsDisconnected6Ind, 5001); CHECK_EQ(m.downs, 1);
}

TEST(reconfigure_indication_refreshes_settings) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  auto ind = hex(kWdsConnected4Ind); ind[17] = 0x01;                          // reconfigure flag
  s.on_qmi(ind.data(), ind.size(), 5000);
  CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Refreshing);
  CHECK_EQ(m.last()[9], 0x2d);                                               // get current settings on client 15
  feed_frame(s, settings4_response_with_txid(m.last_txid()), 5010);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2);
}

TEST(stop_from_link_down_during_reconfigure_stays_idle) {   // a delegate that breaks the no-re-entry rule
  struct Stopper : FakeModem {
    rmnet::Session* session = nullptr;
    void link_down() override { FakeModem::link_down(); session->stop(); }
  };
  Stopper m; rmnet::Session s({}, m); m.session = &s; bring_up_fully(s, m);
  size_t before = m.sent.size();
  auto ind = hex(kWdsConnected4Ind); ind[17] = 0x01;                          // reconfigure flag
  s.on_qmi(ind.data(), ind.size(), 5000);
  CHECK(s.state() == rmnet::SessionState::Idle); CHECK_EQ(m.downs, 1);
  CHECK_EQ(m.sent.size(), before + 5);                                         // the teardown frames only
  CHECK_BYTES(m.last(), kCtlReleaseWdaReq);
  // Teardown used transactions 10 and 11, so a settings request would have used 12.
  for (uint8_t client : {0, 15}) {
    auto reply = settings4_response_with_txid(12); reply[5] = client;
    feed_frame(s, reply, 5010);
  }
  s.tick(20000);
  CHECK(s.state() == rmnet::SessionState::Idle); CHECK_EQ(m.sent.size(), before + 5); CHECK_EQ(m.ups, 1);
}

TEST(stop_tears_down_in_capture_order) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m); size_t before = m.sent.size();
  s.stop();
  CHECK_EQ(m.sent.size(), before + 5); CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Idle);
  CHECK_BYTES(m.sent[before + 0], kWdsStop6Req);    CHECK_BYTES(m.sent[before + 1], kCtlRelease6Req);
  CHECK_BYTES(m.sent[before + 2], kWdsStop4Req);    CHECK_BYTES(m.sent[before + 3], kCtlRelease4Req);
  CHECK_BYTES(m.sent[before + 4], kCtlReleaseWdaReq);
}

TEST(v4_drop_during_v6_bring_up_then_v6_failure_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily6Resp);  // IPv6 start outstanding
  feed(s, kWdsDisconnected4Ind, 100);
  feed_frame(s, failed_start_frame(16, 8), 100);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.ups, 0);
}

TEST(v4_drop_during_v6_bring_up_links_up_v6_only) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily6Resp);
  feed(s, kWdsDisconnected4Ind, 100);
  feed(s, kWdsStart6Resp, 100); feed(s, kWdsSettings6Resp, 100);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK(m.cfg.settings.has_v6); CHECK(!m.cfg.settings.has_v4);
}

TEST(disconnect_from_failed_family_leaves_link_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily6Resp);
  feed_frame(s, failed_start_frame(16, 8), 100);                              // IPv4-only link
  feed(s, kWdsDisconnected6Ind, 5000);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
  feed(s, kWdsDisconnected4Ind, 5001);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);
}
