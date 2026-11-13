#include "rmnet/qmi.h"

namespace rmnet {

namespace {

constexpr uint8_t kQmuxMarker = 0x01;
constexpr uint8_t kQmuxFlagsHost = 0x00;
constexpr size_t kQmuxLengthOffset = 1;  // u16le after the marker, counting itself onward
constexpr uint8_t kTlvResult = 0x02;     // libqmi: "Result"

// Wire values of the QMI header's kind byte.
constexpr uint8_t kCtlRequest = 0x00;     // QMI_CTL_FLAG_REQUEST
constexpr uint8_t kCtlResponse = 0x01;    // QMI_CTL_FLAG_RESPONSE
constexpr uint8_t kCtlIndication = 0x02;  // QMI_CTL_FLAG_INDICATION
constexpr uint8_t kSvcRequest = 0x00;     // QMI_SERVICE_FLAG_NONE
constexpr uint8_t kSvcResponse = 0x02;    // QMI_SERVICE_FLAG_RESPONSE
constexpr uint8_t kSvcIndication = 0x04;  // QMI_SERVICE_FLAG_INDICATION

bool kind_from_wire(bool ctl, uint8_t b, QmiKind* kind) {
  if (b == (ctl ? kCtlRequest : kSvcRequest)) {
    *kind = QmiKind::Request;
  } else if (b == (ctl ? kCtlResponse : kSvcResponse)) {
    *kind = QmiKind::Response;
  } else if (b == (ctl ? kCtlIndication : kSvcIndication)) {
    *kind = QmiKind::Indication;
  } else {
    return false;
  }
  return true;
}

uint8_t kind_to_wire(bool ctl, QmiKind kind) {
  switch (kind) {
    case QmiKind::Response:
      return ctl ? kCtlResponse : kSvcResponse;
    case QmiKind::Indication:
      return ctl ? kCtlIndication : kSvcIndication;
    case QmiKind::Request:
      break;
  }
  return ctl ? kCtlRequest : kSvcRequest;
}

// Walks one TLV; false once the chain is exhausted or a TLV overruns it.
bool next_tlv(Reader* r, uint8_t* type, Span* value) {
  if (r->remaining() == 0) return false;
  *type = r->u8();
  uint16_t len = r->u16le();
  *value = r->take(len);
  return r->ok();
}

}  // namespace

bool qmi_decode(Span frame, QmiMessage* out) {
  Reader r(frame.data, frame.len);
  uint8_t marker = r.u8();
  uint16_t qmux_len = r.u16le();  // counts itself and everything after it
  if (!r.ok() || marker != kQmuxMarker || qmux_len < 2 || r.remaining() < qmux_len - 2u) {
    return false;
  }
  Reader q(frame.data + 1 + 2, qmux_len - 2u);

  QmiHeader hdr;
  q.u8();  // flags
  hdr.service = static_cast<QmiService>(q.u8());
  hdr.client = q.u8();
  bool ctl = hdr.service == QmiService::CTL;
  if (!kind_from_wire(ctl, q.u8(), &hdr.kind)) return false;
  hdr.txid = ctl ? q.u8() : q.u16le();
  hdr.msg_id = q.u16le();
  uint16_t tlv_len = q.u16le();
  if (!q.ok() || q.remaining() != tlv_len) return false;
  Span tlvs = q.take(tlv_len);

  Reader chain(tlvs.data, tlvs.len);
  uint8_t type;
  Span value;
  while (next_tlv(&chain, &type, &value)) {
  }
  if (!chain.ok()) return false;

  out->hdr = hdr;
  out->tlvs = tlvs;
  return true;
}

bool qmi_find_tlv(Span tlvs, uint8_t type, Span* value) {
  Reader r(tlvs.data, tlvs.len);
  uint8_t t;
  Span v;
  while (next_tlv(&r, &t, &v)) {
    if (t == type) {
      *value = v;
      return true;
    }
  }
  return false;
}

QmiResult qmi_result(const QmiMessage& m) {
  QmiResult res = {false, false, 0};
  Span v;
  if (m.hdr.kind != QmiKind::Response || !qmi_find_tlv(m.tlvs, kTlvResult, &v) || v.len < 4) {
    return res;
  }
  Reader r(v.data, v.len);
  uint16_t status = r.u16le();  // QMI_STATUS_SUCCESS is 0
  res.present = true;
  res.error = r.u16le();
  res.ok = status == 0;
  return res;
}

QmiBuilder::QmiBuilder(uint8_t* buf, size_t cap, const QmiHeader& hdr)
    : w_(buf, cap), tlv_start_(0), ok_(true) {
  bool ctl = hdr.service == QmiService::CTL;
  w_.u8(kQmuxMarker);
  w_.u16le(0);  // QMUX length, patched by finish()
  w_.u8(kQmuxFlagsHost);
  w_.u8(static_cast<uint8_t>(hdr.service));
  w_.u8(hdr.client);
  w_.u8(kind_to_wire(ctl, hdr.kind));
  if (ctl) {
    w_.u8(static_cast<uint8_t>(hdr.txid));
  } else {
    w_.u16le(hdr.txid);
  }
  w_.u16le(hdr.msg_id);
  w_.u16le(0);  // TLV length, patched by finish()
  tlv_start_ = w_.size();
}

void QmiBuilder::tlv(uint8_t type, const uint8_t* value, size_t n) {
  if (n > 0xFFFF) ok_ = false;
  if (!ok_) return;
  w_.u8(type);
  w_.u16le(static_cast<uint16_t>(n));
  w_.bytes(value, n);
}

void QmiBuilder::tlv_u8(uint8_t type, uint8_t v) { tlv(type, &v, 1); }

void QmiBuilder::tlv_u32(uint8_t type, uint32_t v) {
  const uint8_t b[4] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8),
                        static_cast<uint8_t>(v >> 16), static_cast<uint8_t>(v >> 24)};
  tlv(type, b, sizeof b);
}

size_t QmiBuilder::finish() {
  size_t total = w_.size();
  if (!ok_ || !w_.ok() || total - 1 > 0xFFFF) return 0;
  w_.patch_u16le(kQmuxLengthOffset, static_cast<uint16_t>(total - 1));
  w_.patch_u16le(tlv_start_ - 2, static_cast<uint16_t>(total - tlv_start_));
  return w_.ok() ? total : 0;
}

}  // namespace rmnet
