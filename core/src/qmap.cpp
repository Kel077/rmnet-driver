#include "rmnet/qmap.h"

#include <string.h>

namespace rmnet {

namespace {

constexpr size_t kHeaderLen = 4;
constexpr uint8_t kCommandFlag = 0x80;
constexpr uint8_t kPadMask = 0x3f;
constexpr size_t kMaxLength = 0xffff;   // largest value of the length field
constexpr size_t kMinCommandLen = 8;
constexpr uint8_t kCommandTypeMask = 0x03;

bool all_zero(const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    if (p[i] != 0) return false;
  }
  return true;
}

uint8_t pad_for(size_t len) { return static_cast<uint8_t>((4 - len % 4) % 4); }

void put_header(uint8_t* hdr, bool command, uint8_t pad, uint8_t mux_id, size_t length) {
  hdr[0] = static_cast<uint8_t>((command ? kCommandFlag : 0) | (pad & kPadMask));
  hdr[1] = mux_id;
  hdr[2] = static_cast<uint8_t>(length >> 8);
  hdr[3] = static_cast<uint8_t>(length);
}

}  // namespace

QmapStatus qmap_next(Span buf, size_t* offset, QmapFrame* out) {
  if (*offset >= buf.len) return QmapStatus::End;
  const uint8_t* p = buf.data + *offset;
  const size_t remaining = buf.len - *offset;

  if (remaining < kHeaderLen) {
    return all_zero(p, remaining) ? QmapStatus::End : QmapStatus::Truncated;
  }
  if (all_zero(p, kHeaderLen)) return QmapStatus::End;

  const uint8_t pad = p[0] & kPadMask;
  const size_t length = (static_cast<size_t>(p[2]) << 8) | p[3];
  if (length == 0 || pad > length) return QmapStatus::Bad;
  if (length > remaining - kHeaderLen) return QmapStatus::Truncated;

  out->mux_id = p[1];
  out->is_command = (p[0] & kCommandFlag) != 0;
  out->payload = {p + kHeaderLen, length - pad};
  *offset += kHeaderLen + length;
  return QmapStatus::Ok;
}

uint8_t qmap_write_header(uint8_t hdr[4], bool command, uint8_t mux_id, size_t payload_len) {
  const uint8_t pad = pad_for(payload_len);
  put_header(hdr, command, pad, mux_id, payload_len + pad);
  return pad;
}

QmapAggregator::QmapAggregator(uint8_t* buf, size_t cap, size_t max_datagrams,
                               size_t usb_packet_size)
    : buf_(buf),
      cap_(cap),
      max_datagrams_(max_datagrams),
      usb_packet_size_(usb_packet_size),
      size_(0),
      count_(0),
      last_header_(0) {}

bool QmapAggregator::add(uint8_t mux_id, const uint8_t* ip, size_t len) {
  if (len == 0 || count_ >= max_datagrams_) return false;
  const size_t pad = pad_for(len);
  // The length field must still hold the extra four bytes finish() may add.
  if (len > kMaxLength - pad - 4) return false;
  const size_t frame = kHeaderLen + len + pad;
  if (cap_ < size_ || frame + 4 > cap_ - size_) return false;

  uint8_t* hdr = buf_ + size_;
  qmap_write_header(hdr, false, mux_id, len);
  memcpy(hdr + kHeaderLen, ip, len);
  memset(hdr + kHeaderLen + len, 0, pad);
  last_header_ = size_;
  size_ += frame;
  ++count_;
  return true;
}

size_t QmapAggregator::count() const { return count_; }

size_t QmapAggregator::finish() {
  if (count_ == 0) return 0;
  size_t n = size_;
  if (usb_packet_size_ != 0 && n % usb_packet_size_ == 0) {
    uint8_t* hdr = buf_ + last_header_;
    const uint8_t pad = static_cast<uint8_t>((hdr[0] & kPadMask) + 4);
    const size_t length = ((static_cast<size_t>(hdr[2]) << 8) | hdr[3]) + 4;
    put_header(hdr, false, pad, hdr[1], length);
    memset(buf_ + n, 0, 4);  // add() reserved these four bytes
    n += 4;
  }
  size_ = 0;
  count_ = 0;
  last_header_ = 0;
  return n;
}

bool qmap_parse_command(Span payload, QmapCommand* out) {
  if (payload.len < kMinCommandLen) return false;
  out->name = payload.data[0];
  out->type = payload.data[1] & kCommandTypeMask;
  return true;
}

size_t qmap_build_command_reply(uint8_t* out, size_t cap, uint8_t mux_id, Span request_payload) {
  QmapCommand cmd;
  if (!qmap_parse_command(request_payload, &cmd)) return 0;
  const size_t len = request_payload.len;
  const size_t pad = pad_for(len);
  if (len > kMaxLength - pad) return 0;
  const size_t total = kHeaderLen + len + pad;
  if (total > cap) return 0;

  const uint8_t type = (cmd.name == kQmapFlowDisable || cmd.name == kQmapFlowEnable)
                           ? kQmapCmdAck
                           : kQmapCmdUnsupported;
  qmap_write_header(out, true, mux_id, len);
  uint8_t* payload = out + kHeaderLen;
  memcpy(payload, request_payload.data, len);
  payload[1] = static_cast<uint8_t>((payload[1] & ~kCommandTypeMask) | type);
  memset(payload + len, 0, pad);
  return total;
}

}  // namespace rmnet
