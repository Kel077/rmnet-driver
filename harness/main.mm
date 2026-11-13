// rmnet-harness: drives Core against the modem from userspace.
//
//   rmnet-harness probe [-v]                        find the QMI interface and exchange one CTL Sync
//   rmnet-harness connect [-v]                      bring a data connection up, print it, tear it down
//   rmnet-harness ping [-v] [-6] [-c COUNT] ADDRESS  bring it up and ping through QMAP on bulk
//
// Work runs on the main dispatch queue; each command ends by calling exit from it. connect and
// ping drive a Session from a 100 ms timer and call Session::stop() before exiting, so no call
// or client is left on the modem.
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "rmnet/ip.h"
#include "rmnet/qmap.h"
#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "rmnet/session.h"
#include "usb_transport.h"

namespace {

constexpr int64_t kSyncTimeoutSeconds = 10;
constexpr uint8_t kSyncTxid = 1;
constexpr int64_t kLinkTimeoutSeconds = 90;
constexpr uint64_t kTickMs = 100;
constexpr uint8_t kMuxId = 0x81;
constexpr int64_t kPingIntervalSeconds = 1;
constexpr uint64_t kPingWindowMs = 2000;  // a reply counts if it arrives within this of its request
constexpr size_t kPingDataLen = 56;
constexpr int kDefaultPingCount = 3;

// Never destroyed: exit runs from inside the transport's handlers.
UsbTransport& g_usb = *new UsbTransport;
bool g_verbose = false;

uint64_t now_ms() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000; }

void print_hex(const char* prefix, const uint8_t* p, size_t n) {
  printf("%s", prefix);
  for (size_t i = 0; i < n; i++) printf(" %02x", p[i]);
  printf("\n");
  fflush(stdout);
}

std::string ip4_text(const uint8_t a[4]) {
  char buf[INET_ADDRSTRLEN];
  return inet_ntop(AF_INET, a, buf, sizeof buf) ? buf : "?";
}

std::string ip6_text(const uint8_t a[16]) {
  char buf[INET6_ADDRSTRLEN];
  return inet_ntop(AF_INET6, a, buf, sizeof buf) ? buf : "?";
}

uint16_t be16(const uint8_t* p) { return (uint16_t)((p[0] << 8) | p[1]); }

// ---- Session plumbing shared by connect and ping ----

// Session callbacks must not call back into the session, so link changes are handed to the
// main queue and handled after the callback has returned.
class HarnessDelegate : public rmnet::SessionDelegate {
 public:
  std::function<void(const rmnet::LinkConfig&)> on_up;
  std::function<void()> on_down;

  void send_qmi(const uint8_t* data, size_t len) override {
    if (g_verbose) print_hex(">>", data, len);
    g_usb.send_control(data, len);  // a failure is logged; the session's timeout handles it
  }
  void link_up(const rmnet::LinkConfig& cfg) override {
    rmnet::LinkConfig copy = cfg;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (on_up) on_up(copy);
    });
  }
  void link_down() override {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (on_down) on_down();
    });
  }
};

HarnessDelegate& g_delegate = *new HarnessDelegate;
rmnet::Session* g_session = nullptr;
bool g_link_seen = false;
dispatch_source_t g_tick_timer = nil;
dispatch_source_t g_signal_sources[2] = {nil, nil};

// Stops the session (Stop Network and Release Client ID go out before this returns), closes the
// transport and exits. Never called from inside a Session callback.
[[noreturn]] void finish(int code) {
  fflush(stdout);
  if (g_session) g_session->stop();
  g_usb.close();
  exit(code);
}

int usage() {
  fprintf(stderr,
          "usage: rmnet-harness probe [-v]\n"
          "       rmnet-harness connect [-v]\n"
          "       rmnet-harness ping [-v] [-6] [-c COUNT] ADDRESS\n");
  return 2;
}

void open_or_exit() {
  std::string err;
  if (!g_usb.open(&err)) {
    fprintf(stderr, "open: %s\n", err.c_str());
    exit(1);
  }
}

