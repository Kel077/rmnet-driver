// CoreHost on the host: a fake UsbPort and RxSink stand in for the driver's USB and receive packets.
// The tests cover the transmit hold (a frame refused while every uplink buffer is in flight), the
// kept QMAP command replies, and the pause limit (kPauseMaxMs).
#include "minitest.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>
#include <vector>

#include "captures.h"
#include "core_host.h"
#include "frames.h"
#include "rmnet/ethernet.h"
#include "rmnet/qmap.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "rmnet/session.h"

namespace {

// kUplinkSlots buffers in memory. Each send_uplink payload and release_uplink slot is recorded.
// all_busy is the switch that makes every buffer look in flight: acquire_uplink gives none.
class FakeUsb final : public UsbPort {
 public:
  struct Sent {
    int slot;
    std::vector<uint8_t> bytes;
  };
  bool all_busy = false;
  std::vector<Sent> uplinks;                // send_uplink, in the order sent
  std::vector<int> releases;                // release_uplink
  std::vector<std::vector<uint8_t>> qmi;    // send
  std::vector<uint32_t> bulk_starts;        // start_bulk

  // The transfer from `slot` completed: its buffer is free again. The test then tells CoreHost
  // (on_bulk_out_done), as the driver does.
  void complete(int slot) { state_[slot] = Free; }

  bool send(const uint8_t* data, size_t len) override {
    qmi.emplace_back(data, data + len);
    return true;
  }
  void start_bulk(uint32_t read_len) override { bulk_starts.push_back(read_len); }
  int acquire_uplink() override {
    if (all_busy) return -1;
    for (int i = 0; i < static_cast<int>(kUplinkSlots); i++) {
      if (state_[i] == Free) {
        state_[i] = Reserved;
        return i;
      }
    }
    return -1;
  }
  uint8_t* uplink_buffer(int slot) const override { return buffers_.get() + static_cast<size_t>(slot) * kMaxUplink; }
  bool send_uplink(int slot, uint32_t len) override {
    const uint8_t* b = uplink_buffer(slot);
    uplinks.push_back({slot, std::vector<uint8_t>(b, b + len)});
    state_[slot] = InFlight;
    return true;
  }
  void release_uplink(int slot) override {
    releases.push_back(slot);
    state_[slot] = Free;
  }
  bool uplink_recovering() const override { return false; }
  uint16_t bulk_out_packet_size() const override { return 512; }

 private:
  enum State { Free, Reserved, InFlight };
  State state_[kUplinkSlots] = {};
  std::unique_ptr<uint8_t[]> buffers_{new uint8_t[kUplinkSlots * kMaxUplink]()};
};

// One receive packet, always available; every frame committed is recorded.
class FakeRx final : public RxSink {
 public:
  std::vector<std::vector<uint8_t>> frames;
  uint8_t* rx_buffer(size_t* cap) override {
    *cap = sizeof buf_;
    return buf_;
  }
  void rx_commit(size_t len) override { frames.emplace_back(buf_, buf_ + len); }

 private:
  uint8_t buf_[2048];
};

// The link the recorded IPv4 call came up with: its Get Current Settings reply and the modem's Set
// Data Format answer (QMAP both ways, 16384-byte uplink transfers of up to 32 datagrams).
rmnet::LinkConfig recorded_link() {
  rmnet::LinkConfig cfg{};
  std::vector<uint8_t> settings = hex(kWdsSettings4Resp);
  std::vector<uint8_t> format = hex(kWdaSetFormatResp);
  rmnet::QmiMessage m{};
  bool ok = rmnet::qmi_decode({settings.data(), settings.size()}, &m) &&
            rmnet::parse_wds_current_settings(m, &cfg.settings) &&
            rmnet::qmi_decode({format.data(), format.size()}, &m) && rmnet::parse_wda_data_format(m, &cfg.format);
  if (!ok || !cfg.settings.has_v4 || cfg.settings.has_v6 || !rmnet::data_format_usable(cfg.format)) {
    fprintf(stderr, "recorded_link(): the recorded replies do not give a usable IPv4 link\n");
    abort();
  }
  return cfg;
}

// CoreHost over the fakes, its data link brought up as the driver brings it up: the session's
// link_up, then take_link_change and data_link_up. The session itself is never started.
struct Rig {
  FakeUsb usb;
  FakeRx rx;
  CoreHost core;

