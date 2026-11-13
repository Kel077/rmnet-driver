#include "core_host.h"

#include <os/log.h>

#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "usb_io.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "RMNet: " fmt, ##__VA_ARGS__)

namespace {

constexpr uint8_t kTlvStartFamily = 0x19;  // WDS Start Network "IP Family Preference"
constexpr uint8_t kFamilyV4 = 4;
constexpr uint8_t kFamilyV6 = 6;

const char* ServiceName(rmnet::QmiService s) {
  switch (s) {
    case rmnet::QmiService::CTL:
      return "CTL";
    case rmnet::QmiService::WDS:
      return "WDS";
    case rmnet::QmiService::WDA:
      return "WDA";
  }
  return "?";
}

uint8_t PrefixLength(const uint8_t mask[4]) {
  uint8_t n = 0;
  for (int i = 0; i < 4; i++) {
    for (int b = 7; b >= 0; b--) {
      if (mask[i] & (1u << b)) n++;
    }
  }
  return n;
}

}  // namespace

const char* SessionStateName(rmnet::SessionState s) {
  switch (s) {
    case rmnet::SessionState::Idle:
      return "idle";
    case rmnet::SessionState::Syncing:
      return "syncing";
    case rmnet::SessionState::Configuring:
      return "configuring";
    case rmnet::SessionState::Connecting:
      return "connecting";
    case rmnet::SessionState::Up:
      return "up";
    case rmnet::SessionState::Refreshing:
      return "refreshing";
    case rmnet::SessionState::Backoff:
      return "backoff";
  }
  return "?";
}

CoreHost::CoreHost(UsbIo& usb, const rmnet::MacPair& macs)
    : usb_(usb),
      session_(rmnet::SessionConfig{}, *this),
      eth_(macs),
      logged_state_(rmnet::SessionState::Idle),
      link_(),
      change_{false, false},
      syncs_sent_(0),
      start_client_(),
      start_client_known_() {}

void CoreHost::start(uint64_t now_ms) {
  session_.start(now_ms);
  note_state();
}

void CoreHost::stop() {
  session_.stop();
  note_state();
}

void CoreHost::tick(uint64_t now_ms) {
  session_.tick(now_ms);
  note_state();
}

void CoreHost::on_control(const uint8_t* data, size_t len, uint64_t now_ms) {
  log_received(data, len);
  session_.on_qmi(data, len, now_ms);
  note_state();
}

CoreHost::LinkChange CoreHost::take_link_change() {
  LinkChange c = change_;
  change_ = {false, false};
  return c;
}

void CoreHost::send_qmi(const uint8_t* data, size_t len) {
  log_sent(data, len);
  if (!usb_.send(data, len)) LOG("qmi message of %zu bytes not sent", len);
}

void CoreHost::link_up(const rmnet::LinkConfig& cfg) {
  link_ = cfg;
  change_.up = true;
}

void CoreHost::link_down() {
  change_.down = true;
  change_.up = false;
}

// One line per state change: this is where backoff and the return to syncing show.
void CoreHost::note_state() {
  rmnet::SessionState s = session_.state();
  if (s == logged_state_) return;
  if (logged_state_ == rmnet::SessionState::Syncing && s == rmnet::SessionState::Configuring) {
    LOG("sync answered after %u sent", syncs_sent_);
  }
  LOG("session %{public}s -> %{public}s", SessionStateName(logged_state_), SessionStateName(s));
  logged_state_ = s;
}

uint8_t CoreHost::family_of(uint8_t wds_client) const {
  for (int i = 0; i < 2; i++) {
    if (start_client_known_[i] && start_client_[i] == wds_client) return i == 0 ? kFamilyV4 : kFamilyV6;
  }
  return 0;
}