// Ctrl-C and SIGTERM still tear the connection down.
void catch_signals() {
  const int sigs[2] = {SIGINT, SIGTERM};
  for (int i = 0; i < 2; i++) {
    signal(sigs[i], SIG_IGN);
    dispatch_source_t s =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{
      printf("interrupted\n");
      finish(1);
    });
    dispatch_resume(s);
    g_signal_sources[i] = s;
  }
}

// Opens the transport and starts a Session on it. on_up and on_down run on the main queue.
void run_session(std::function<void(const rmnet::LinkConfig&)> on_up,
                 std::function<void()> on_down) {
  open_or_exit();
  catch_signals();
  g_usb.set_error_handler([](const std::string& what) {
    printf("usb: %s\n", what.c_str());
    finish(1);
  });
  g_delegate.on_up = [on_up](const rmnet::LinkConfig& cfg) {
    g_link_seen = true;
    on_up(cfg);
  };
  g_delegate.on_down = std::move(on_down);

  rmnet::SessionConfig cfg;
  cfg.iface_number = g_usb.interface_number();
  cfg.mux_id = kMuxId;
  g_session = new rmnet::Session(cfg, g_delegate);

  g_usb.start_control([](const uint8_t* data, size_t len) {
    if (g_verbose) print_hex("<<", data, len);
    g_session->on_qmi(data, len, now_ms());
  });

  g_tick_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(g_tick_timer, dispatch_time(DISPATCH_TIME_NOW, kTickMs * NSEC_PER_MSEC),
                            kTickMs * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(g_tick_timer, ^{
    g_session->tick(now_ms());
  });
  dispatch_resume(g_tick_timer);

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLinkTimeoutSeconds * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   if (g_link_seen) return;
                   printf("no link after %lld s\n", (long long)kLinkTimeoutSeconds);
                   finish(1);
                 });

  g_session->start(now_ms());
}

// ---- probe ----

void probe() {
  open_or_exit();
  printf("interface %u, bulk in 0x%02x, bulk out 0x%02x, interrupt 0x%02x, packet size %zu, "
         "serial %s\n",
         g_usb.interface_number(), g_usb.bulk_in(), g_usb.bulk_out(), g_usb.interrupt_in(),
         g_usb.bulk_packet_size(), g_usb.serial().c_str());

  g_usb.start_control([](const uint8_t* data, size_t len) {
    if (g_verbose) print_hex("<<", data, len);
    rmnet::QmiMessage m;
    if (!rmnet::qmi_decode(rmnet::Span{data, len}, &m)) return;
    if (m.hdr.service != rmnet::QmiService::CTL || m.hdr.kind != rmnet::QmiKind::Response ||
        m.hdr.msg_id != rmnet::kCtlSync || m.hdr.txid != kSyncTxid) {
      return;
    }
    rmnet::QmiResult r = rmnet::qmi_result(m);
    if (r.present && r.ok) {
      printf("sync ok\n");
      finish(0);
    }
    printf("sync: error 0x%04x\n", r.present ? r.error : 0xffff);
    finish(1);
  });

  uint8_t req[32];
  size_t n = rmnet::build_ctl_sync(req, sizeof req, kSyncTxid);
  if (g_verbose) print_hex(">>", req, n);
  if (n == 0 || !g_usb.send_control(req, n)) {
    printf("sync: send failed\n");
    finish(1);
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kSyncTimeoutSeconds * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   printf("sync: no answer\n");
                   finish(1);
                 });
}

// ---- connect ----

