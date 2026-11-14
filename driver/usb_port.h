// The USB interface CoreHost is written against, and the bulk sizes both sides share. Free of
// DriverKit, so CoreHost also builds on the host (tests/driver/test_core_host.cpp, make driver-test).
#pragma once

#include <stddef.h>
#include <stdint.h>

enum : uint32_t {
  kBulkReads = 32,       // bulk IN reads kept posted
  kUplinkSlots = 8,      // bulk OUT buffers
  kMaxDownlink = 31744,  // the largest downlink transfer Core accepts (data_format_usable)
  kMaxUplink = 16384,    // the largest uplink transfer Core accepts
};

// What CoreHost needs from USB. UsbIo implements it on the driver; tests implement it on the host.
class UsbPort {
 public:
  // Queues one SEND_ENCAPSULATED_COMMAND; messages go out one at a time, in order. False if the
  // message is too long, the ring is full, or UsbIo is stopping.
  virtual bool send(const uint8_t* data, size_t len) = 0;
  // Bulk IN: posts every idle read, each `read_len` bytes (rounded up to the endpoint's packet
  // size, at most kMaxDownlink). Later re-posts use the newest length. Reads keep being re-posted
  // until finish_sending. A read that cannot be posted is fatal.
  virtual void start_bulk(uint32_t read_len) = 0;
  // Bulk OUT. acquire_uplink reserves a free buffer and returns its slot, or -1 when all are in
  // use; uplink_buffer gives its kMaxUplink bytes. send_uplink sends `len` bytes from a reserved
  // slot (false if it could not be submitted; the slot is then free again); release_uplink frees
  // a reserved slot unsent. Nothing is sent once finish_sending has been called.
  virtual int acquire_uplink() = 0;
  virtual uint8_t* uplink_buffer(int slot) const = 0;
  virtual bool send_uplink(int slot, uint32_t len) = 0;
  virtual void release_uplink(int slot) = 0;
  // Bulk OUT is recovering from a stall: acquire_uplink gives no buffer meanwhile.
  virtual bool uplink_recovering() const = 0;
  virtual uint16_t bulk_out_packet_size() const = 0;  // from the endpoint descriptor
 protected:
  ~UsbPort() = default;
};
