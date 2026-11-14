#include "minitest.h"

#include <algorithm>

#include "captures.h"
#include "frames.h"
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

// A WDS `msg_id` response on `client` with transaction `txid` that failed with `error`.
std::vector<uint8_t> wds_error_frame(uint16_t msg_id, uint8_t client, uint16_t txid, uint16_t error) {
  std::vector<uint8_t> buf(64);
  rmnet::QmiBuilder b(buf.data(), buf.size(),
                      {rmnet::QmiService::WDS, client, rmnet::QmiKind::Response, txid, msg_id});
  const uint8_t result[4] = {0x01, 0x00, static_cast<uint8_t>(error), static_cast<uint8_t>(error >> 8)};
  b.tlv(0x02, result, sizeof result);
  buf.resize(b.finish());
  buf[3] = 0x80;  // from the modem
  return buf;
}

// A Start Network response on WDS `client` with transaction `txid` that failed with `error`.
std::vector<uint8_t> start_error_frame(uint8_t client, uint16_t txid, uint16_t error) {
  return wds_error_frame(rmnet::kWdsStartNetwork, client, txid, error);
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

std::vector<uint8_t> start6_response_with_txid(uint16_t txid) { return with_txid(kWdsStart6Resp, txid); }

std::vector<uint8_t> settings6_response_with_txid(uint16_t txid) {
  return with_txid(kWdsSettings6Resp, txid);
}

// Replays the capture so IPv4 comes up, then fails the IPv6 Start Network at `time`.
void bring_up_v4_only(rmnet::Session& s, FakeModem& m, uint64_t time) {
  bring_up_to(s, m, kWdsFamily6Resp);
  feed_frame(s, failed_start_frame(16, m.last_txid()), time);
}

std::vector<uint8_t> start4_response_with_txid(uint16_t txid) { return with_txid(kWdsStart4Resp, txid); }

// Replays the capture up to the IPv4 Start Network, fails it at `time` (as after a teardown, when the
// network refuses IPv4 for a moment), then answers the IPv6 steps so the link comes up IPv6-only.
void bring_up_v6_only(rmnet::Session& s, FakeModem& m, uint64_t time) {
  bring_up_to(s, m, kWdsFamily4Resp);
  feed_frame(s, failed_start_frame(15, m.last_txid()), time);
  feed(s, kCtlGetWds6Resp, time);
  feed_frame(s, with_txid(kWdsBind6Resp, m.last_txid()), time);
  feed_frame(s, with_txid(kWdsFamily6Resp, m.last_txid()), time);
  feed_frame(s, start6_response_with_txid(m.last_txid()), time);
  feed_frame(s, settings6_response_with_txid(m.last_txid()), time);
}

// Ticks at `now`; if that sent a liveness probe, answers it at once with the capture's settings
// reply for the probed client. For tests that span minutes with the link up.
void tick_answering_probe(rmnet::Session& s, FakeModem& m, uint64_t now) {
  size_t sent = m.sent.size();
  s.tick(now);
  if (m.sent.size() != sent + 1 || m.last()[9] != 0x2d) return;
  const char* reply = m.last()[5] == 15 ? kWdsSettings4Resp : kWdsSettings6Resp;
  feed_frame(s, with_txid(reply, m.last_txid()), now);
}

// The capture's packet-service-status indication with its reconfigure flag set.
std::vector<uint8_t> reconfigure_indication(const char* connected_ind) {
  std::vector<uint8_t> ind = hex(connected_ind);
  ind[17] = 0x01;
  return ind;
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
  auto reply = settings4_response_with_txid(m.last_txid());
  const uint8_t old_addr[7] = {0x1e, 0x04, 0x00, 0xe6, 0xf6, 0x66, 0x0a};    // TLV 0x1E: 10.102.246.230, u32le
  auto at = std::search(reply.begin(), reply.end(), old_addr, old_addr + 7);
  CHECK(at != reply.end()); at[3] = 0xea;                                     // now 10.102.246.234
  feed_frame(s, reply, 5010);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2);
  CHECK(m.cfg.settings.has_v4); CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 ea");
  CHECK(m.cfg.settings.has_v6); CHECK_EQ(m.cfg.settings.v6_prefix_len, 64);   // IPv6 untouched by the IPv4 refresh
  CHECK_BYTES(m.cfg.settings.v6_addr, 16, "20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08");
  CHECK_EQ(m.cfg.settings.v6_dns_count, 2);
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

TEST(missing_family_is_retried_while_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);          // helper: IPv6 Start Network fails at time 100
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  size_t sent = m.sent.size();
  s.tick(5099); CHECK_EQ(m.sent.size(), sent);
  s.tick(5100); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);                     // Start Network on the IPv6 client
  feed_frame(s, start6_response_with_txid(m.last_txid()), 5200);
  CHECK_EQ(m.last()[9], 0x2d);                                                // Get Current Settings
  feed_frame(s, settings6_response_with_txid(m.last_txid()), 5300);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 0);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  sent = m.sent.size(); s.tick(200000); CHECK_EQ(m.sent.size(), sent + 1);    // nothing left to retry: only the
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);                     // liveness probe, on the IPv4 client
}

TEST(failed_retry_keeps_link_up_and_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);
  const uint64_t at[] = {5100, 15200, 35300, 75400, 135500, 195600};          // waits of 5, 10, 20, 40, 60, 60 s after each failure
  for (uint64_t t : at) {
    tick_answering_probe(s, m, t - 500);                                      // keeps the liveness probe answered
    size_t sent = m.sent.size();
    s.tick(t - 1); CHECK_EQ(m.sent.size(), sent);
    s.tick(t);     CHECK_EQ(m.sent.size(), sent + 1);
    CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);                   // Start Network on the IPv6 client
    feed_frame(s, failed_start_frame(16, m.last_txid()), t + 100);
    CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0); CHECK_EQ(m.ups, 1);
  }
}