void print_link(const rmnet::LinkConfig& cfg) {
  const rmnet::RuntimeSettings& s = cfg.settings;
  printf("link up\n");
  if (s.has_v4) {
    printf("ipv4 %s mask %s gateway %s\n", ip4_text(s.v4_addr).c_str(),
           ip4_text(s.v4_mask).c_str(), ip4_text(s.v4_gateway).c_str());
  } else {
    printf("ipv4 none\n");
  }
  if (s.has_v6) {
    printf("ipv6 %s/%u\n", ip6_text(s.v6_addr).c_str(), s.v6_prefix_len);
  } else {
    printf("ipv6 none\n");
  }
  printf("dns");
  for (uint8_t i = 0; i < s.v4_dns_count && i < 2; i++) printf(" %s", ip4_text(s.v4_dns[i]).c_str());
  for (uint8_t i = 0; i < s.v6_dns_count && i < 2; i++) printf(" %s", ip6_text(s.v6_dns[i]).c_str());
  printf("\n");
  printf("mtu %u\n", s.mtu);
  if (g_verbose) {
    const rmnet::DataFormat& f = cfg.format;
    printf("format: link layer %u, ul agg %u, dl agg %u, dl %u datagrams %u bytes, "
           "ul %u datagrams %u bytes\n",
           f.link_layer, f.ul_agg, f.dl_agg, f.dl_max_datagrams, f.dl_max_size,
           f.ul_max_datagrams, f.ul_max_size);
    if (s.has_v4) printf("ipv4 gateway %s\n", ip4_text(s.v4_gateway).c_str());
    if (s.has_v6) printf("ipv6 gateway %s\n", ip6_text(s.v6_gateway).c_str());
  }
  fflush(stdout);
}

void connect_cmd() {
  run_session([](const rmnet::LinkConfig& cfg) {
    print_link(cfg);
    finish(0);
  }, [] {});
}

// ---- ping ----

struct Ping {
  bool v6 = false;
  int count = kDefaultPingCount;
  uint8_t target[16] = {};
  std::string target_text;
  uint8_t source[16] = {};
  uint16_t id = 0;
  bool started = false;
  int sent = 0;
  int received = 0;
  std::vector<uint64_t> sent_ms;  // by sequence number
  std::vector<bool> answered;
  std::vector<uint8_t> uplink;  // one aggregated transfer, sized from the granted format
  std::unique_ptr<rmnet::QmapAggregator> aggregator;
  // Seen on the downlink, for -v.
  size_t transfers = 0, frames = 0, commands = 0, other_frames = 0;
};

Ping& g_ping = *new Ping;

[[noreturn]] void end_ping() {
  printf("%d sent, %d received\n", g_ping.sent, g_ping.received);
  if (g_verbose) {
    printf("downlink: %zu transfers, %zu frames, %zu command frames, %zu other data frames\n",
           g_ping.transfers, g_ping.frames, g_ping.commands, g_ping.other_frames);
  }
  finish(g_ping.received >= 1 ? 0 : 1);
}

void send_echo(uint16_t seq) {
  uint8_t data[kPingDataLen];
  for (size_t i = 0; i < kPingDataLen; i++) data[i] = (uint8_t)(0x08 + i);
  uint8_t pkt[40 + 8 + kPingDataLen];
  size_t n = g_ping.v6 ? rmnet::build_icmp6_echo(pkt, sizeof pkt, g_ping.source, g_ping.target,
                                                 g_ping.id, seq, data, sizeof data)
                       : rmnet::build_icmp4_echo(pkt, sizeof pkt, g_ping.source, g_ping.target,
                                                 g_ping.id, seq, data, sizeof data);
  g_ping.sent_ms[seq] = now_ms();
  g_ping.sent++;
  size_t len = 0;
  if (n > 0 && g_ping.aggregator->add(kMuxId, pkt, n)) len = g_ping.aggregator->finish();
  if (len == 0) {
    printf("seq=%u: request does not fit the uplink transfer\n", seq);
    return;
  }
  if (g_verbose) print_hex(">> bulk", g_ping.uplink.data(), len);
  if (!g_usb.write_bulk(g_ping.uplink.data(), len)) printf("seq=%u: bulk write failed\n", seq);
}

// Sends request `seq`, then schedules the next one a second later, or the end two seconds
// after the last.
void send_next(uint16_t seq) {
  send_echo(seq);
  if (seq + 1 < g_ping.count) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kPingIntervalSeconds * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ send_next((uint16_t)(seq + 1)); });
  } else {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kPingWindowMs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ end_ping(); });
  }
}

