// rmnet-harness: drives Core against the modem from userspace.
//
//   rmnet-harness probe [-v]   find the QMI interface and exchange one CTL Sync
//
// Work runs on the main dispatch queue; each command ends by calling exit from it.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>

#include "rmnet/qmi.h"
#include "rmnet/qmi_msgs.h"
#include "usb_transport.h"

namespace {

constexpr int64_t kSyncTimeoutSeconds = 10;
constexpr uint8_t kSyncTxid = 1;

// Never destroyed: exit runs from inside the transport's handlers.
UsbTransport& g_usb = *new UsbTransport;
bool g_verbose = false;

void print_hex(const char* prefix, const uint8_t* p, size_t n) {
  printf("%s", prefix);
  for (size_t i = 0; i < n; i++) printf(" %02x", p[i]);
  printf("\n");
  fflush(stdout);
}

[[noreturn]] void finish(int code) {
  fflush(stdout);
  g_usb.close();
  exit(code);
}

int usage() {
  fprintf(stderr, "usage: rmnet-harness probe [-v]\n");
  return 2;
}

void probe() {
  std::string err;
  if (!g_usb.open(&err)) {
    fprintf(stderr, "open: %s\n", err.c_str());
    exit(1);
  }
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

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return usage();
  std::string cmd = argv[1];
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "-v") == 0) {
      g_verbose = true;
    } else {
      return usage();
    }
  }
  if (cmd == "probe") {
    dispatch_async(dispatch_get_main_queue(), ^{ probe(); });
  } else {
    return usage();
  }
  dispatch_main();
}
