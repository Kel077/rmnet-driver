#include "rmnet/qmi_interface.h"

namespace rmnet {

QmiInterfaceFault qmi_interface_fault(uint8_t iface_class, uint8_t subclass, uint8_t protocol,
                                      const QmiEndpoints& eps) {
  if (iface_class != 0xff || subclass != 0xff || protocol != 0xff) return QmiInterfaceFault::Class;
  if (eps.total != 3 || eps.interrupt_in != 1 || eps.bulk_in != 1 || eps.bulk_out != 1) {
    return QmiInterfaceFault::Endpoints;
  }
  return QmiInterfaceFault::None;
}

}  // namespace rmnet
