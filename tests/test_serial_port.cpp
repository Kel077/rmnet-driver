// The checks RMNetSerial makes before it takes an interface: the interface's class, subclass and
// protocol are the serial port's, and the port's name is a safe TTY base name.
#include "minitest.h"

#include "rmnet/serial_port.h"

TEST(serial_interface_matches_diag_and_nmea) {
  CHECK(rmnet::serial_interface_matches(0xff, 0xff, 0x30, 255, 48));
  CHECK(rmnet::serial_interface_matches(0xff, 0x00, 0x40, 0, 64));
}

TEST(serial_interface_refuses_at_and_qmi) {
  CHECK(!rmnet::serial_interface_matches(0xff, 0x00, 0x00, 0, 64));    // AT, interfaces 2 and 3
  CHECK(!rmnet::serial_interface_matches(0xff, 0xff, 0xff, 255, 48));  // QMI, interface 4
  CHECK(!rmnet::serial_interface_matches(0xff, 0x00, 0x00, 255, 48));
}

TEST(serial_interface_refuses_other_class_and_out_of_range_wants) {
  CHECK(!rmnet::serial_interface_matches(0x02, 0xff, 0x30, 255, 48));
  CHECK(!rmnet::serial_interface_matches(0xff, 0xff, 0x30, 255 + 256, 48));
  CHECK(!rmnet::serial_interface_matches(0xff, 0xff, 0x30, 255, 48 + 256));
}

TEST(tty_name_ok_accepts_port_names) {
  CHECK(rmnet::tty_name_ok("RM520N-GL-NMEA"));
  CHECK(rmnet::tty_name_ok("RM520N-GL-DIAG"));
  CHECK(rmnet::tty_name_ok("a_1"));
  CHECK(rmnet::tty_name_ok("abcdefghijklmnopqrstuvwxyz01234"));  // 31
}

TEST(tty_name_ok_refuses_bad_names) {
  CHECK(!rmnet::tty_name_ok(nullptr));
  CHECK(!rmnet::tty_name_ok(""));
  CHECK(!rmnet::tty_name_ok("abcdefghijklmnopqrstuvwxyz012345"));  // 32
  CHECK(!rmnet::tty_name_ok("a b"));
  CHECK(!rmnet::tty_name_ok("a/b"));
  CHECK(!rmnet::tty_name_ok("a.b"));
  CHECK(!rmnet::tty_name_ok("caf\xc3\xa9"));
}