// An echo reply from the target carrying our identifier: returns true and its sequence number.
bool parse_echo_reply(const uint8_t* p, size_t n, uint16_t* seq) {
  const uint8_t* icmp;
  size_t icmp_len;
  if (!g_ping.v6) {
    if (n < 20 || (p[0] >> 4) != 4) return false;
    size_t ihl = (size_t)(p[0] & 0x0f) * 4;
    size_t total = be16(p + 2);
    if (ihl < 20 || total < ihl || total > n || p[9] != 1) return false;  // 1: ICMP
    if (memcmp(p + 12, g_ping.target, 4) != 0) return false;
    icmp = p + ihl;
    icmp_len = total - ihl;
    if (icmp_len < 8 || icmp[0] != 0 || icmp[1] != 0) return false;  // echo reply
    if (rmnet::fold_checksum(rmnet::sum16(icmp, icmp_len)) != 0) return false;
  } else {
    if (n < 40 || (p[0] >> 4) != 6 || p[6] != 58) return false;  // 58: ICMPv6, no ext headers
    size_t payload = be16(p + 4);
    if (40 + payload > n) return false;
    if (memcmp(p + 8, g_ping.target, 16) != 0) return false;
    icmp = p + 40;
    icmp_len = payload;
    if (icmp_len < 8 || icmp[0] != 129 || icmp[1] != 0) return false;  // echo reply
    if (rmnet::icmp6_checksum(p + 8, p + 24, icmp, icmp_len) != 0) return false;
  }
  if (be16(icmp + 4) != g_ping.id) return false;
  *seq = be16(icmp + 6);
  return true;
}

void on_data_frame(const rmnet::QmapFrame& f) {
  uint16_t seq;
  if (f.mux_id != kMuxId || !parse_echo_reply(f.payload.data, f.payload.len, &seq)) {
    g_ping.other_frames++;
    if (g_verbose) {
      print_hex("<< other frame:", f.payload.data, f.payload.len < 48 ? f.payload.len : 48);
    }
    return;
  }
  uint64_t now = now_ms();
  if (seq >= g_ping.sent_ms.size() || seq >= g_ping.sent || g_ping.answered[seq]) {
    if (g_verbose) printf("seq=%u: unexpected or duplicate reply\n", seq);
    return;
  }
  uint64_t rtt = now - g_ping.sent_ms[seq];
  if (rtt > kPingWindowMs) {
    if (g_verbose) printf("seq=%u: late reply after %llu ms\n", seq, (unsigned long long)rtt);
    return;
  }
  g_ping.answered[seq] = true;
  g_ping.received++;
  printf("reply from %s: seq=%u time=%llu ms\n", g_ping.target_text.c_str(), seq,
         (unsigned long long)rtt);
  fflush(stdout);
}

void on_command_frame(const rmnet::QmapFrame& f) {
  g_ping.commands++;
  rmnet::QmapCommand cmd = {};
  bool parsed = rmnet::qmap_parse_command(f.payload, &cmd);
  if (g_verbose) {
    printf("<< command frame mux 0x%02x name %u type %u%s\n", f.mux_id, cmd.name, cmd.type,
           parsed ? "" : " (unparsed)");
    print_hex("<< command payload:", f.payload.data, f.payload.len);
  }
  if (!parsed || cmd.type != rmnet::kQmapCmdRequest) return;
  // A buffer of its own: the reply must not overlap the request payload.
  uint8_t reply[256];
  size_t n = rmnet::qmap_build_command_reply(reply, sizeof reply, f.mux_id, f.payload);
  if (n == 0) {
    printf("qmap: command %u too long to answer\n", cmd.name);
    return;
  }
  if (g_verbose) print_hex(">> command reply:", reply, n);
  if (!g_usb.write_bulk(reply, n)) printf("qmap: command reply failed\n");
}