TEST(retry_timeout_keeps_link_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);
  s.tick(5100); size_t sent = m.sent.size();
  s.tick(65099); CHECK(s.state() == rmnet::SessionState::Up);
  s.tick(65100); CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);   // Start Network timed out
  CHECK_EQ(m.sent.size(), sent);
  s.tick(75100); CHECK_EQ(m.sent.size(), sent + 1);                           // next retry 10 s after the timeout
}

TEST(live_family_drop_during_retry_goes_to_backoff) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);
  s.tick(5100);
  feed(s, kWdsDisconnected4Ind, 5200);
  CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Backoff);
}

TEST(retried_call_dropping_before_settings_fails_the_retry) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);
  s.tick(5100);
  feed_frame(s, start6_response_with_txid(m.last_txid()), 5200);
  CHECK_EQ(m.last()[9], 0x2d);                                                // Get Current Settings outstanding
  uint16_t settings_txid = m.last_txid();
  feed(s, kWdsDisconnected6Ind, 5250);                                         // the retried IPv6 call drops
  feed_frame(s, settings6_response_with_txid(settings_txid), 5300);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1); CHECK_EQ(m.downs, 0);
  CHECK(!m.cfg.settings.has_v6);
  size_t sent = m.sent.size();
  s.tick(15299); CHECK_EQ(m.sent.size(), sent);
  s.tick(15300); CHECK_EQ(m.sent.size(), sent + 1);                           // next retry 10 s after the failure
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);
}

TEST(retry_binds_a_client_whose_bind_failed) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWds6Resp);  // IPv6 Bind Mux outstanding
  feed_frame(s, wds_error_frame(rmnet::kWdsBindMuxDataPort, 16, m.last_txid(), rmnet::kQmiErrCallFailed), 100);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  s.tick(5100);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0xa2); CHECK_EQ(m.last()[10], 0x00);   // Bind Mux on client 16
  feed_frame(s, with_txid(kWdsBind6Resp, m.last_txid()), 5200);
  CHECK_EQ(m.last()[9], 0x4d);                                                // Set IP Family
  feed_frame(s, with_txid(kWdsFamily6Resp, m.last_txid()), 5300);
  CHECK_EQ(m.last()[9], 0x20);                                                // Start Network
}

TEST(missing_v4_is_retried_while_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v6_only(s, m, 100);          // helper: IPv4 Start Network fails at time 100
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK(m.cfg.settings.has_v6); CHECK(!m.cfg.settings.has_v4);
  size_t sent = m.sent.size();
  s.tick(5099); CHECK_EQ(m.sent.size(), sent);
  s.tick(5100); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x20);                     // Start Network on the IPv4 client
  feed_frame(s, start4_response_with_txid(m.last_txid()), 5200);
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);                     // Get Current Settings
  feed_frame(s, settings4_response_with_txid(m.last_txid()), 5300);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 0);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 e6");
  sent = m.sent.size(); s.tick(200000); CHECK_EQ(m.sent.size(), sent + 1);    // nothing left to retry: only the
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);                     // liveness probe, on the IPv4 client
}

TEST(failed_v4_retry_keeps_link_up_and_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v6_only(s, m, 100);
  const uint64_t at[] = {5100, 15200, 35300, 75400, 135500, 195600};          // waits of 5, 10, 20, 40, 60, 60 s after each failure
  for (uint64_t t : at) {
    tick_answering_probe(s, m, t - 500);                                      // keeps the liveness probe answered
    size_t sent = m.sent.size();
    s.tick(t - 1); CHECK_EQ(m.sent.size(), sent);
    s.tick(t);     CHECK_EQ(m.sent.size(), sent + 1);
    CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x20);                   // Start Network on the IPv4 client
    feed_frame(s, failed_start_frame(15, m.last_txid()), t + 100);
    CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0); CHECK_EQ(m.ups, 1);
    CHECK(m.cfg.settings.has_v6); CHECK(!m.cfg.settings.has_v4);
  }
}

// Liveness probe while Up. bring_up_fully() brings the link up at time 100.

TEST(probe_is_sent_30_s_after_link_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  size_t sent = m.sent.size();
  s.tick(30099); CHECK_EQ(m.sent.size(), sent);
  s.tick(30100); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[4], 0x01); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);   // Get Current Settings, IPv4 client
  s.tick(30200); CHECK_EQ(m.sent.size(), sent + 1);                           // one probe at a time
}

TEST(answered_probe_schedules_the_next_one) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  s.tick(30100);
  auto reply = settings4_response_with_txid(m.last_txid());
  const uint8_t old_addr[7] = {0x1e, 0x04, 0x00, 0xe6, 0xf6, 0x66, 0x0a};    // TLV 0x1E: 10.102.246.230
  auto at = std::search(reply.begin(), reply.end(), old_addr, old_addr + 7);
  CHECK(at != reply.end()); at[3] = 0xea;                                     // contents are ignored
  feed_frame(s, reply, 30200);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1); CHECK_EQ(m.downs, 0);
  CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 e6");
  size_t sent = m.sent.size();
  s.tick(40200); CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
  s.tick(60199); CHECK_EQ(m.sent.size(), sent);
  s.tick(60200); CHECK_EQ(m.sent.size(), sent + 1); CHECK_EQ(m.last()[9], 0x2d);   // 30 s after the answer
}

TEST(probe_with_error_result_counts_as_alive) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  s.tick(30100);
  feed_frame(s, wds_error_frame(rmnet::kWdsGetCurrentSettings, 15, m.last_txid(), rmnet::kQmiErrCallFailed), 30200);
  size_t sent = m.sent.size();
  s.tick(40100); s.tick(60199);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0); CHECK_EQ(m.sent.size(), sent);
  s.tick(60200); CHECK_EQ(m.sent.size(), sent + 1); CHECK_EQ(m.last()[9], 0x2d);
}

