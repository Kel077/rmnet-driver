// The check RMNetDriver makes before it opens an interface as the modem's QMI interface.
//
// A personality matches the QMI interface by product and interface number. In the modem's QMI USB
// configuration that number is the QMI function's, but in another configuration (MBIM, ECM, a
// DIAG port switched off) it can belong to another function, so before anything is opened
// RMNetDriver checks the interface itself, by the rule the Linux kernel's qmi_wwan applies to
// Quectel modems (drivers/net/usb/qmi_wwan.c, QMI_MATCH_FF_FF_FF and qmi_wwan_probe): class,
// subclass and protocol 0xff, and not the DIAG function, which can have the same class, subclass
// and protocol but has two bulk endpoints only. Here the endpoints must be exactly the QMI
// function's three: one interrupt IN (QMI indications), one bulk IN and one bulk OUT (data).
#pragma once

#include <stdint.h>

namespace rmnet {

// The endpoints an interface has: its descriptor's bNumEndpoints, and its endpoint descriptors
// counted by kind.
struct QmiEndpoints {
  uint8_t total;
  uint8_t interrupt_in;
  uint8_t bulk_in;
  uint8_t bulk_out;
};

enum class QmiInterfaceFault : uint8_t {
  None,       // the QMI interface
  Class,      // class, subclass or protocol not 0xff (checked first)
  Endpoints,  // not exactly three endpoints, one interrupt IN, one bulk IN and one bulk OUT
};

QmiInterfaceFault qmi_interface_fault(uint8_t iface_class, uint8_t subclass, uint8_t protocol,
                                      const QmiEndpoints& eps);

}  // namespace rmnet
