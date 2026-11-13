// Drives Core's QMI session for the driver: plain C++, run on the driver's Default queue.
//
// It owns the Session and the EthernetEmulator, sends the session's QMI messages through UsbIo,
// and logs the session's progress. Link changes are only recorded while Core is running; the
// driver applies them after the Core call returns (take_link_change), so nothing it does can
// re-enter the Session from a delegate callback.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/ethernet.h"
#include "rmnet/session.h"

class UsbIo;

class CoreHost final : public rmnet::SessionDelegate {
 public:
  CoreHost(UsbIo& usb, const rmnet::MacPair& macs);
  CoreHost(const CoreHost&) = delete;
  CoreHost& operator=(const CoreHost&) = delete;

  void start(uint64_t now_ms);
  void stop();
  void tick(uint64_t now_ms);
  void on_control(const uint8_t* data, size_t len, uint64_t now_ms);  // one QMUX frame

  // Link changes since the last call, in the order to apply them: down first (the link went
  // down), then up (the link is up with link_config(); also a family added while already up).
  struct LinkChange {
    bool down;
    bool up;
  };
  LinkChange take_link_change();
  const rmnet::LinkConfig& link_config() const { return link_; }

  rmnet::SessionState state() const { return session_.state(); }
  rmnet::EthernetEmulator& ethernet() { return eth_; }

  // SessionDelegate: called by the session from inside start, stop, on_qmi and tick.
  void send_qmi(const uint8_t* data, size_t len) override;
  void link_up(const rmnet::LinkConfig& cfg) override;
  void link_down() override;

 private:
  void note_state();
  void log_sent(const uint8_t* data, size_t len);
  void log_received(const uint8_t* data, size_t len);
  uint8_t family_of(uint8_t wds_client) const;

  UsbIo& usb_;
  rmnet::Session session_;
  rmnet::EthernetEmulator eth_;
  rmnet::SessionState logged_state_;
  rmnet::LinkConfig link_;
  LinkChange change_;
  uint32_t syncs_sent_;
  // The IP family (4 or 6) each WDS client asked for in Start Network, for the log.
  uint8_t start_client_[2];
  bool start_client_known_[2];
};

const char* SessionStateName(rmnet::SessionState s);
