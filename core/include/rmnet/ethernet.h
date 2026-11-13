// Ethernet emulation over the modem's raw-IP link. macOS sees an Ethernet
// interface; the emulator adds and removes Ethernet headers and plays the
// router on the other end of the link, answering ARP itself.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/bytes.h"
#include "rmnet/qmi_msgs.h"

namespace rmnet {

// Locally administered unicast MACs for the host interface and the emulated router.
struct MacPair {
  uint8_t host[6];
  uint8_t router[6];
};

// Stable for a given USB serial number; host and router differ only in the last bit.
MacPair derive_macs(const char* usb_serial);

enum class TxAction : uint8_t { Forward, Reply, Drop };

// Forward: ip is the packet inside the frame (points into the frame).
// Reply: reply_len bytes were written to the reply buffer.
struct TxResult {
  TxAction action;
  Span ip;
  size_t reply_len;
};

class EthernetEmulator {
 public:
  explicit EthernetEmulator(const MacPair& macs);

  // Copies *settings; nullptr means the link is down.
  void set_link(const RuntimeSettings* settings);

  // Wraps a packet from the modem in an Ethernet header, router to host.
  // Returns the frame length, or 0 if the packet is to be dropped.
  size_t wrap_rx(const uint8_t* ip, size_t len, uint8_t* out, size_t cap);

  // Decides what to do with a frame the host sent.
  TxResult handle_tx(const uint8_t* frame, size_t len, uint8_t* reply, size_t reply_cap);

  // Unsolicited IPv6 router advertisement. Not implemented yet: returns 0.
  size_t make_router_advert(uint8_t* out, size_t cap);

 private:
  // One handler per EtherType; each receives the payload after the Ethernet header.
  TxResult tx_ipv4(const uint8_t* frame, const uint8_t* payload, size_t len, uint8_t* reply, size_t cap);
  TxResult tx_ipv6(const uint8_t* frame, const uint8_t* payload, size_t len, uint8_t* reply, size_t cap);
  TxResult tx_arp(const uint8_t* frame, const uint8_t* payload, size_t len, uint8_t* reply, size_t cap);

  // Writes an Ethernet header from the router to `dst`; returns 14.
  size_t write_header(uint8_t* out, const uint8_t dst[6], uint16_t ethertype) const;

  MacPair macs_;
  RuntimeSettings link_;
  bool link_up_;
};

}  // namespace rmnet
