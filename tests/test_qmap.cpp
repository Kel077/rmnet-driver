#include "minitest.h"

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