// Logs every request the session sends: service, client, message and transaction ID.
void CoreHost::log_sent(const uint8_t* data, size_t len) {
  rmnet::QmiMessage m;
  if (!rmnet::qmi_decode(rmnet::Span{data, len}, &m)) {
    LOG("qmi tx %zu bytes (undecodable)", len);
    return;
  }
  if (m.hdr.service == rmnet::QmiService::CTL && m.hdr.msg_id == rmnet::kCtlSync) {
    // The state is logged after the session call returns, so a first sync finds it not Syncing.
    if (logged_state_ != rmnet::SessionState::Syncing) syncs_sent_ = 0;
    syncs_sent_++;
    LOG("sync sent (%u)", syncs_sent_);
    return;
  }
  if (m.hdr.service == rmnet::QmiService::WDS && m.hdr.msg_id == rmnet::kWdsStartNetwork) {
    rmnet::Span v;
    uint8_t family = 0;
    if (rmnet::qmi_find_tlv(m.tlvs, kTlvStartFamily, &v) && v.len == 1) family = v.data[0];
    if (family == kFamilyV4 || family == kFamilyV6) {
      int i = family == kFamilyV4 ? 0 : 1;
      start_client_[i] = m.hdr.client;
      start_client_known_[i] = true;
    }
    LOG("call IPv%u: start network (client %u)", family, m.hdr.client);
    return;
  }
  LOG("qmi tx %{public}s client %u msg 0x%04x txid %u", ServiceName(m.hdr.service), m.hdr.client, m.hdr.msg_id,
      m.hdr.txid);
}

// Logs every message from the modem, and the meaning of the ones that mark progress.
void CoreHost::log_received(const uint8_t* data, size_t len) {
  rmnet::QmiMessage m;
  if (!rmnet::qmi_decode(rmnet::Span{data, len}, &m)) {
    LOG("qmi rx %zu bytes (undecodable)", len);
    return;
  }
  rmnet::QmiResult r = rmnet::qmi_result(m);
  const char* kind = m.hdr.kind == rmnet::QmiKind::Indication ? "ind" : "resp";
  LOG("qmi rx %{public}s %{public}s client %u msg 0x%04x txid %u result %{public}s 0x%x", ServiceName(m.hdr.service), kind,
      m.hdr.client, m.hdr.msg_id, m.hdr.txid, !r.present ? "-" : (r.ok ? "ok" : "error"), r.error);
  if (m.hdr.kind != rmnet::QmiKind::Response) return;

  if (m.hdr.service == rmnet::QmiService::WDA && m.hdr.msg_id == rmnet::kWdaSetDataFormat) {
    rmnet::DataFormat f;
    if (rmnet::parse_wda_data_format(m, &f)) {
      LOG("data format: link layer %u, ul agg %u (%u datagrams, %u bytes), dl agg %u (%u datagrams, %u bytes), "
          "usable %d",
          f.link_layer, f.ul_agg, f.ul_max_datagrams, f.ul_max_size, f.dl_agg, f.dl_max_datagrams, f.dl_max_size,
          rmnet::data_format_usable(f));
    } else {
      LOG("data format refused (error 0x%x)", r.error);
    }
  } else if (m.hdr.service == rmnet::QmiService::WDS && m.hdr.msg_id == rmnet::kWdsStartNetwork) {
    uint32_t handle = 0;
    rmnet::CallEnd end;
    bool ok = rmnet::parse_wds_start_network(m, &handle, &end);
    unsigned family = family_of(m.hdr.client);
    if (ok) {
      LOG("call IPv%u: connected", family);
    } else {
      LOG("call IPv%u: failed, error 0x%x, end reason %u, verbose %u/%u", family, r.error, end.reason,
          end.verbose_type, end.verbose_reason);
    }
  } else if (m.hdr.service == rmnet::QmiService::WDS && m.hdr.msg_id == rmnet::kWdsGetCurrentSettings) {
    rmnet::RuntimeSettings s{};
    if (rmnet::parse_wds_current_settings(m, &s)) {
      LOG("settings IPv%u: v4 %d (/%u, %u dns), v6 %d (/%u, %u dns), mtu %u", family_of(m.hdr.client), s.has_v4,
          s.has_v4 ? PrefixLength(s.v4_mask) : 0, s.v4_dns_count, s.has_v6, s.v6_prefix_len, s.v6_dns_count, s.mtu);
    }
  }
}