TEST(unanswered_probe_takes_the_link_down_and_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  s.tick(30100);
  s.tick(40099); CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
  s.tick(40100); CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);
  s.tick(40200); CHECK_EQ(m.downs, 1);
}

TEST(probe_waits_for_an_outstanding_retry) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);          // link up at 100, IPv6 missing
  s.tick(5100); CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);       // retry: Start Network, 60 s timeout
  size_t sent = m.sent.size();
  s.tick(30100); s.tick(39999); CHECK_EQ(m.sent.size(), sent);                // no probe while the retry is outstanding
  feed_frame(s, failed_start_frame(16, m.last_txid()), 40000);                // next retry due at 50000
  s.tick(40000); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);                     // the probe, on the live IPv4 client
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
}

TEST(retry_waits_for_an_outstanding_probe) {
  FakeModem m; rmnet::Session s({}, m); bring_up_v4_only(s, m, 100);
  s.tick(5100);  feed_frame(s, failed_start_frame(16, m.last_txid()), 5200);   // next retry at 15200
  s.tick(15200); feed_frame(s, failed_start_frame(16, m.last_txid()), 15300);  // next retry at 35300
  s.tick(30100); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);      // the probe
  uint16_t probe = m.last_txid(); size_t sent = m.sent.size();
  s.tick(35300); s.tick(35900); CHECK_EQ(m.sent.size(), sent);                // the due retry waits
  feed_frame(s, settings4_response_with_txid(probe), 36000);
  CHECK_EQ(m.ups, 1);                                                         // an answered probe changes nothing
  s.tick(36000); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);                     // now the retry
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
}

TEST(disconnect_indication_during_a_probe_abandons_it) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  size_t before = m.sent.size();
  s.tick(30100); CHECK_EQ(m.sent.size(), before + 1); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);
  uint16_t probe = m.last_txid();
  feed(s, kWdsDisconnected4Ind, 31000);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);
  size_t sent = m.sent.size();
  feed_frame(s, settings4_response_with_txid(probe), 31100);                  // the late answer
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.sent.size(), sent); CHECK_EQ(m.ups, 1);
  s.tick(40100); CHECK_EQ(m.downs, 1);
}

TEST(reconfigure_indication_during_a_probe_abandons_it) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  size_t before = m.sent.size();
  s.tick(30100); CHECK_EQ(m.sent.size(), before + 1); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);
  uint16_t probe = m.last_txid();
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 31000);
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.downs, 1);
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);
  uint16_t refresh = m.last_txid(); CHECK(refresh != probe);
  feed_frame(s, settings4_response_with_txid(probe), 31100);                  // the late probe answer is not the refresh's
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.ups, 1);
  s.tick(40099); CHECK(s.state() == rmnet::SessionState::Refreshing);         // the probe's timeout no longer applies
  feed_frame(s, settings4_response_with_txid(refresh), 40099);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 1);
  size_t sent = m.sent.size();
  s.tick(70098); CHECK_EQ(m.sent.size(), sent);                               // the interval restarts at the new link up
  s.tick(70099); CHECK_EQ(m.sent.size(), sent + 1); CHECK_EQ(m.last()[9], 0x2d);
}

TEST(reconfigure_for_the_other_family_during_a_refresh_is_not_lost) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 5000);
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.last()[5], 15);
  size_t sent = m.sent.size(); uint16_t v4 = m.last_txid();
  feed_frame(s, reconfigure_indication(kWdsConnected6Ind), 5005);
  CHECK_EQ(m.sent.size(), sent);                                              // remembered, not sent yet
  feed_frame(s, settings4_response_with_txid(v4), 5010);
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.ups, 1);
  CHECK_EQ(m.sent.size(), sent + 1); CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x2d);   // IPv6 refreshed next
  auto reply = settings6_response_with_txid(m.last_txid());
  reply[51] = 0x09;                                                           // last byte of the IPv6 address: 08 -> 09
  feed_frame(s, reply, 5020);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 1);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  CHECK_BYTES(m.cfg.settings.v6_addr, 16, "20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 09");
}

TEST(ipv4_without_gateway_or_mask_is_not_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsStart4Resp);   // IPv4 Get Current Settings outstanding
  feed_frame(s, without_tlv(settings4_response_with_txid(m.last_txid()), 0x20), 100);   // no gateway
  CHECK_EQ(m.last()[8], 0x22);                                                // bring-up moves on to IPv6 (CTL Get Client ID)
  feed(s, kCtlGetWds6Resp, 100);
  feed_frame(s, with_txid(kWdsBind6Resp, m.last_txid()), 100);
  feed_frame(s, with_txid(kWdsFamily6Resp, m.last_txid()), 100);
  feed_frame(s, start6_response_with_txid(m.last_txid()), 100);
  feed_frame(s, settings6_response_with_txid(m.last_txid()), 100);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK(!m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  s.tick(5100); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x20);       // IPv4 is retried
  feed_frame(s, start4_response_with_txid(m.last_txid()), 5200);
  feed_frame(s, without_tlv(settings4_response_with_txid(m.last_txid()), 0x21), 5300);  // no mask
  CHECK_EQ(m.ups, 1); CHECK(!m.cfg.settings.has_v4);
  s.tick(15300); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x20);      // retried again
  feed_frame(s, start4_response_with_txid(m.last_txid()), 15400);
  feed_frame(s, settings4_response_with_txid(m.last_txid()), 15500);          // complete
  CHECK_EQ(m.ups, 2); CHECK(m.cfg.settings.has_v4);
  CHECK_BYTES(m.cfg.settings.v4_gateway, 4, "0a 66 f6 e5"); CHECK_BYTES(m.cfg.settings.v4_mask, 4, "ff ff ff fc");
}