  Rig() : core(usb, rx, rmnet::derive_macs("bfeed1a5"), 1, true) {
    core.link_up(recorded_link());
    CoreHost::LinkChange c = core.take_link_change();
    CHECK(c.up);
    CHECK(!c.down);
    core.data_link_up(0);
    CHECK_EQ(usb.bulk_starts.size(), 1u);
  }
  void transmit_ok(const std::vector<uint8_t>& f) { CHECK(core.transmit(f.data(), f.size())); }
  bool transmit(const std::vector<uint8_t>& f) { return core.transmit(f.data(), f.size()); }
  void bulk_in(const std::vector<uint8_t>& t) { core.on_bulk_in(t.data(), t.size()); }
  // The transfer from `slot` completed, as the driver reports it.
  void complete(int slot) {
    usb.complete(slot);
    core.on_bulk_out_done(slot, true);
  }
  // The transfers that held every buffer while all_busy was set complete: CoreHost hears of one
  // (the last slot, which the tests that use this never fill themselves).
  void free_buffers() {
    usb.all_busy = false;
    core.on_bulk_out_done(static_cast<int>(kUplinkSlots) - 1, true);
  }
};

// An Ethernet frame from the host to the router carrying a unicast IPv4 UDP datagram; `tag` is its
// one payload byte.
std::vector<uint8_t> host_frame(uint8_t tag) { return ipv4_udp("10.102.246.230", "8.8.8.8", 40000, 53, {tag}); }

// The IP packet inside a frame host_frame made (no Ethernet padding).
std::vector<uint8_t> ip_of(const std::vector<uint8_t>& frame) { return {frame.begin() + 14, frame.end()}; }

// The IP packets the uplink transfers carried, in the order sent.
std::vector<std::vector<uint8_t>> sent_packets(const FakeUsb& usb) {
  std::vector<std::vector<uint8_t>> out;
  for (const FakeUsb::Sent& t : usb.uplinks) {
    size_t off = 0;
    rmnet::QmapFrame f;
    while (rmnet::qmap_next({t.bytes.data(), t.bytes.size()}, &off, &f) == rmnet::QmapStatus::Ok) {
      if (!f.is_command) out.emplace_back(f.payload.data, f.payload.data + f.payload.len);
    }
  }
  return out;
}

// A QMAP flow control request from the modem on mux 0x81 (as in test_qmap.cpp), `tag` its last byte.
std::vector<uint8_t> flow_request(uint8_t name, uint8_t tag) {
  return {0x80, 0x81, 0x00, 0x08, name, rmnet::kQmapCmdRequest, 0x00, 0x00, 0x00, 0x00, 0x00, tag};
}

}  // namespace

TEST(transmit_is_refused_while_every_uplink_buffer_is_in_flight_and_the_same_frame_goes_through_later) {
  Rig r;
  std::vector<uint8_t> f = host_frame(1);
  r.usb.all_busy = true;
  CHECK(!r.transmit(f));
  CHECK(!r.transmit(f));  // offered again while still busy: the same answer
  DataCounters none{};
  CHECK(memcmp(&r.core.counters(), &none, sizeof none) == 0);
  CHECK(r.usb.uplinks.empty());

  r.free_buffers();
  r.transmit_ok(f);
  CHECK(r.usb.uplinks.empty());  // in the open buffer until the queue is empty
  r.core.flush_uplink();
  REQUIRE(r.usb.uplinks.size() == 1u);
  std::vector<std::vector<uint8_t>> sent = sent_packets(r.usb);
  REQUIRE(sent.size() == 1u);
  CHECK(sent[0] == ip_of(f));

  r.complete(r.usb.uplinks[0].slot);
  CHECK_EQ(r.core.counters().tx_packets, 1u);
  CHECK_EQ(r.core.counters().tx_bytes, ip_of(f).size());
}

TEST(frames_reach_the_modem_in_the_order_offered) {
  Rig r;
  std::vector<uint8_t> first = host_frame(1), second = host_frame(2), third = host_frame(3);
  r.transmit_ok(first);
  r.core.flush_uplink();  // the queue ran empty: the first frame's transfer is in flight
  r.usb.all_busy = true;
  CHECK(!r.transmit(second));  // the driver keeps it ...
  r.usb.all_busy = false;
  REQUIRE(r.usb.uplinks.size() == 1u);
  r.complete(r.usb.uplinks[0].slot);  // ... until the first frame's transfer completes ...
  r.transmit_ok(second);              // ... and offers it again before the third
  r.transmit_ok(third);
  r.core.flush_uplink();
  std::vector<std::vector<uint8_t>> sent = sent_packets(r.usb);
  REQUIRE(sent.size() == 3u);
  CHECK(sent[0] == ip_of(first));
  CHECK(sent[1] == ip_of(second));
  CHECK(sent[2] == ip_of(third));
}

