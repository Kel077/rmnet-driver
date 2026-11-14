// The connection state machine: brings a QMI data connection up, keeps it up, tears it down.
//
// It does no I/O. The host hands it every received QMI frame and the current time, calls
// tick() at least every 250 ms, and receives requests to send and link changes through a
// SessionDelegate. It never blocks, sleeps or allocates.
//
// Bring-up, one request outstanding at a time: CTL Sync; CTL Get Client ID for WDA; WDA Set
// Data Format; then for IPv4 and then IPv6: CTL Get Client ID for WDS, WDS Bind Mux Data Port,
// Set IP Family, Start Network, Get Current Settings. link_up() follows the last family if at
// least one family has settings. Failures and timeouts go to Backoff, which redials from Sync.
//
// Up with one family missing, the session retries that family while the link stays up:
// kFamilyRetryFirstMs after link_up(), then after each failed or timed-out retry a wait twice the
// last, capped at kFamilyRetryMaxMs. A retry reuses the family's WDS client (Start Network, Get
// Current Settings; first Bind Mux and Set IP Family if those failed at bring-up), or, if it has
// none, starts from Get Client ID. A retry whose call drops before its settings arrive fails. A
// retry due while Refreshing waits until the session is Up again.
//
// Up, the session also probes the modem: kLivenessIntervalMs after link_up() (a link_up() that
// only adds a retried family does not restart the wait) and after each answered probe, it sends
// WDS Get Current Settings on the first live family, IPv4 first. Any response to it is an answer,
// whatever its result; its contents are ignored. No answer within kRequestTimeoutMs takes the
// link down and goes to Backoff. A probe and a retry never run together: whichever falls due
// while the other is outstanding waits, and when both are due the retry goes first. A
// packet-service-status indication that takes the link down or starts a refresh abandons the
// probe; a late answer to it is then ignored.
//
// Refreshing, a reconfigure indication for the other family is remembered, and that family is
// refreshed after the current one, before the link comes back up.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"

namespace rmnet {

struct SessionConfig {
  uint32_t iface_number = 4;
  uint8_t mux_id = 0x81;
  uint8_t profile = 1;
};

struct LinkConfig {
  RuntimeSettings settings;
  DataFormat format;
};

// The session calls these from inside start(), stop(), on_qmi() and tick(). A callback must not
// call back into the Session (start, stop, on_qmi or tick): the session is part-way through a
// transition when it calls out. To stop from a callback, record the wish and call stop() after
// the session call returns. (As a safeguard, a session stopped from inside link_down() stays
// Idle, but nothing else about re-entry is defined.)
//
// link_up() can be called again while the link is up, without link_down() between: the settings
// gained a family that a retry brought up, and cfg holds both families.
class SessionDelegate {
 public:
  virtual void send_qmi(const uint8_t* data, size_t len) = 0;
  virtual void link_up(const LinkConfig& cfg) = 0;
  virtual void link_down() = 0;

 protected:
  ~SessionDelegate() = default;
};

enum class SessionState : uint8_t { Idle, Syncing, Configuring, Connecting, Up, Refreshing, Backoff };

enum : uint32_t {
  kSyncResendMs = 2000,
  kSyncGiveUpMs = 60000,
  kRequestTimeoutMs = 10000,
  kStartNetworkTimeoutMs = 60000,
};

enum : uint32_t { kFamilyRetryFirstMs = 5000, kFamilyRetryMaxMs = 60000 };   // 5 s, 10 s, 20 s, 40 s, then 60 s

// How long a modem that goes silent while Up can go unnoticed: normally about 40 s from the last
// answered probe (the interval, then the probe's kRequestTimeoutMs). With one family missing, a
// retry outstanding as the modem goes silent delays the probe, since only one request is
// outstanding at a time and a retry that times out keeps the link up: a retry sent just before the
// probe falls due waits up to kStartNetworkTimeoutMs, then the probe goes on the next tick and
// waits kRequestTimeoutMs, so about 100 s from the moment the modem goes silent. Counted from the
// last answered probe it can be about 130 s, when the retry has to re-run its earlier steps (Get
// Client ID, Bind Mux, Set IP Family) with slow answers before its Start Network. No second retry
// can start first: the next one waits at least kFamilyRetryFirstMs
// (silent_modem_during_a_retry_is_noticed_after_the_retry_times_out).
enum : uint32_t { kLivenessIntervalMs = 30000 };

class Session {
 public:
  Session(const SessionConfig& cfg, SessionDelegate& delegate);