namespace {

// The link comes up IPv4-only at 100, then the host ticks every 100 ms up to 60100, as the driver
// does. Each probe is answered at once, each retry's Start Network fails at once, except the third
// retry (sent at 35100), whose failure arrives at `third_fail` (35200..60100). Afterwards the next
// probe is due at 90100 (the last answered at 60100) and the next retry 40 s after `third_fail`.
void up_with_slow_third_retry(rmnet::Session& s, FakeModem& m, uint64_t third_fail) {
  bring_up_v4_only(s, m, 100);
  std::vector<uint64_t> retries, probes;
  uint16_t third = 0;
  for (uint64_t t = 200; t <= 60100; t += 100) {
    if (t == third_fail) feed_frame(s, failed_start_frame(16, third), t);
    size_t sent = m.sent.size();
    s.tick(t);
    if (m.sent.size() == sent) continue;
    if (m.last()[9] == 0x2d) {
      probes.push_back(t);
      feed_frame(s, settings4_response_with_txid(m.last_txid()), t);
    } else {
      retries.push_back(t);
      if (retries.size() == 3) third = m.last_txid();
      else feed_frame(s, failed_start_frame(16, m.last_txid()), t);
    }
  }
  CHECK(retries == std::vector<uint64_t>({5100, 15100, 35100}));
  CHECK(probes == std::vector<uint64_t>({30100, 60100}));
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1); CHECK_EQ(m.downs, 0);
}

// Ticks every 100 ms over [from, to] and checks that nothing is sent and the link stays up.
void quiet(rmnet::Session& s, FakeModem& m, uint64_t from, uint64_t to) {
  size_t sent = m.sent.size();
  for (uint64_t t = from; t <= to; t += 100) s.tick(t);
  CHECK_EQ(m.sent.size(), sent); CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
}

}  // namespace

// The worst case for a silent modem: a retry falls due just before the next probe and goes out to
// a modem that no longer answers. Its Start Network waits 60 s, the probe follows and waits 10 s:
// the link goes down about 100 s after the modem goes silent (here, the last answered probe; a
// retry that first re-runs its earlier steps with slow answers can make it about 130 s from the
// last answered probe).
TEST(silent_modem_during_a_retry_is_noticed_after_the_retry_times_out) {
  FakeModem m; rmnet::Session s({}, m);
  up_with_slow_third_retry(s, m, 50000);                                      // last answered probe 60100; retry due 90000
  // From here the modem answers nothing.
  quiet(s, m, 60200, 89900);
  s.tick(90000); CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);      // retry: Start Network, 60 s timeout
  quiet(s, m, 90100, 149900);                                                 // the probe due at 90100 waits
  size_t sent = m.sent.size();
  s.tick(150000);                                                             // the retry times out; the link stays up
  CHECK_EQ(m.sent.size(), sent); CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
  s.tick(150100); CHECK_EQ(m.sent.size(), sent + 1);                          // the probe, not a second retry
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);
  quiet(s, m, 150200, 160000);
  s.tick(160100);                                                             // 100000 ms after the modem went silent
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);
  s.tick(160200); CHECK_EQ(m.downs, 1);
}

TEST(retry_and_probe_due_on_the_same_tick_send_the_retry_first) {
  FakeModem m; rmnet::Session s({}, m);
  up_with_slow_third_retry(s, m, 50100);                                      // probe and retry both due at 90100
  quiet(s, m, 60200, 90000);
  size_t sent = m.sent.size();
  s.tick(90100); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);                     // the retry's Start Network
  feed_frame(s, failed_start_frame(16, m.last_txid()), 90150);
  s.tick(90200); CHECK_EQ(m.sent.size(), sent + 2);
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);                     // then the probe, on the next tick
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.downs, 0);
}

// Restarting: stop() then start(), as CoreHost::restart does at a wake or after an uplink stall.

namespace {

// Feeds the capture's bring-up responses at `now`, each with the transaction ID of the request
// just sent (8 bits for CTL, 16 otherwise), so a session restarted mid-life can be brought up.
// `after_wds4_client` runs once the IPv4 WDS client is granted.
template <typename F>
void bring_up_again(rmnet::Session& s, FakeModem& m, uint64_t now, F after_wds4_client) {
  for (const char* r : kBringUpResponses) {
    std::vector<uint8_t> f = hex(r);
    if (f[4] == 0) f[7] = static_cast<uint8_t>(m.last_txid());
    else f = with_txid(r, m.last_txid());
    feed_frame(s, f, now);
    if (r == kCtlGetWds4Resp) after_wds4_client();
  }
}

// Ticks every second from `t` until the session is in `want`; returns that time.
uint64_t tick_until(rmnet::Session& s, uint64_t t, rmnet::SessionState want) {
  while (s.state() != want && t < 10000000) s.tick(t += 1000);
  return t;
}

}  // namespace

TEST(restart_from_up_with_a_probe_outstanding_ignores_its_late_answer) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  s.tick(30100); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);      // the probe is outstanding
  uint16_t probe = m.last_txid(); size_t before = m.sent.size();
  s.stop();
  CHECK_EQ(m.sent.size(), before + 5); CHECK_EQ(m.downs, 1);                  // the teardown went out:
  CHECK_EQ(m.sent[before + 0][5], 16); CHECK_EQ(m.sent[before + 0][9], 0x21); // Stop Network on IPv6 (the probe
  CHECK_EQ(m.sent[before + 2][5], 15); CHECK_EQ(m.sent[before + 2][9], 0x21); // took one transaction ID), IPv4,
  CHECK_BYTES(m.sent[before + 4], kCtlReleaseWdaReq);                         // then the WDA client released
  s.start(30200);
  CHECK(s.state() == rmnet::SessionState::Syncing); CHECK_EQ(m.sent.size(), before + 6);
  CHECK_EQ(m.last()[4], 0x00); CHECK_EQ(m.last()[8], 0x27);                    // the next request is a CTL Sync
  size_t sent = m.sent.size();
  feed_frame(s, settings4_response_with_txid(probe), 30300);                  // the late answer to the old probe
  CHECK(s.state() == rmnet::SessionState::Syncing); CHECK_EQ(m.sent.size(), sent); CHECK_EQ(m.ups, 1);
  bring_up_again(s, m, 30400, [&] {
    size_t n = m.sent.size(); uint16_t bind = m.last_txid();
    feed_frame(s, settings4_response_with_txid(probe), 30400);                // again, with client 15 granted anew
    CHECK(s.state() == rmnet::SessionState::Connecting); CHECK_EQ(m.sent.size(), n); CHECK_EQ(m.last_txid(), bind);
  });
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 1);   // link_down exactly once
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
}