TEST(a_command_reply_is_kept_while_no_buffer_is_free_and_sent_on_the_next_completion) {
  Rig r;
  r.usb.all_busy = true;
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 0x2a));
  CHECK_EQ(r.core.kept_replies(), 1u);
  CHECK(r.usb.uplinks.empty());

  r.free_buffers();
  CHECK_EQ(r.core.kept_replies(), 0u);
  REQUIRE(r.usb.uplinks.size() == 1u);
  CHECK_BYTES(r.usb.uplinks[0].bytes, "80 81 00 08 01 01 00 00 00 00 00 2a");  // the ACK
  CHECK_EQ(r.core.counters().command_replies, 1u);
  CHECK_EQ(r.core.counters().command_reply_drops, 0u);
}

TEST(at_most_four_replies_are_kept_and_the_fifth_counts_as_a_reply_drop) {
  Rig r;
  r.usb.all_busy = true;
  for (uint8_t tag = 1; tag <= 5; tag++) r.bulk_in(flow_request(rmnet::kQmapFlowDisable, tag));
  CHECK_EQ(r.core.kept_replies(), 4u);
  CHECK_EQ(r.core.counters().commands, 5u);
  CHECK_EQ(r.core.counters().command_reply_drops, 1u);

  // The four kept go out oldest first once buffers are free; the fifth never does.
  r.free_buffers();
  CHECK_EQ(r.core.kept_replies(), 0u);
  REQUIRE(r.usb.uplinks.size() == 4u);
  for (size_t i = 0; i < 4; i++) CHECK_EQ(r.usb.uplinks[i].bytes.back(), i + 1);
  CHECK_EQ(r.core.counters().command_replies, 4u);
}

TEST(kept_replies_are_dropped_and_counted_on_link_down) {
  Rig r;
  r.usb.all_busy = true;
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 1));
  r.bulk_in(flow_request(rmnet::kQmapFlowEnable, 2));
  CHECK_EQ(r.core.kept_replies(), 2u);

  r.core.link_down();  // the session reports it; the driver applies it after the Core call
  CHECK(r.core.take_link_change().down);
  r.core.data_link_down();
  CHECK_EQ(r.core.kept_replies(), 0u);
  CHECK_EQ(r.core.counters().command_reply_drops, 2u);

  r.free_buffers();
  r.core.data_tick(1000);
  CHECK(r.usb.uplinks.empty());
  CHECK_EQ(r.core.counters().command_replies, 0u);
}

TEST(a_pause_past_kPauseMaxMs_asks_for_one_restart) {
  Rig r;
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 1));
  REQUIRE(r.core.uplink_paused());
  r.core.data_tick(1000);  // the first tick that sees the pause times it
  r.core.data_tick(1000 + kPauseMaxMs - 1);
  CHECK(!r.core.take_restart_wanted());
  r.core.data_tick(1000 + kPauseMaxMs);
  CHECK(r.core.take_restart_wanted());
  CHECK(!r.core.take_restart_wanted());
  r.core.data_tick(1000 + 2 * kPauseMaxMs);  // the same pause asks only once
  CHECK(!r.core.take_restart_wanted());
  CHECK_EQ(r.core.counters().uplink_pause_timeouts, 1u);
}

TEST(restart_lifts_the_pause_and_drops_the_kept_replies) {
  Rig r;
  r.usb.all_busy = true;
  r.bulk_in(flow_request(rmnet::kQmapFlowDisable, 1));
  REQUIRE(r.core.uplink_paused());
  REQUIRE(r.core.kept_replies() == 1u);

  r.core.restart(5000);
  CHECK(!r.core.uplink_paused());
  CHECK(r.core.take_uplink_resumed());
  CHECK_EQ(r.core.kept_replies(), 0u);
  CHECK_EQ(r.core.counters().command_reply_drops, 1u);
  CHECK(!r.usb.qmi.empty());  // the new session's first sync
}
