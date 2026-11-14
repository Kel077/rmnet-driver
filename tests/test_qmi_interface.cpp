// The check RMNetDriver makes before it opens an interface as the modem's QMI interface: class,
// subclass and protocol 0xff, and exactly one interrupt IN, one bulk IN and one bulk OUT endpoint.
// The descriptors are the RM520N-GL's (I/O registry and the harness captures) and those in the
// Linux kernel's commits for other Quectel modems.
#include "minitest.h"

#include "rmnet/qmi_interface.h"

namespace {

// total endpoints, then interrupt IN, bulk IN, bulk OUT.
rmnet::QmiEndpoints eps(uint8_t total, uint8_t interrupt_in, uint8_t bulk_in, uint8_t bulk_out) {
  return rmnet::QmiEndpoints{total, interrupt_in, bulk_in, bulk_out};
}

}  // namespace

TEST(qmi_interface_takes_the_rm520n_gl_interface_4) {
  // ff/ff/ff, bNumEndpoints 3: bulk in 0x8e, bulk out 0x0f, interrupt in 0x88.
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(3, 1, 1, 1)) == rmnet::QmiInterfaceFault::None);
}

TEST(qmi_interface_refuses_other_classes) {
  using rmnet::QmiInterfaceFault;
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0x30, eps(2, 0, 1, 1)) == QmiInterfaceFault::Class);  // DIAG
  CHECK(rmnet::qmi_interface_fault(0xff, 0x00, 0x40, eps(3, 1, 1, 1)) == QmiInterfaceFault::Class);  // NMEA
  CHECK(rmnet::qmi_interface_fault(0xff, 0x00, 0x00, eps(3, 1, 1, 1)) == QmiInterfaceFault::Class);  // AT
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0x50, eps(3, 1, 1, 1)) == QmiInterfaceFault::Class);  // RG255C's QMI
  CHECK(rmnet::qmi_interface_fault(0x02, 0x0e, 0x00, eps(1, 1, 0, 0)) == QmiInterfaceFault::Class);  // MBIM control
  CHECK(rmnet::qmi_interface_fault(0x0a, 0x00, 0x00, eps(2, 0, 1, 1)) == QmiInterfaceFault::Class);  // CDC data
}

TEST(qmi_interface_refuses_a_diag_port_with_the_qmi_class) {
  // EC25, EP06, EM12: DIAG is ff/ff/ff with two bulk endpoints (option.c's NUMEP2).
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(2, 0, 1, 1)) == rmnet::QmiInterfaceFault::Endpoints);
}

TEST(qmi_interface_wants_one_endpoint_of_each_kind_and_no_more) {
  using rmnet::QmiInterfaceFault;
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(3, 0, 2, 1)) == QmiInterfaceFault::Endpoints);
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(3, 1, 1, 0)) == QmiInterfaceFault::Endpoints);
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(3, 2, 1, 0)) == QmiInterfaceFault::Endpoints);
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(4, 1, 1, 1)) == QmiInterfaceFault::Endpoints);
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0xff, eps(0, 0, 0, 0)) == QmiInterfaceFault::Endpoints);
}

TEST(qmi_interface_names_the_class_first) {
  // Both wrong: the class is the reason given.
  CHECK(rmnet::qmi_interface_fault(0xff, 0xff, 0x30, eps(2, 0, 1, 1)) == rmnet::QmiInterfaceFault::Class);
}
