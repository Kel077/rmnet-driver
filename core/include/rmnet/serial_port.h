// The checks RMNetSerial makes before it takes an interface as a serial port.
//
// The serial personalities match the modem's USB interfaces by number (0 for DIAG, 1 for NMEA).
// A number alone could name an AT or QMI interface after a USB configuration change (switching
// DIAG off, for example, renumbers the rest), so before anything is opened RMNetSerial checks
// that the interface's class is vendor-specific (0xff) and that its subclass and protocol are the
// ones its personality names. It also checks that the personality's port name is safe to use as
// the TTY base name of /dev/cu.<name> and /dev/tty.<name>.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace rmnet {

// The longest port name tty_name_ok accepts, so a name and its NUL fit in kTtyNameMax + 1 bytes.
enum : size_t { kTtyNameMax = 31 };

// True only when iface_class is 0xff and subclass and protocol equal want_subclass and
// want_protocol. A wanted value above 255 never matches; it is not truncated to 8 bits.
bool serial_interface_matches(uint8_t iface_class, uint8_t subclass, uint8_t protocol,
                              uint64_t want_subclass, uint64_t want_protocol);

// True when name is not null and is 1 to kTtyNameMax characters, each A-Z, a-z, 0-9, '-' or '_',
// followed by a NUL. Reads at most kTtyNameMax + 1 bytes of name.
bool tty_name_ok(const char* name);

}  // namespace rmnet