TEST(restart_from_backoff_starts_with_the_first_backoff_again) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  uint64_t t = 0;
  for (int i = 0; i < 3; ++i) {                                               // Sync gives up three times: 2 s, 4 s, 8 s
    t = tick_until(s, t, rmnet::SessionState::Backoff);
    t = tick_until(s, t, rmnet::SessionState::Syncing);
  }
  t = tick_until(s, t, rmnet::SessionState::Backoff);                         // now waiting 16 s
  s.stop(); CHECK(s.state() == rmnet::SessionState::Idle);
  s.start(t);
  uint64_t failed = t;                                                        // the restarted Sync gives up 60 s later
  while (s.state() == rmnet::SessionState::Syncing) s.tick(++failed);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(failed, t + 60000);
  s.tick(failed + 1999); CHECK(s.state() == rmnet::SessionState::Backoff);
  s.tick(failed + 2000); CHECK(s.state() == rmnet::SessionState::Syncing);   // the first wait, 2 s, as a fresh session
}

// Follow-up gaps: the Get Client ID retry, reconfigure orders, the probe's ignored reply.

namespace {

// The capture's IPv6 CTL Get Client ID response with CTL transaction `txid`, failed with
// ClientIdsExhausted (0x05) when `ok` is false.
std::vector<uint8_t> get_wds6_client_response(uint8_t txid, bool ok) {
  std::vector<uint8_t> f = hex(kCtlGetWds6Resp);
  f[7] = txid;
  if (!ok) { f[15] = 0x01; f[17] = 0x05; }                                   // result: failure, error 0x05
  return f;
}

// The capture's IPv4 settings reply with transaction `txid` and the address 10.102.246.234.
std::vector<uint8_t> settings4_moved_with_txid(uint16_t txid) {
  auto reply = settings4_response_with_txid(txid);
  const uint8_t old_addr[7] = {0x1e, 0x04, 0x00, 0xe6, 0xf6, 0x66, 0x0a};    // TLV 0x1E: 10.102.246.230, u32le
  auto at = std::search(reply.begin(), reply.end(), old_addr, old_addr + 7);
  if (at == reply.end()) ::minitest::fail(__FILE__, __LINE__, "settings4_moved_with_txid(): address not found");
  else at[3] = 0xea;
  return reply;
}

}  // namespace

TEST(retry_of_a_family_that_never_got_a_client_starts_from_get_client_id) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsSettings4Resp);  // IPv6 Get Client ID outstanding
  feed_frame(s, get_wds6_client_response(static_cast<uint8_t>(m.last_txid()), false), 100);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK(m.cfg.settings.has_v4); CHECK(!m.cfg.settings.has_v6);
  size_t sent = m.sent.size();
  s.tick(5099); CHECK_EQ(m.sent.size(), sent);
  s.tick(5100); CHECK_EQ(m.sent.size(), sent + 1);
  CHECK_EQ(m.last()[4], 0x00); CHECK_EQ(m.last()[8], 0x22); CHECK_EQ(m.last().back(), 0x01);  // CTL Get Client ID for WDS
  feed_frame(s, get_wds6_client_response(static_cast<uint8_t>(m.last_txid()), false), 5200);   // refused again
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1); CHECK_EQ(m.downs, 0);
  sent = m.sent.size();
  s.tick(15199); CHECK_EQ(m.sent.size(), sent);
  s.tick(15200); CHECK_EQ(m.sent.size(), sent + 1);                           // next retry 10 s after the failure
  CHECK_EQ(m.last()[4], 0x00); CHECK_EQ(m.last()[8], 0x22); CHECK_EQ(m.last().back(), 0x01);  // from Get Client ID again
  feed_frame(s, get_wds6_client_response(static_cast<uint8_t>(m.last_txid()), true), 15300);   // client 16
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0xa2); CHECK_EQ(m.last()[10], 0x00);        // Bind Mux on client 16
  feed_frame(s, with_txid(kWdsBind6Resp, m.last_txid()), 15400);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x4d);                     // Set IP Family
  feed_frame(s, with_txid(kWdsFamily6Resp, m.last_txid()), 15500);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x20);                     // Start Network
  feed_frame(s, start6_response_with_txid(m.last_txid()), 15600);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x2d);                     // Get Current Settings
  feed_frame(s, settings6_response_with_txid(m.last_txid()), 15700);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 0);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
}

TEST(reconfigure_for_ipv4_during_an_ipv6_refresh_is_not_lost) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  feed_frame(s, reconfigure_indication(kWdsConnected6Ind), 5000);
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.downs, 1);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x2d);                     // IPv6 refreshed first
  size_t sent = m.sent.size(); uint16_t v6 = m.last_txid();
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 5005);
  CHECK_EQ(m.sent.size(), sent);                                              // remembered, not sent yet
  feed_frame(s, settings6_response_with_txid(v6), 5010);
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.ups, 1);
  CHECK_EQ(m.sent.size(), sent + 1); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);   // then IPv4
  feed_frame(s, settings4_moved_with_txid(m.last_txid()), 5020);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 1);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 ea");
  CHECK_BYTES(m.cfg.settings.v6_addr, 16, "20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08");
}

