#include "rmnet/serial_port.h"

namespace rmnet {

namespace {

// Letters, digits, '-' and '_' only: never '/', '.', a space or a non-ASCII byte.
bool tty_name_char(char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
         c == '-' || c == '_';
}

}  // namespace

bool serial_interface_matches(uint8_t iface_class, uint8_t subclass, uint8_t protocol,
                              uint64_t want_subclass, uint64_t want_protocol) {
  // Comparing at 64 bits keeps a wanted value above 255 from matching its low 8 bits.
  return iface_class == 0xff && uint64_t{subclass} == want_subclass &&
         uint64_t{protocol} == want_protocol;
}

bool tty_name_ok(const char* name) {
  if (name == nullptr) return false;
  for (size_t i = 0; i <= kTtyNameMax; ++i) {
    if (name[i] == '\0') return i > 0;
    if (!tty_name_char(name[i])) return false;
  }
  return false;  // kTtyNameMax + 1 characters with no NUL among them: too long
}

}  // namespace rmnet
