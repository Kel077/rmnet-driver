// QMUX framing of QMI messages and their TLVs.
//
// Frame: u8 0x01 (QMUX marker); u16le length of everything after the marker
// (the length field included); u8 flags
// (0x00 from the host, 0x80 from the modem); u8 service; u8 client. Then the QMI header:
// for CTL, u8 kind (0 request, 1 response, 2 indication) and u8 transaction ID; for other
// services, u8 kind (0 request, 2 response, 4 indication) and u16le transaction ID. Then
// u16le message ID, u16le TLV length, and TLVs as u8 type, u16le length, value.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/bytes.h"

namespace rmnet {

enum class QmiService : uint8_t {
  CTL = 0x00,  // QMI_SERVICE_CTL
  WDS = 0x01,  // QMI_SERVICE_WDS
  WDA = 0x1A,  // QMI_SERVICE_WDA
};

enum class QmiKind : uint8_t { Request, Response, Indication };

struct QmiHeader {
  QmiService service;
  uint8_t client;
  QmiKind kind;
  uint16_t txid;  // CTL transaction IDs are 8 bits on the wire
  uint16_t msg_id;
};

struct QmiMessage {
  QmiHeader hdr;
  Span tlvs;  // points into the decoded frame
};

// Total length of the QMUX frame at the start of buf (1 + its declared length), or 0 if buf does not
// start with a complete frame. Checks only the marker, that the declared length covers the QMUX
// header, and that buf holds the whole frame; qmi_decode checks the rest.
size_t qmi_frame_length(Span buf);

// Decodes one QMUX frame. Returns false if the frame is malformed, shorter than its length
// field says, or its TLV chain does not exactly fill the TLV length. Bytes after the length
// the frame declares are ignored.
bool qmi_decode(Span frame, QmiMessage* out);

// Finds the first TLV of `type` in a TLV chain. Stops at the first malformed TLV.
bool qmi_find_tlv(Span tlvs, uint8_t type, Span* value);

struct QmiResult {
  bool present;  // the message is a response and carries a well-formed result TLV
  bool ok;
  uint16_t error;  // QmiProtocolError
};

// Reads the result TLV (0x02) of a response: u16le status (0 success), u16le error.
QmiResult qmi_result(const QmiMessage& m);

// Builds one QMUX frame from the host into the caller's buffer.
class QmiBuilder {
 public:
  QmiBuilder(uint8_t* buf, size_t cap, const QmiHeader& hdr);

  void tlv(uint8_t type, const uint8_t* value, size_t n);
  void tlv_u8(uint8_t type, uint8_t v);
  void tlv_u32(uint8_t type, uint32_t v);  // little-endian

  size_t finish();  // total frame length; 0 on overflow

 private:
  Writer w_;
  size_t tlv_start_;  // offset of the first TLV
  bool ok_;
};

}  // namespace rmnet