void on_transfer(const uint8_t* data, size_t len) {
  g_ping.transfers++;
  if (g_verbose) {
    printf("<< bulk transfer %zu bytes\n", len);
    if (len <= 16) print_hex("<< bulk", data, len);
  }
  rmnet::Span buf{data, len};
  size_t off = 0;
  for (;;) {
    rmnet::QmapFrame f;
    size_t at = off;
    rmnet::QmapStatus st = rmnet::qmap_next(buf, &off, &f);
    if (st == rmnet::QmapStatus::End) break;
    if (st != rmnet::QmapStatus::Ok) {
      printf("qmap: %s frame at offset %zu of a %zu-byte transfer\n",
             st == rmnet::QmapStatus::Truncated ? "truncated" : "malformed", at, len);
      break;
    }
    g_ping.frames++;
    if (f.is_command) {
      on_command_frame(f);
    } else {
      on_data_frame(f);
    }
  }
}

void ping_link_up(const rmnet::LinkConfig& cfg) {
  if (g_ping.started) return;
  g_ping.started = true;
  const rmnet::RuntimeSettings& s = cfg.settings;
  if (g_ping.v6 ? !s.has_v6 : !s.has_v4) {
    printf("link up without an %s address\n", g_ping.v6 ? "IPv6" : "IPv4");
    finish(1);
  }
  if (g_ping.v6) {
    memcpy(g_ping.source, s.v6_addr, 16);
  } else {
    memcpy(g_ping.source, s.v4_addr, 4);
  }
  printf("link up, ping %s from %s\n", g_ping.target_text.c_str(),
         g_ping.v6 ? ip6_text(g_ping.source).c_str() : ip4_text(g_ping.source).c_str());
  if (g_verbose) {
    const rmnet::DataFormat& f = cfg.format;
    printf("format: dl %u datagrams %u bytes, ul %u datagrams %u bytes\n", f.dl_max_datagrams,
           f.dl_max_size, f.ul_max_datagrams, f.ul_max_size);
  }
  fflush(stdout);

  g_ping.uplink.assign(cfg.format.ul_max_size, 0);
  g_ping.aggregator.reset(new rmnet::QmapAggregator(g_ping.uplink.data(), g_ping.uplink.size(),
                                                    cfg.format.ul_max_datagrams,
                                                    g_usb.bulk_packet_size()));
  g_ping.sent_ms.assign(g_ping.count, 0);
  g_ping.answered.assign(g_ping.count, false);
  g_usb.start_bulk(cfg.format.dl_max_size, on_transfer);
  send_next(0);
}

void ping_cmd() {
  g_ping.id = (uint16_t)(getpid() & 0xffff);
  run_session(ping_link_up, [] {
    if (!g_ping.started) return;
    printf("link down\n");
    end_ping();
  });
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return usage();
  std::string cmd = argv[1];
  bool have_target = false;
  for (int i = 2; i < argc; i++) {
    const char* a = argv[i];
    if (strcmp(a, "-v") == 0) {
      g_verbose = true;
    } else if (cmd == "ping" && strcmp(a, "-6") == 0) {
      g_ping.v6 = true;
    } else if (cmd == "ping" && strcmp(a, "-c") == 0 && i + 1 < argc) {
      char* end = nullptr;
      long c = strtol(argv[++i], &end, 10);
      if (!end || *end != '\0' || c < 1 || c > 65535) return usage();
      g_ping.count = (int)c;
    } else if (cmd == "ping" && a[0] != '-' && !have_target) {
      have_target = true;
      g_ping.target_text = a;
    } else {
      return usage();
    }
  }
  if (cmd == "probe") {
    dispatch_async(dispatch_get_main_queue(), ^{ probe(); });
  } else if (cmd == "connect") {
    dispatch_async(dispatch_get_main_queue(), ^{ connect_cmd(); });
  } else if (cmd == "ping") {
    if (!have_target) return usage();
    if (inet_pton(g_ping.v6 ? AF_INET6 : AF_INET, g_ping.target_text.c_str(), g_ping.target) != 1) {
      fprintf(stderr, "ping: %s is not an IPv%d address\n", g_ping.target_text.c_str(),
              g_ping.v6 ? 6 : 4);
      return 2;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ ping_cmd(); });
  } else {
    return usage();
  }
  dispatch_main();
}