  void start(uint64_t now_ms);  // Idle -> Syncing; ignored in any other state
  // Stops started calls and releases clients without waiting for answers, then -> Idle.
  // Calls link_down() if the link was up. The backoff returns to its first wait, so a session
  // started again begins as a fresh one.
  void stop();
  void on_qmi(const uint8_t* data, size_t len, uint64_t now_ms);
  void tick(uint64_t now_ms);  // the host calls this at least every 250 ms
  SessionState state() const;

 private:
  // What the outstanding request is, so its response goes to the right handler.
  enum class Step : uint8_t { Sync, GetWdaClient, SetDataFormat, GetWdsClient, Bind, IpFamily, Start, Settings,
                              Probe };

  struct Pending {
    bool active;
    Step step;
    QmiService service;
    uint8_t client;
    uint16_t txid;
    uint16_t msg_id;
    uint64_t sent_ms;
    uint32_t timeout_ms;
  };

  // One WDS client per IP family: index 0 is IPv4, index 1 is IPv6.
  struct Family {
    bool has_client;
    uint8_t client;
    bool configured;  // the client is bound to the mux and has its IP family set
    bool has_handle;  // false also when Start Network answered NoEffect
    uint32_t handle;
    bool live;  // Start Network succeeded (or answered NoEffect) and no disconnect followed
  };

  uint8_t next_ctl_txid();
  uint16_t next_txid();
  void expect(Step step, QmiService service, uint8_t client, uint16_t txid, uint16_t msg_id,
              size_t len, uint64_t now_ms, uint32_t timeout_ms);
  void transmit(size_t len);

  void begin_sync(uint64_t now_ms);
  void send_sync(uint64_t now_ms);
  void begin_family(uint8_t index, uint64_t now_ms);
  void send_bind(uint64_t now_ms);
  void send_start(uint64_t now_ms);
  void send_settings(uint64_t now_ms);
  void tick_up(uint64_t now_ms);
  void send_probe(uint64_t now_ms);
  void family_done(uint64_t now_ms);
  void schedule_retry(uint64_t now_ms);
  void begin_retry(uint64_t now_ms);
  void retry_done(uint64_t now_ms);
  void cancel_retry();
  void finish_bring_up(uint64_t now_ms);
  void enter_backoff(uint64_t now_ms);
  void teardown();
  void reset_clients();
  void clear_family_settings(uint8_t index);
  bool family_has_settings(uint8_t index) const;

  void on_response(const QmiMessage& m, uint64_t now_ms);
  void on_indication(const QmiMessage& m, uint64_t now_ms);

  SessionConfig cfg_;
  SessionDelegate& delegate_;
  SessionState state_;
  uint8_t ctl_txid_;  // next CTL transaction ID; never 0
  uint16_t txid_;     // next transaction ID shared by WDA and WDS; never 0
  Pending pending_;
  uint64_t sync_started_ms_;
  uint64_t backoff_started_ms_;
  uint32_t backoff_wait_ms_;  // the wait of the current Backoff
  uint32_t next_backoff_ms_;  // the wait of the next Backoff
  bool has_wda_client_;
  uint8_t wda_client_;
  Family families_[2];
  uint8_t current_;  // family being brought up or refreshed
  bool link_is_up_;  // link_up() was reported and link_down() has not followed
  LinkConfig link_;
  // Retrying the missing family while Up. At most one of retry_due_ and retrying_ is true.
  bool retry_due_;               // a retry starts once retry_wait_ms_ has passed since retry_from_ms_
  bool retrying_;                // a retry request is outstanding; current_ is the missing family
  uint64_t retry_from_ms_;
  uint32_t retry_wait_ms_;
  uint32_t next_retry_wait_ms_;  // the wait after the next failed retry
  uint64_t probe_from_ms_;       // Up: the next probe is due kLivenessIntervalMs after this
  bool refresh_other_;           // Refreshing: the other family asked for a refresh too
  uint8_t buf_[128];  // every request the session builds fits
};

}  // namespace rmnet