TEST(another_reconfigure_for_the_family_being_refreshed_is_ignored) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  // Alone: the refresh of IPv4 is not repeated, and IPv6 is not refreshed.
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 5000);
  size_t sent = m.sent.size(); uint16_t v4 = m.last_txid();
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 5005);
  CHECK_EQ(m.sent.size(), sent); CHECK(s.state() == rmnet::SessionState::Refreshing);
  feed_frame(s, settings4_response_with_txid(v4), 5010);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 1);
  CHECK_EQ(m.sent.size(), sent);                                              // no IPv6 refresh
  // A third indication, after the other family's: IPv4, then IPv6, then IPv4 again.
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 6000);
  CHECK(s.state() == rmnet::SessionState::Refreshing); CHECK_EQ(m.downs, 2);
  sent = m.sent.size(); v4 = m.last_txid(); CHECK_EQ(m.last()[5], 15);
  feed_frame(s, reconfigure_indication(kWdsConnected6Ind), 6005);
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 6006);
  CHECK_EQ(m.sent.size(), sent);
  feed_frame(s, settings4_response_with_txid(v4), 6010);
  CHECK_EQ(m.sent.size(), sent + 1); CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x2d);   // IPv6, once
  feed_frame(s, settings6_response_with_txid(m.last_txid()), 6020);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 3); CHECK_EQ(m.downs, 2);
  CHECK_EQ(m.sent.size(), sent + 1);                                          // and IPv4 not again
}

TEST(disconnect_while_a_refresh_is_remembered_forgets_it) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), 5000);
  uint16_t v4 = m.last_txid();
  feed_frame(s, reconfigure_indication(kWdsConnected6Ind), 5005);             // IPv6 remembered
  feed(s, kWdsDisconnected6Ind, 5010);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);     // the link was already down
  size_t sent = m.sent.size();
  feed_frame(s, settings4_response_with_txid(v4), 5020);                      // the late refresh answer
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.sent.size(), sent); CHECK_EQ(m.ups, 1);
  uint64_t t = tick_until(s, 5010, rmnet::SessionState::Syncing);
  bring_up_again(s, m, t, [] {});
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2); CHECK_EQ(m.downs, 1);
  // The remembered IPv6 refresh did not survive the redial: a new IPv4 refresh is followed by nothing.
  feed_frame(s, reconfigure_indication(kWdsConnected4Ind), t + 1000);
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);
  sent = m.sent.size();
  feed_frame(s, settings4_response_with_txid(m.last_txid()), t + 1010);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 3); CHECK_EQ(m.downs, 2);
  CHECK_EQ(m.sent.size(), sent);
}

TEST(probe_reply_settings_never_reach_a_later_link_up) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  s.tick(30100); CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x2d);      // the probe, on the IPv4 client
  feed_frame(s, settings4_moved_with_txid(m.last_txid()), 30200);            // reports 10.102.246.234
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  // An IPv6 refresh reports link up again with the IPv4 settings the session holds.
  feed_frame(s, reconfigure_indication(kWdsConnected6Ind), 31000);
  CHECK_EQ(m.last()[5], 16); CHECK_EQ(m.last()[9], 0x2d);
  feed_frame(s, settings6_response_with_txid(m.last_txid()), 31100);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2);
  CHECK(m.cfg.settings.has_v4); CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 e6");   // from bring-up, not the probe
}

// In-band flow control: Set Data Format asks for it when configured, and falls back at once,
// without it, if the modem does not accept it.

namespace {

rmnet::SessionConfig flow_config() {
  rmnet::SessionConfig c;
  c.flow_control = true;
  return c;
}

// `capture` with its transaction ID set to the last request's (8 bits for CTL, 16 otherwise).
std::vector<uint8_t> answering_last(FakeModem& m, const char* capture) {
  std::vector<uint8_t> f = hex(capture);
  if (f[4] == 0) f[7] = static_cast<uint8_t>(m.last_txid());
  else f = with_txid(capture, m.last_txid());
  return f;
}

// Feeds the capture's bring-up responses from `first` on, each answering the request just sent.
void answer_from(rmnet::Session& s, FakeModem& m, uint64_t now, const char* first) {
  bool on = false;
  for (const char* r : kBringUpResponses) {
    on = on || r == first;
    if (on) feed_frame(s, answering_last(m, r), now);
  }
}

// The request the session must send, as hex text: `capture` with the last request's transaction ID.
std::string expected_request(FakeModem& m, const char* capture) {
  std::vector<uint8_t> f = with_txid(capture, m.last_txid());
  return minitest::to_hex(f.data(), f.size());
}

// A Set Data Format response on WDA `client` with transaction `txid` that failed with `error`.
std::vector<uint8_t> set_format_error_frame(uint8_t client, uint16_t txid, uint16_t error) {
  std::vector<uint8_t> buf(64);
  rmnet::QmiBuilder b(buf.data(), buf.size(),
                      {rmnet::QmiService::WDA, client, rmnet::QmiKind::Response, txid, rmnet::kWdaSetDataFormat});
  const uint8_t result[4] = {0x01, 0x00, static_cast<uint8_t>(error), static_cast<uint8_t>(error >> 8)};
  b.tlv(0x02, result, sizeof result);
  buf.resize(b.finish());
  buf[3] = 0x80;  // from the modem
  return buf;
}

constexpr uint16_t kSomeError = 0x0030;

// The recorded response, with the modem granting flow control (TLV 0x1B = 01).
std::vector<uint8_t> granted_format_response(uint16_t txid) {
  std::vector<uint8_t> f = with_txid(kWdaSetFormatResp, txid);
  f.back() = 0x01;
  return f;
}

}  // namespace

TEST(asks_for_flow_control_when_configured) {
  FakeModem m; rmnet::Session s(flow_config(), m);
  CHECK(!s.flow_control_asked());                                             // nothing sent yet
  bring_up_to(s, m, kCtlGetWdaResp);
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReqFlow).c_str());
  CHECK(s.flow_control_asked()); CHECK(!s.flow_control_refused());
}

