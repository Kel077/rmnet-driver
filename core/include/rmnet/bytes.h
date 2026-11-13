// Bounds-checked byte cursors over caller-owned memory.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace rmnet {

// A non-owning view of bytes.
struct Span {
  const uint8_t* data;
  size_t len;
};

// Reads from a buffer. Never reads past the end; a failed read is sticky.
class Reader {
 public:
  Reader(const uint8_t* data, size_t len);

  bool ok() const;           // false once any read ran short
  size_t remaining() const;  // 0 once !ok()

  // Each returns 0 when fewer bytes remain than it needs.
  uint8_t u8();
  uint16_t u16le();
  uint32_t u32le();
  uint16_t u16be();
  uint32_t u32be();

  Span take(size_t n);  // {nullptr, 0} when short
  void skip(size_t n);

 private:
  const uint8_t* claim(size_t n);  // nullptr (and !ok()) when short

  const uint8_t* data_;
  size_t len_;
  size_t pos_;
  bool ok_;
};

// Writes into the caller's buffer. Overflow is sticky and writes nothing.
class Writer {
 public:
  Writer(uint8_t* buf, size_t cap);

  bool ok() const;
  size_t size() const;  // 0 once !ok()

  void u8(uint8_t v);
  void u16le(uint16_t v);
  void u32le(uint32_t v);
  void u16be(uint16_t v);
  void u32be(uint32_t v);
  void bytes(const uint8_t* p, size_t n);

  // Overwrites two already-written bytes; offset + 2 must be <= size(), else !ok().
  void patch_u16le(size_t offset, uint16_t v);

 private:
  uint8_t* claim(size_t n);  // nullptr (and !ok()) on overflow

  uint8_t* buf_;
  size_t cap_;
  size_t size_;
  bool ok_;
};

}  // namespace rmnet
