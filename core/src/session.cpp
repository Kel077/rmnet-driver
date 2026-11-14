#include "rmnet/session.h"

#include <string.h>

namespace rmnet {

namespace {

constexpr uint8_t kFamilyIpv4 = 4;  // libqmi: QMI_WDS_IP_FAMILY_IPV4
constexpr uint8_t kFamilyIpv6 = 6;  // libqmi: QMI_WDS_IP_FAMILY_IPV6
constexpr uint8_t kFamilyValues[2] = {kFamilyIpv4, kFamilyIpv6};

constexpr uint8_t kStatusDisconnected = 1;  // libqmi: QMI_WDS_CONNECTION_STATUS_DISCONNECTED
constexpr uint8_t kStatusConnected = 2;     // libqmi: QMI_WDS_CONNECTION_STATUS_CONNECTED

constexpr uint32_t kFirstBackoffMs = 2000;
constexpr uint32_t kMaxBackoffMs = 60000;

// Milliseconds from `since` to `now`; 0 if the clock appears to have gone backwards.
uint64_t elapsed(uint64_t now, uint64_t since) { return now >= since ? now - since : 0; }

bool response_ok(const QmiMessage& m) {
  QmiResult r = qmi_result(m);
  return r.present && r.ok;
}

}  // namespace

Session::Session(const SessionConfig& cfg, SessionDelegate& delegate)
    : cfg_(cfg),
      delegate_(delegate),
      state_(SessionState::Idle),
      ctl_txid_(1),
      txid_(1),
      pending_(),
      sync_started_ms_(0),
      backoff_started_ms_(0),
      backoff_wait_ms_(0),
      next_backoff_ms_(kFirstBackoffMs),
      has_wda_client_(false),
      wda_client_(0),
      families_(),
      current_(0),
      link_is_up_(false),
      link_(),
      retry_due_(false),
      retrying_(false),
      retry_from_ms_(0),
      retry_wait_ms_(0),
      next_retry_wait_ms_(kFamilyRetryFirstMs),
      probe_from_ms_(0),
      refresh_other_(false),
      flow_asked_(false),
      flow_refused_(false),
      buf_() {}

SessionState Session::state() const { return state_; }

bool Session::flow_control_asked() const { return flow_asked_; }

bool Session::flow_control_refused() const { return flow_refused_; }

void Session::give_up_flow_control() { flow_refused_ = true; }

void Session::start(uint64_t now_ms) {
  if (state_ != SessionState::Idle) return;
  begin_sync(now_ms);
}

void Session::stop() {
  if (state_ == SessionState::Idle) return;
  pending_.active = false;
  cancel_retry();
  refresh_other_ = false;
  next_backoff_ms_ = kFirstBackoffMs;  // a session started again begins as a fresh one
  state_ = SessionState::Idle;
  if (link_is_up_) {
    link_is_up_ = false;
    delegate_.link_down();
  }
  teardown();
}

void Session::tick(uint64_t now_ms) {
  switch (state_) {
    case SessionState::Idle:
      return;
    case SessionState::Up:
      tick_up(now_ms);
      return;
    case SessionState::Backoff:
      if (elapsed(now_ms, backoff_started_ms_) >= backoff_wait_ms_) begin_sync(now_ms);
      return;
    case SessionState::Syncing:
      if (elapsed(now_ms, sync_started_ms_) >= kSyncGiveUpMs) {
        enter_backoff(now_ms);
      } else if (elapsed(now_ms, pending_.sent_ms) >= kSyncResendMs) {
        send_sync(now_ms);
      }
      return;
    case SessionState::Configuring:
    case SessionState::Connecting:
    case SessionState::Refreshing:
      if (pending_.active && elapsed(now_ms, pending_.sent_ms) >= pending_.timeout_ms) {
        if (pending_.step == Step::SetDataFormat && flow_asked_) {
          refuse_flow_control(now_ms);
          return;
        }
        enter_backoff(now_ms);
      }
      return;
  }
}

void Session::on_qmi(const uint8_t* data, size_t len, uint64_t now_ms) {
  QmiMessage m;
  if (!qmi_decode({data, len}, &m)) return;
  if (m.hdr.kind == QmiKind::Indication) {
    on_indication(m, now_ms);
    return;
  }
  if (m.hdr.kind != QmiKind::Response || !pending_.active) return;
  const Pending& p = pending_;
  if (m.hdr.service != p.service || m.hdr.client != p.client || m.hdr.txid != p.txid ||
      m.hdr.msg_id != p.msg_id) {
    return;
  }
  pending_.active = false;
  on_response(m, now_ms);
}

void Session::on_response(const QmiMessage& m, uint64_t now_ms) {
  Family& fam = families_[current_];
  switch (pending_.step) {
    case Step::Sync: {
      if (!response_ok(m)) break;
      state_ = SessionState::Configuring;
      uint8_t tx = next_ctl_txid();
      size_t n = build_ctl_get_client_id(buf_, sizeof buf_, tx, QmiService::WDA);
      expect(Step::GetWdaClient, QmiService::CTL, 0, tx, kCtlGetClientId, n, now_ms,
             kRequestTimeoutMs);
      return;
    }
    case Step::GetWdaClient: {
      QmiService service;
      uint8_t client;
      if (!parse_ctl_get_client_id(m, &service, &client) || service != QmiService::WDA) break;
      has_wda_client_ = true;
      wda_client_ = client;
      send_set_data_format(now_ms);
      return;
    }
    case Step::SetDataFormat: {
      DataFormat f;
      if (!parse_wda_data_format(m, &f) || !data_format_usable(f)) {
        if (flow_asked_) {
          refuse_flow_control(now_ms);
          return;
        }
        break;
      }
      link_.format = f;
      begin_family(0, now_ms);
      return;
    }
    case Step::GetWdsClient: {
      QmiService service;
      uint8_t client;
      if (!parse_ctl_get_client_id(m, &service, &client) || service != QmiService::WDS) {
        family_done(now_ms);
        return;
      }
      fam.has_client = true;
      fam.client = client;
      send_bind(now_ms);
      return;
    }
    case Step::Bind: {
      if (!response_ok(m)) {
        family_done(now_ms);
        return;
      }
      uint16_t tx = next_txid();
      size_t n = build_wds_set_ip_family(buf_, sizeof buf_, fam.client, tx, kFamilyValues[current_]);
      expect(Step::IpFamily, QmiService::WDS, fam.client, tx, kWdsSetIpFamily, n, now_ms,
             kRequestTimeoutMs);
      return;
    }
    case Step::IpFamily: {
      if (!response_ok(m)) {
        family_done(now_ms);
        return;
      }
      fam.configured = true;
      send_start(now_ms);
      return;
    }
    case Step::Start: {
      uint32_t handle = 0;
      CallEnd end;
      if (parse_wds_start_network(m, &handle, &end)) {
        fam.has_handle = true;
        fam.handle = handle;
      } else {
        QmiResult r = qmi_result(m);
        // NoEffect: a call of this family is already up; adopt it, without a handle to stop.
        if (!(r.present && !r.ok && r.error == kQmiErrNoEffect)) {
          family_done(now_ms);
          return;
        }
      }
      fam.live = true;
      send_settings(now_ms);
      return;
    }
    case Step::Settings: {
      if (state_ == SessionState::Refreshing) {
        // A refresh without settings goes to Backoff, taking the other family down too. That
        // includes an IPv4 reply with an address but no gateway or mask; intended.
        clear_family_settings(current_);
        if (!parse_wds_current_settings(m, &link_.settings) || !family_has_settings(current_)) {
          break;
        }
        if (refresh_other_) {
          refresh_other_ = false;
          current_ = current_ == 0 ? 1 : 0;
          send_settings(now_ms);
          return;
        }
        finish_bring_up(now_ms);
        return;
      }
      // A reply that fails to parse leaves the settings unchanged, so this family has none. A
      // call that dropped while the reply was outstanding gets none either.
      if (fam.live) (void)parse_wds_current_settings(m, &link_.settings);
      family_done(now_ms);
      return;
    }
    case Step::Probe:
      // The modem answered: alive, whatever the result. The settings it reports are not used.
      probe_from_ms_ = now_ms;
      return;
  }
  enter_backoff(now_ms);
}

void Session::on_indication(const QmiMessage& m, uint64_t now_ms) {
  if (state_ != SessionState::Connecting && state_ != SessionState::Up &&
      state_ != SessionState::Refreshing) {
    return;
  }
  if (m.hdr.service != QmiService::WDS || m.hdr.msg_id != kWdsPacketServiceStatus) return;
  uint8_t index = 0;
  while (index < 2 && !(families_[index].has_client && families_[index].client == m.hdr.client)) {
    ++index;
  }
  if (index == 2) return;
  PacketStatus status;
  if (!parse_wds_packet_status(m, &status)) return;

  Family& fam = families_[index];
  if (state_ == SessionState::Connecting) {
    // A family whose call drops during bring-up no longer counts; the last family_done() then
    // sees whether anything remains. Other indications are harmless here.
    if (status.status == kStatusDisconnected) {
      fam.has_handle = false;
      fam.live = false;
      clear_family_settings(index);
    }
    return;
  }

  // Up or Refreshing: only the families that carry the link matter. A family that failed during
  // bring-up keeps its client, so a late indication from it must not take the link down. The one
  // exception: if the call of the family being retried drops, its settings must not be used.
  if (!family_has_settings(index)) {
    if (retrying_ && index == current_ && status.status == kStatusDisconnected) {
      fam.has_handle = false;
      fam.live = false;
    }
    return;
  }
  // Either way an outstanding probe is abandoned: enter_backoff() drops it, and a refresh drops it
  // below. Its late answer then matches nothing, since the refresh uses a new transaction ID.
  if (status.status == kStatusDisconnected) {
    fam.has_handle = false;  // the call is gone; nothing to stop
    fam.live = false;
    enter_backoff(now_ms);
  } else if (status.status == kStatusConnected && status.reconfigure) {
    if (state_ == SessionState::Refreshing) {
      // The other family is refreshed once the current one is done, instead of being dropped.
      if (index != current_) refresh_other_ = true;
      return;
    }
    pending_.active = false;  // an outstanding probe (or retry, below) is abandoned
    if (retrying_) {
      // The refresh takes over the one outstanding request. The abandoned retry is due again as
      // soon as the session is back Up, with the same next wait.
      retrying_ = false;
      retry_due_ = true;
      retry_from_ms_ = now_ms;
      retry_wait_ms_ = 0;
    }
    link_is_up_ = false;
    state_ = SessionState::Refreshing;
    current_ = index;
    delegate_.link_down();
    send_settings(now_ms);
  }
}

uint8_t Session::next_ctl_txid() {
  uint8_t tx = ctl_txid_++;
  if (ctl_txid_ == 0) ctl_txid_ = 1;
  return tx;
}

uint16_t Session::next_txid() {
  uint16_t tx = txid_++;
  if (txid_ == 0) txid_ = 1;
  return tx;
}

// Records the request just built in buf_ as the outstanding one and sends it. A request that
// did not fit (len 0) is not sent; its timeout then takes the session to Backoff.
void Session::expect(Step step, QmiService service, uint8_t client, uint16_t txid,
                     uint16_t msg_id, size_t len, uint64_t now_ms, uint32_t timeout_ms) {
  pending_ = {true, step, service, client, txid, msg_id, now_ms, timeout_ms};
  transmit(len);
}

void Session::transmit(size_t len) {
  if (len > 0) delegate_.send_qmi(buf_, len);
}

// Asks for flow control while configured with it and it has not been refused.
void Session::send_set_data_format(uint64_t now_ms) {
  flow_asked_ = cfg_.flow_control && !flow_refused_;
  uint16_t tx = next_txid();
  size_t n = build_wda_set_data_format(buf_, sizeof buf_, wda_client_, tx, cfg_.iface_number,
                                       flow_asked_);
  expect(Step::SetDataFormat, QmiService::WDA, wda_client_, tx, kWdaSetDataFormat, n, now_ms,
         kRequestTimeoutMs);
}

// A Set Data Format request that asked for flow control failed: asks again at once without it,
// with a new transaction ID (so a late answer to the first request matches nothing) and a fresh
// timeout.
void Session::refuse_flow_control(uint64_t now_ms) {
  flow_refused_ = true;
  send_set_data_format(now_ms);
}

void Session::begin_sync(uint64_t now_ms) {
  reset_clients();
  link_ = LinkConfig();
  state_ = SessionState::Syncing;
  sync_started_ms_ = now_ms;
  send_sync(now_ms);
}

void Session::send_sync(uint64_t now_ms) {
  uint8_t tx = next_ctl_txid();
  size_t n = build_ctl_sync(buf_, sizeof buf_, tx);
  expect(Step::Sync, QmiService::CTL, 0, tx, kCtlSync, n, now_ms, kSyncResendMs);
}

// begin_family and send_settings can run right after a delegate callback. If the delegate broke
// the rule and stopped the session from inside it, the session is Idle and must stay so.
void Session::begin_family(uint8_t index, uint64_t now_ms) {
  if (state_ == SessionState::Idle) return;
  state_ = SessionState::Connecting;
  current_ = index;
  uint8_t tx = next_ctl_txid();
  size_t n = build_ctl_get_client_id(buf_, sizeof buf_, tx, QmiService::WDS);
  expect(Step::GetWdsClient, QmiService::CTL, 0, tx, kCtlGetClientId, n, now_ms,
         kRequestTimeoutMs);
}

void Session::send_bind(uint64_t now_ms) {
  const Family& fam = families_[current_];
  uint16_t tx = next_txid();
  size_t n = build_wds_bind_mux(buf_, sizeof buf_, fam.client, tx, cfg_.iface_number, cfg_.mux_id);
  expect(Step::Bind, QmiService::WDS, fam.client, tx, kWdsBindMuxDataPort, n, now_ms,
         kRequestTimeoutMs);
}

void Session::send_start(uint64_t now_ms) {
  const Family& fam = families_[current_];
  uint16_t tx = next_txid();
  size_t n = build_wds_start_network(buf_, sizeof buf_, fam.client, tx, cfg_.profile,
                                     kFamilyValues[current_]);
  expect(Step::Start, QmiService::WDS, fam.client, tx, kWdsStartNetwork, n, now_ms,
         kStartNetworkTimeoutMs);
}

void Session::send_settings(uint64_t now_ms) {
  if (state_ == SessionState::Idle) return;
  const Family& fam = families_[current_];
  uint16_t tx = next_txid();
  size_t n = build_wds_get_current_settings(buf_, sizeof buf_, fam.client, tx);
  expect(Step::Settings, QmiService::WDS, fam.client, tx, kWdsGetCurrentSettings, n, now_ms,
         kRequestTimeoutMs);
}

// Up: a retry of the missing family and the liveness probe share the one outstanding request.
// This is the only place either starts or times out, so neither starts while the other is
// outstanding; whichever falls due meanwhile waits. When both are due, the retry goes first: a
// retry waits at least kFamilyRetryFirstMs after it ends, so the probe follows it at once.
void Session::tick_up(uint64_t now_ms) {
  if (pending_.active) {
    if (elapsed(now_ms, pending_.sent_ms) < pending_.timeout_ms) return;
    if (pending_.step == Step::Probe) {
      enter_backoff(now_ms);  // the modem went silent: the link must not look up
      return;
    }
    pending_.active = false;  // the retry's request timed out; the link stays up
    retry_done(now_ms);
    return;
  }
  if (retry_due_ && elapsed(now_ms, retry_from_ms_) >= retry_wait_ms_) {
    begin_retry(now_ms);
  } else if (!retrying_ && elapsed(now_ms, probe_from_ms_) >= kLivenessIntervalMs) {
    send_probe(now_ms);
  }
}

// Sends Get Current Settings on the first live family, IPv4 first. Up always has one; if none is
// live, no probe is sent.
void Session::send_probe(uint64_t now_ms) {
  for (uint8_t i = 0; i < 2; ++i) {
    const Family& fam = families_[i];
    if (!fam.live || !fam.has_client) continue;
    uint16_t tx = next_txid();
    size_t n = build_wds_get_current_settings(buf_, sizeof buf_, fam.client, tx);
    expect(Step::Probe, QmiService::WDS, fam.client, tx, kWdsGetCurrentSettings, n, now_ms,
           kRequestTimeoutMs);
    return;
  }
}

// The current family is finished, with or without settings. A failed family keeps its client
// (and any handle) until teardown releases them. During a retry, the retry is finished instead.
void Session::family_done(uint64_t now_ms) {
  if (retrying_) {
    retry_done(now_ms);
    return;
  }
  if (current_ == 0) {
    begin_family(1, now_ms);
    return;
  }
  if (!family_has_settings(0) && !family_has_settings(1)) {
    enter_backoff(now_ms);
    return;
  }
  next_retry_wait_ms_ = kFamilyRetryFirstMs;
  schedule_retry(now_ms);
  finish_bring_up(now_ms);
}

// Schedules a retry of the missing family, if one is missing, with the next wait.
void Session::schedule_retry(uint64_t now_ms) {
  retry_due_ = !family_has_settings(0) || !family_has_settings(1);
  if (!retry_due_) return;
  retry_from_ms_ = now_ms;
  retry_wait_ms_ = next_retry_wait_ms_;
  next_retry_wait_ms_ = next_retry_wait_ms_ >= kFamilyRetryMaxMs / 2 ? kFamilyRetryMaxMs
                                                                       : next_retry_wait_ms_ * 2;
}

// Up, with the link carried by one family: starts bringing up the other. A family that kept its
// configured client from bring-up goes straight to Start Network; one whose Bind Mux or Set IP
// Family failed starts again from Bind Mux.
void Session::begin_retry(uint64_t now_ms) {
  retry_due_ = false;
  retrying_ = true;
  current_ = family_has_settings(0) ? 1 : 0;
  const Family& fam = families_[current_];
  if (fam.has_client && fam.configured) {
    send_start(now_ms);
    return;
  }
  if (fam.has_client) {
    send_bind(now_ms);
    return;
  }
  uint8_t tx = next_ctl_txid();
  size_t n = build_ctl_get_client_id(buf_, sizeof buf_, tx, QmiService::WDS);
  expect(Step::GetWdsClient, QmiService::CTL, 0, tx, kCtlGetClientId, n, now_ms,
         kRequestTimeoutMs);
}

// The retry finished, answered or timed out. With settings for the family, the link gains it and
// stays up; otherwise the next retry is scheduled and nothing else changes.
void Session::retry_done(uint64_t now_ms) {
  retrying_ = false;
  if (family_has_settings(current_)) {
    retry_due_ = false;
    delegate_.link_up(link_);
    return;
  }
  schedule_retry(now_ms);
}

void Session::cancel_retry() {
  retry_due_ = false;
  retrying_ = false;
}

void Session::finish_bring_up(uint64_t now_ms) {
  state_ = SessionState::Up;
  link_is_up_ = true;
  probe_from_ms_ = now_ms;
  next_backoff_ms_ = kFirstBackoffMs;
  delegate_.link_up(link_);
}

void Session::enter_backoff(uint64_t now_ms) {
  pending_.active = false;
  cancel_retry();
  refresh_other_ = false;
  state_ = SessionState::Backoff;
  backoff_started_ms_ = now_ms;
  backoff_wait_ms_ = next_backoff_ms_;
  next_backoff_ms_ = next_backoff_ms_ >= kMaxBackoffMs / 2 ? kMaxBackoffMs : next_backoff_ms_ * 2;
  if (link_is_up_) {
    link_is_up_ = false;
    delegate_.link_down();
  }
  teardown();
}

// Sends, without waiting for answers: Stop Network and Release Client ID for IPv6, the same
// for IPv4, then Release Client ID for WDA. Forgets every client.
void Session::teardown() {
  for (int i = 1; i >= 0; --i) {
    Family& fam = families_[i];
    if (fam.has_client && fam.has_handle) {
      transmit(build_wds_stop_network(buf_, sizeof buf_, fam.client, next_txid(), fam.handle));
    }
    if (fam.has_client) {
      transmit(build_ctl_release_client_id(buf_, sizeof buf_, next_ctl_txid(), QmiService::WDS,
                                           fam.client));
    }
  }
  if (has_wda_client_) {
    transmit(build_ctl_release_client_id(buf_, sizeof buf_, next_ctl_txid(), QmiService::WDA,
                                         wda_client_));
  }
  reset_clients();
}

void Session::reset_clients() {
  has_wda_client_ = false;
  wda_client_ = 0;
  memset(families_, 0, sizeof families_);
}

void Session::clear_family_settings(uint8_t index) {
  RuntimeSettings& s = link_.settings;
  if (index == 0) {
    s.has_v4 = false;
    memset(s.v4_addr, 0, sizeof s.v4_addr);
    memset(s.v4_gateway, 0, sizeof s.v4_gateway);
    memset(s.v4_mask, 0, sizeof s.v4_mask);
    memset(s.v4_dns, 0, sizeof s.v4_dns);
    s.v4_dns_count = 0;
  } else {
    s.has_v6 = false;
    memset(s.v6_addr, 0, sizeof s.v6_addr);
    s.v6_prefix_len = 0;
    memset(s.v6_gateway, 0, sizeof s.v6_gateway);
    memset(s.v6_dns, 0, sizeof s.v6_dns);
    s.v6_dns_count = 0;
  }
}

bool Session::family_has_settings(uint8_t index) const {
  return index == 0 ? link_.settings.has_v4 : link_.settings.has_v6;
}

}  // namespace rmnet
