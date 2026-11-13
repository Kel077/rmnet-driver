#include "rmnet/bytes.h"

#include <string.h>

namespace rmnet {

// ---- Reader ----

Reader::Reader(const uint8_t* data, size_t len) : data_(data), len_(len), pos_(0), ok_(true) {}

bool Reader::ok() const { return ok_; }

size_t Reader::remaining() const { return ok_ ? len_ - pos_ : 0; }

const uint8_t* Reader::claim(size_t n) {
  if (!ok_ || n > len_ - pos_) {
    ok_ = false;
    return nullptr;
  }
  const uint8_t* p = data_ + pos_;
  pos_ += n;
  return p;
}

uint8_t Reader::u8() {
  const uint8_t* p = claim(1);
  return p ? p[0] : 0;
}

uint16_t Reader::u16le() {
  const uint8_t* p = claim(2);
  return p ? static_cast<uint16_t>(p[0] | p[1] << 8) : 0;
}

uint32_t Reader::u32le() {
  const uint8_t* p = claim(4);
  if (!p) return 0;
  return static_cast<uint32_t>(p[0]) | static_cast<uint32_t>(p[1]) << 8 |
         static_cast<uint32_t>(p[2]) << 16 | static_cast<uint32_t>(p[3]) << 24;
}

uint16_t Reader::u16be() {
  const uint8_t* p = claim(2);
  return p ? static_cast<uint16_t>(p[0] << 8 | p[1]) : 0;
}

uint32_t Reader::u32be() {
  const uint8_t* p = claim(4);
  if (!p) return 0;
  return static_cast<uint32_t>(p[0]) << 24 | static_cast<uint32_t>(p[1]) << 16 |
         static_cast<uint32_t>(p[2]) << 8 | static_cast<uint32_t>(p[3]);
}

Span Reader::take(size_t n) {
  const uint8_t* p = claim(n);
  return p ? Span{p, n} : Span{nullptr, 0};
}

void Reader::skip(size_t n) { claim(n); }

// ---- Writer ----

Writer::Writer(uint8_t* buf, size_t cap) : buf_(buf), cap_(cap), size_(0), ok_(true) {}

bool Writer::ok() const { return ok_; }

size_t Writer::size() const { return ok_ ? size_ : 0; }

uint8_t* Writer::claim(size_t n) {
  if (!ok_ || n > cap_ - size_) {
    ok_ = false;
    return nullptr;
  }
  uint8_t* p = buf_ + size_;
  size_ += n;
  return p;
}

void Writer::u8(uint8_t v) {
  if (uint8_t* p = claim(1)) p[0] = v;
}

void Writer::u16le(uint16_t v) {
  if (uint8_t* p = claim(2)) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
  }
}

void Writer::u32le(uint32_t v) {
  if (uint8_t* p = claim(4)) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
    p[2] = static_cast<uint8_t>(v >> 16);
    p[3] = static_cast<uint8_t>(v >> 24);
  }
}

void Writer::u16be(uint16_t v) {
  if (uint8_t* p = claim(2)) {
    p[0] = static_cast<uint8_t>(v >> 8);
    p[1] = static_cast<uint8_t>(v);
  }
}

void Writer::u32be(uint32_t v) {
  if (uint8_t* p = claim(4)) {
    p[0] = static_cast<uint8_t>(v >> 24);
    p[1] = static_cast<uint8_t>(v >> 16);
    p[2] = static_cast<uint8_t>(v >> 8);
    p[3] = static_cast<uint8_t>(v);
  }
}

void Writer::bytes(const uint8_t* src, size_t n) {
  uint8_t* p = claim(n);
  if (p && n > 0) memcpy(p, src, n);
}

void Writer::patch_u16le(size_t offset, uint16_t v) {
  if (!ok_ || offset > size_ || size_ - offset < 2) {
    ok_ = false;
    return;
  }
  buf_[offset] = static_cast<uint8_t>(v);
  buf_[offset + 1] = static_cast<uint8_t>(v >> 8);
}

}  // namespace rmnet
