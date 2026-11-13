#include "minitest.h"

#include "rmnet/bytes.h"

TEST(reader_reads_little_and_big_endian) {
  auto b = hex("01 02 03 04 05 06 07 08 09 0a 0b");
  rmnet::Reader r(b.data(), b.size());
  CHECK_EQ(r.u8(), 0x01); CHECK_EQ(r.u16le(), 0x0302); CHECK_EQ(r.u32le(), 0x07060504u);
  CHECK_EQ(r.u16be(), 0x0809); CHECK_EQ(r.remaining(), 2u); CHECK(r.ok());
}
TEST(reader_short_read_is_sticky) {
  auto b = hex("01 02");
  rmnet::Reader r(b.data(), b.size());
  CHECK_EQ(r.u32le(), 0u); CHECK(!r.ok()); CHECK_EQ(r.u8(), 0); CHECK_EQ(r.remaining(), 0u);
  CHECK(r.take(1).data == nullptr);
}
TEST(reader_take_returns_view) {
  auto b = hex("aa bb cc dd");
  rmnet::Reader r(b.data(), b.size()); r.skip(1);
  rmnet::Span s = r.take(2);
  CHECK(s.data == b.data() + 1); CHECK_EQ(s.len, 2u); CHECK_EQ(r.remaining(), 1u);
}
TEST(writer_writes_and_patches) {
  uint8_t buf[8];
  rmnet::Writer w(buf, sizeof buf);
  w.u8(0x01); w.u16le(0); w.u32be(0x0a0b0c0d); w.patch_u16le(1, 0x1234);
  CHECK(w.ok()); CHECK_EQ(w.size(), 7u); CHECK_BYTES(buf, 7, "01 34 12 0a 0b 0c 0d");
}
TEST(writer_overflow_is_sticky) {
  uint8_t buf[2];
  rmnet::Writer w(buf, sizeof buf);
  w.u32le(1); CHECK(!w.ok()); CHECK_EQ(w.size(), 0u);
  w.u8(1); CHECK(!w.ok()); CHECK_EQ(w.size(), 0u);
}
