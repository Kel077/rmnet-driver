#include "minitest.h"

#include <string.h>

#include "rmnet/qmap.h"

TEST(parse_single_frame) {
  auto b = hex("00 81 00 08 45 00 00 08 aa bb cc dd"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok);
  CHECK_EQ(f.mux_id, 0x81); CHECK(!f.is_command); CHECK_EQ(f.payload.len, 8u); CHECK(f.payload.data == b.data() + 4);
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::End);
}
TEST(parse_strips_padding) {
  auto b = hex("03 81 00 08 45 00 00 05 aa 00 00 00"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.payload.len, 5u);
}
TEST(parse_two_frames_then_zero_filler) {
  auto b = hex("00 81 00 04 45 00 00 04  00 82 00 04 60 00 00 00  00 00 00 00"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.mux_id, 0x81);
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.mux_id, 0x82);
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::End);
}
TEST(parse_truncated) {
  auto b = hex("00 81 00 08 45 00 00 08 aa bb"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Truncated);
  auto c = hex("00 81 00"); off = 0;
  CHECK(rmnet::qmap_next({c.data(), c.size()}, &off, &f) == rmnet::QmapStatus::Truncated);
}
TEST(parse_bad_pad) {
  auto b = hex("09 81 00 08 45 00 00 08 aa bb cc dd"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Bad);
}
TEST(write_header_pads_to_four) {
  uint8_t h[4]; CHECK_EQ(rmnet::qmap_write_header(h, false, 0x81, 1401), 3); CHECK_BYTES(h, 4, "03 81 05 7c");
  CHECK_EQ(rmnet::qmap_write_header(h, true, 0x81, 8), 0);                  CHECK_BYTES(h, 4, "80 81 00 08");
}
TEST(command_frame_and_reply) {
  auto b = hex("80 81 00 08 01 00 00 00 00 00 00 2a"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK(f.is_command);
  rmnet::QmapCommand c; CHECK(rmnet::qmap_parse_command(f.payload, &c));
  CHECK_EQ(c.name, rmnet::kQmapFlowDisable); CHECK_EQ(c.type, rmnet::kQmapCmdRequest);
  uint8_t out[32]; size_t n = rmnet::qmap_build_command_reply(out, sizeof out, 0x81, f.payload);
  CHECK_BYTES(out, n, "80 81 00 08 01 01 00 00 00 00 00 2a");
  auto u = hex("07 00 00 00 00 00 00 2a");
  n = rmnet::qmap_build_command_reply(out, sizeof out, 0x81, {u.data(), u.size()});
  CHECK_BYTES(out, n, "80 81 00 08 07 02 00 00 00 00 00 2a");
  CHECK(!rmnet::qmap_parse_command({u.data(), 4}, &c));
}
TEST(aggregator_packs_and_round_trips) {
  uint8_t buf[16384]; std::vector<uint8_t> pkt(100, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  for (int i = 0; i < 3; i++) CHECK(a.add(0x81, pkt.data(), pkt.size()));
  CHECK_EQ(a.count(), 3u); size_t n = a.finish(); CHECK_EQ(n, 312u); CHECK_EQ(a.count(), 0u); CHECK_EQ(a.finish(), 0u);
  size_t off = 0; rmnet::QmapFrame f; int frames = 0;
  while (rmnet::qmap_next({buf, n}, &off, &f) == rmnet::QmapStatus::Ok) { CHECK_EQ(f.payload.len, 100u); frames++; }
  CHECK_EQ(frames, 3);
}
TEST(aggregator_rejects_when_full) {
  uint8_t buf[256]; std::vector<uint8_t> pkt(200, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  CHECK(a.add(0x81, pkt.data(), pkt.size())); CHECK(!a.add(0x81, pkt.data(), pkt.size()));
  uint8_t big[4096]; rmnet::QmapAggregator c(big, sizeof big, 2, 1024);
  CHECK(c.add(0x81, pkt.data(), 10)); CHECK(c.add(0x81, pkt.data(), 10)); CHECK(!c.add(0x81, pkt.data(), 10));
}
TEST(aggregator_avoids_usb_packet_multiple) {
  uint8_t buf[4096]; std::vector<uint8_t> pkt(1020, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  CHECK(a.add(0x81, pkt.data(), pkt.size()));
  size_t n = a.finish(); CHECK_EQ(n, 1028u); CHECK_BYTES(buf, 4, "04 81 04 00");
  size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({buf, n}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.payload.len, 1020u);
}

// Pinned behaviour (the deferred list of 2026-11-13).

TEST(aggregator_and_command_reply_keep_lengths_within_16_bits) {
  // Aggregator: a packet is taken only if its padded length plus the 4 bytes finish() may add still
  // fit the length field, so 65528 is the largest.
  std::vector<uint8_t> buf(70000), pkt(65536, 0x45);
  rmnet::QmapAggregator a(buf.data(), buf.size(), 32, 65532);                 // a 65532-byte transfer grows by 4
  for (size_t len : {65529, 65530, 65531, 65532}) CHECK(!a.add(0x81, pkt.data(), len));
  CHECK_EQ(a.count(), 0u);
  CHECK(a.add(0x81, pkt.data(), 65528));
  size_t n = a.finish(); CHECK_EQ(n, 65536u); CHECK_BYTES(buf.data(), 4, "04 81 ff fc");
  size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({buf.data(), n}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.payload.len, 65528u);
  // Command reply: the payload and its padding up to 0xffff, so 65532 is the largest request.
  std::vector<uint8_t> req(65536, 0x00); req[0] = rmnet::kQmapFlowEnable;
  for (size_t len : {65533, 65534, 65535}) {
    CHECK_EQ(rmnet::qmap_build_command_reply(buf.data(), buf.size(), 0x81, {req.data(), len}), 0u);
  }
  CHECK_EQ(rmnet::qmap_build_command_reply(buf.data(), buf.size(), 0x81, {req.data(), 65532}), 65536u);
  CHECK_BYTES(buf.data(), 6, "80 81 ff fc 02 01");
}
TEST(aggregator_refuses_a_zero_length_packet) {
  uint8_t buf[64]; const uint8_t ip[4] = {0x45, 0x00, 0x00, 0x04};
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  CHECK(!a.add(0x81, ip, 0)); CHECK_EQ(a.count(), 0u); CHECK_EQ(a.finish(), 0u);
  CHECK(a.add(0x81, ip, 4)); CHECK(!a.add(0x81, ip, 0)); CHECK_EQ(a.count(), 1u);
  CHECK_EQ(a.finish(), 8u); CHECK_BYTES(buf, 8, "00 81 00 04 45 00 00 04");
}
TEST(non_zero_header_with_zero_length_is_bad) {
  rmnet::QmapFrame f;
  for (const char* text : {"00 81 00 00 45 00 00 04", "80 81 00 00 01 00 00 00", "03 00 00 00 45 00 00 04"}) {
    auto b = hex(text); size_t off = 0;                                       // a mux ID, a command, a pad length
    CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Bad); CHECK_EQ(off, 0u);
  }
  auto z = hex("00 00 00 00 45 00 00 04"); size_t off = 0;                    // all zero: filler, the end
  CHECK(rmnet::qmap_next({z.data(), z.size()}, &off, &f) == rmnet::QmapStatus::End); CHECK_EQ(off, 0u);
}
TEST(aggregator_with_usb_packet_size_0_never_grows_the_transfer) {
  uint8_t buf[4096]; std::vector<uint8_t> pkt(1020, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 0);
  CHECK(a.add(0x81, pkt.data(), pkt.size()));
  CHECK_EQ(a.finish(), 1024u); CHECK_BYTES(buf, 4, "00 81 03 fc");           // with 1024 it would be 1028
  CHECK(a.add(0x81, pkt.data(), 4)); CHECK_EQ(a.finish(), 8u);
}
TEST(command_reply_into_a_buffer_too_small_writes_nothing) {
  uint8_t out[16];
  auto req = hex("01 00 00 00 00 00 00 2a");                                  // 8 bytes: a 12-byte reply
  memset(out, 0xee, sizeof out);
  CHECK_EQ(rmnet::qmap_build_command_reply(out, 11, 0x81, {req.data(), req.size()}), 0u);
  CHECK_BYTES(out, 16, "ee ee ee ee ee ee ee ee ee ee ee ee ee ee ee ee");
  CHECK_EQ(rmnet::qmap_build_command_reply(out, 12, 0x81, {req.data(), req.size()}), 12u);
  CHECK_BYTES(out, 12, "80 81 00 08 01 01 00 00 00 00 00 2a");
  auto odd = hex("02 00 00 00 00 00 00 2a 07");                               // 9 bytes: 3 of padding, 16 in all
  memset(out, 0xee, sizeof out);
  CHECK_EQ(rmnet::qmap_build_command_reply(out, 15, 0x81, {odd.data(), odd.size()}), 0u);
  CHECK_BYTES(out, 16, "ee ee ee ee ee ee ee ee ee ee ee ee ee ee ee ee");
  CHECK_EQ(rmnet::qmap_build_command_reply(out, 16, 0x81, {odd.data(), odd.size()}), 16u);
  CHECK_BYTES(out, 16, "83 81 00 0c 02 01 00 00 00 00 00 2a 07 00 00 00");
}
TEST(offset_at_or_past_the_end_is_the_end) {
  auto b = hex("00 81 00 04 45 00 00 04"); rmnet::QmapFrame f;
  const size_t starts[] = {8, 9, 100, SIZE_MAX};
  for (size_t start : starts) {
    size_t off = start;
    CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::End); CHECK_EQ(off, start);
  }
}
