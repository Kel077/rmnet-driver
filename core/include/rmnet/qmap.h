// QMAP (rmnet MAP) framing: the header that carries IP packets and command
// frames between the host and the modem over USB, uplink aggregation and
// flow-control command replies.
//
// Header, four bytes:
//   byte 0: bit 7 command flag, low six bits pad length
//   byte 1: mux ID
//   bytes 2-3: big-endian length of payload plus padding
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/bytes.h"

namespace rmnet {

// One frame inside a received transfer.
struct QmapFrame {
  uint8_t mux_id;
  bool is_command;
  Span payload;  // padding already removed; points into the caller's buffer
};

enum class QmapStatus : uint8_t {
  Ok,         // *out holds the next frame and *offset has moved past it
  End,        // no more frames: buffer end, or all-zero filler
  Truncated,  // the header or payload runs past the buffer end
  Bad,        // the header is malformed (zero length, or pad longer than length)
};

// Reads the frame at *offset. Advances *offset only on Ok.
QmapStatus qmap_next(Span buf, size_t* offset, QmapFrame* out);

// Writes a header for payload_len bytes padded to a multiple of four and
// returns the pad length (0..3). The caller keeps payload_len + pad <= 0xffff.
uint8_t qmap_write_header(uint8_t hdr[4], bool command, uint8_t mux_id, size_t payload_len);

// Packs uplink packets into one USB transfer in a caller-owned buffer.
class QmapAggregator {
 public:
  QmapAggregator(uint8_t* buf, size_t cap, size_t max_datagrams, size_t usb_packet_size);

  // Appends one frame. False if it will not fit (or len is 0); the caller
  // sends finish() first. Always keeps four spare bytes for finish().
  bool add(uint8_t mux_id, const uint8_t* ip, size_t len);
  size_t count() const;
  // Transfer length, 0 if empty; then empty again. Never an exact multiple
  // of usb_packet_size: the last frame's padding grows by four instead.
  size_t finish();

 private:
  uint8_t* buf_;
  size_t cap_;
  size_t max_datagrams_;
  size_t usb_packet_size_;
  size_t size_;
  size_t count_;
  size_t last_header_;  // offset of the last frame's header
};

enum : uint8_t { kQmapFlowDisable = 1, kQmapFlowEnable = 2 };
enum : uint8_t { kQmapCmdRequest = 0, kQmapCmdAck = 1, kQmapCmdUnsupported = 2 };

// Command payload: byte 0 is the command name, the low two bits of byte 1 the type.
struct QmapCommand {
  uint8_t name;
  uint8_t type;
};

// payload must be at least 8 bytes.
bool qmap_parse_command(Span payload, QmapCommand* out);

// Writes a command frame answering request_payload: the same payload with the
// type set to ACK for flow disable and flow enable, UNSUPPORTED otherwise.
// Returns the frame length, or 0 if the request is shorter than 8 bytes or
// the frame does not fit in cap. `out` must not overlap request_payload: the
// payload is copied with memcpy, so answering in place is undefined behaviour.
size_t qmap_build_command_reply(uint8_t* out, size_t cap, uint8_t mux_id, Span request_payload);

}  // namespace rmnet