TEST(does_not_ask_by_default) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWdaResp);
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());
  CHECK(!s.flow_control_asked()); CHECK(!s.flow_control_refused());
}

TEST(a_granted_flow_control_reaches_link_up) {
  FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
  feed_frame(s, granted_format_response(m.last_txid()), 100);
  answer_from(s, m, 100, kCtlGetWds4Resp);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK_EQ(m.cfg.format.flow_control, 1);
  CHECK(s.flow_control_asked()); CHECK(!s.flow_control_refused());
}

TEST(a_refused_flow_control_falls_back_at_once) {
  FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
  uint16_t first = m.last_txid(); size_t sent = m.sent.size();
  feed_frame(s, set_format_error_frame(1, first, kSomeError), 100);
  CHECK_EQ(m.sent.size(), sent + 1);                                          // the fallback, at once: no teardown,
  CHECK(m.last_txid() != first);                                              // no backoff wait, a new transaction
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());       // and no flow control TLV
  CHECK(s.state() == rmnet::SessionState::Configuring); CHECK_EQ(m.downs, 0);
  CHECK(s.flow_control_refused()); CHECK(!s.flow_control_asked());
  feed_frame(s, with_txid(kWdaSetFormatResp, first), 150);                    // a late answer to the first request
  CHECK_EQ(m.sent.size(), sent + 1); CHECK(s.state() == rmnet::SessionState::Configuring);
  answer_from(s, m, 200, kWdaSetFormatResp);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK_EQ(m.cfg.format.flow_control, 0);                                     // the answer without the field
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
}

TEST(an_unusable_answer_with_flow_control_falls_back) {
  std::vector<uint8_t> unusable = hex(kWdaSetFormatResp); unusable[27] = 0x01;          // link layer 1 instead of 2
  std::vector<uint8_t> unparsable = hex(kWdaSetFormatResp);                   // TLV 0x1B two bytes: 1b 02 00 00 00
  unparsable.push_back(0x00); unparsable[unparsable.size() - 4] = 0x02; unparsable[1] += 1; unparsable[11] += 1;
  for (const std::vector<uint8_t>& bad : {unusable, unparsable}) {
    FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
    uint16_t first = m.last_txid(); size_t sent = m.sent.size();
    std::vector<uint8_t> f = bad; f[7] = static_cast<uint8_t>(first); f[8] = static_cast<uint8_t>(first >> 8);
    feed_frame(s, f, 100);
    CHECK_EQ(m.sent.size(), sent + 1); CHECK(m.last_txid() != first);
    CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());
    CHECK(s.state() == rmnet::SessionState::Configuring); CHECK(s.flow_control_refused());
    answer_from(s, m, 200, kWdaSetFormatResp);
    CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  }
}

TEST(a_timeout_with_flow_control_falls_back) {
  FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);   // asked at t=100
  uint16_t first = m.last_txid(); size_t sent = m.sent.size();
  s.tick(10099); CHECK_EQ(m.sent.size(), sent);
  s.tick(10100);
  CHECK_EQ(m.sent.size(), sent + 1); CHECK(m.last_txid() != first);
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());
  CHECK(s.state() == rmnet::SessionState::Configuring); CHECK(s.flow_control_refused());
  s.tick(20099); CHECK(s.state() == rmnet::SessionState::Configuring);        // a fresh 10 s for the fallback
  answer_from(s, m, 20099, kWdaSetFormatResp);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
}

TEST(a_refusal_is_remembered_across_a_restart) {
  FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
  feed_frame(s, set_format_error_frame(1, m.last_txid(), kSomeError), 100);
  answer_from(s, m, 100, kWdaSetFormatResp);
  CHECK(s.state() == rmnet::SessionState::Up);
  s.stop(); s.start(1000);
  feed_frame(s, answering_last(m, kCtlSyncResp), 1100);
  feed_frame(s, answering_last(m, kCtlGetWdaResp), 1100);
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());
  CHECK(!s.flow_control_asked()); CHECK(s.flow_control_refused());
}

TEST(a_failure_without_flow_control_is_as_before) {
  {                                                                           // not configured: as today
    FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWdaResp);
    feed_frame(s, set_format_error_frame(1, m.last_txid(), kSomeError), 100);
    CHECK(s.state() == rmnet::SessionState::Backoff); CHECK(!s.flow_control_refused());
    CHECK_EQ(m.last()[8], 0x23); CHECK_EQ(m.last()[15], 0x1a);               // the teardown (release the WDA
                                                                              // client), not a new request
    s.tick(2099); CHECK(s.state() == rmnet::SessionState::Backoff);
    s.tick(2100); CHECK(s.state() == rmnet::SessionState::Syncing);
  }
  {                                                                           // refused, then the fallback fails
    FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
    feed_frame(s, set_format_error_frame(1, m.last_txid(), kSomeError), 100);
    feed_frame(s, set_format_error_frame(1, m.last_txid(), kSomeError), 200);
    CHECK(s.state() == rmnet::SessionState::Backoff); CHECK(s.flow_control_refused());
    s.tick(2199); CHECK(s.state() == rmnet::SessionState::Backoff);
    s.tick(2200); CHECK(s.state() == rmnet::SessionState::Syncing);
  }
  {                                                                           // refused, then the fallback times out
    FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
    s.tick(10100); s.tick(20099); CHECK(s.state() == rmnet::SessionState::Configuring);
    s.tick(20100); CHECK(s.state() == rmnet::SessionState::Backoff);
  }
}

TEST(a_refusal_is_remembered_across_a_backoff_redial) {
  FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
  feed_frame(s, set_format_error_frame(1, m.last_txid(), kSomeError), 100);  // refused
  feed_frame(s, set_format_error_frame(1, m.last_txid(), kSomeError), 200);  // the fallback fails too
  CHECK(s.state() == rmnet::SessionState::Backoff);
  s.tick(2200); CHECK(s.state() == rmnet::SessionState::Syncing);            // the redial, from backoff
  feed_frame(s, answering_last(m, kCtlSyncResp), 2300);
  feed_frame(s, answering_last(m, kCtlGetWdaResp), 2300);
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());
  CHECK(!s.flow_control_asked()); CHECK(s.flow_control_refused());
}

TEST(giving_up_flow_control_omits_it_after_a_restart) {
  FakeModem m; rmnet::Session s(flow_config(), m); bring_up_to(s, m, kCtlGetWdaResp);
  feed_frame(s, granted_format_response(m.last_txid()), 100);
  answer_from(s, m, 100, kCtlGetWds4Resp);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.cfg.format.flow_control, 1);
  size_t sent = m.sent.size();
  s.give_up_flow_control();
  CHECK_EQ(m.sent.size(), sent); CHECK(s.state() == rmnet::SessionState::Up);   // sends nothing, changes nothing else
  CHECK(s.flow_control_refused());
  s.stop(); s.start(1000);
  feed_frame(s, answering_last(m, kCtlSyncResp), 1100);
  feed_frame(s, answering_last(m, kCtlGetWdaResp), 1100);
  CHECK_BYTES(m.last(), expected_request(m, kWdaSetFormatReq).c_str());
  CHECK(!s.flow_control_asked()); CHECK(s.flow_control_refused());
}

// Pinned behaviour (the deferred list of 2026-11-13): the teardown on entering Backoff, Start
// Network's 60 s timeout, the backoff's steps.

namespace {

std::string as_text(const std::vector<uint8_t>& f) { return minitest::to_hex(f.data(), f.size()); }

// A captured CTL frame with its 8-bit transaction ID replaced.
std::vector<uint8_t> ctl_with_txid(const char* hex_text, uint8_t txid) {
  std::vector<uint8_t> f = hex(hex_text);
  f[7] = txid;
  return f;
}

// The capture's CTL Sync response with CTL transaction `txid`, failed (status 1, error 3).
std::vector<uint8_t> failed_sync_response(uint8_t txid) {
  std::vector<uint8_t> f = ctl_with_txid(kCtlSyncResp, txid);
  f[15] = 0x01; f[17] = 0x03;
  return f;
}

}  // namespace

TEST(entering_backoff_sends_the_teardown) {
  {
    // From Up, the IPv4 call drops: it is gone, so only its client is released. These are the
    // capture's own frames, since bring-up used the capture's transaction IDs and nothing came since.
    FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m); size_t before = m.sent.size();
    feed(s, kWdsDisconnected4Ind, 5000);
    CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);
    REQUIRE(m.sent.size() == before + 4);
    CHECK_BYTES(m.sent[before + 0], kWdsStop6Req);    CHECK_BYTES(m.sent[before + 1], kCtlRelease6Req);
    CHECK_BYTES(m.sent[before + 2], kCtlRelease4Req); CHECK_BYTES(m.sent[before + 3], kCtlReleaseWdaReq);
    s.tick(6999); CHECK_EQ(m.sent.size(), before + 4);                        // then nothing until the redial
  }
  {
    // From Up, the probe (transaction 10) goes unanswered: both calls are stopped, IPv6 first, with
    // the next transaction IDs, then all three clients released.
    FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
    s.tick(30100); REQUIRE(m.last_txid() == 10u); size_t before = m.sent.size();
    s.tick(40100);
    CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.downs, 1);
    REQUIRE(m.sent.size() == before + 5);
    CHECK_BYTES(m.sent[before + 0], as_text(with_txid(kWdsStop6Req, 11)).c_str());
    CHECK_BYTES(m.sent[before + 1], kCtlRelease6Req);
    CHECK_BYTES(m.sent[before + 2], as_text(with_txid(kWdsStop4Req, 12)).c_str());
    CHECK_BYTES(m.sent[before + 3], kCtlRelease4Req);
    CHECK_BYTES(m.sent[before + 4], kCtlReleaseWdaReq);
  }
}

TEST(start_network_gets_60_s_before_backing_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily4Resp);   // IPv4 Start Network sent at 100
  CHECK_EQ(m.last()[5], 15); CHECK_EQ(m.last()[9], 0x20);
  size_t sent = m.sent.size();
  s.tick(10100); CHECK(s.state() == rmnet::SessionState::Connecting);         // other requests time out at 10 s
  s.tick(60099); CHECK(s.state() == rmnet::SessionState::Connecting); CHECK_EQ(m.sent.size(), sent);
  s.tick(60100); CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.ups, 0);
  // Not on to IPv6: the teardown releases the IPv4 client (no call to stop) and the WDA client.
  REQUIRE(m.sent.size() == sent + 2);
  CHECK_BYTES(m.sent[sent + 0], as_text(ctl_with_txid(kCtlRelease4Req, 4)).c_str());
  CHECK_BYTES(m.sent[sent + 1], as_text(ctl_with_txid(kCtlReleaseWdaReq, 5)).c_str());
}

TEST(backoff_waits_double_from_2_s_up_to_60_s) {
  // Every Sync is refused at once, so each Backoff follows the last: 2 s, then 4, 8, 16 and 32 s,
  // then 60 s, not 64 (a wait of half the 60 s cap or more is followed by the cap), and 60 s on.
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  uint64_t t = 0;
  for (uint64_t wait : {2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000}) {
    feed_frame(s, failed_sync_response(static_cast<uint8_t>(m.last_txid())), t);
    CHECK(s.state() == rmnet::SessionState::Backoff);
    size_t sent = m.sent.size();
    s.tick(t + wait - 1); CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.sent.size(), sent);
    s.tick(t + wait);     CHECK(s.state() == rmnet::SessionState::Syncing); CHECK_EQ(m.sent.size(), sent + 1);
    t += wait;
  }
}
