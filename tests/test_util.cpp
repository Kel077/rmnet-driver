#include "minitest.h"

#include <string.h>

#include <string>
#include <vector>

#include "frames.h"
#include "rmnet/qmi_msgs.h"
#include "rmnet/util.h"

static uint8_t prefix_of(const char* mask) {
  std::vector<uint8_t> m = ipv4(mask);
  return rmnet::prefix_length(m.data());
}

// format_ipv6 of `addr`/`prefix_len` into a buffer of `cap` bytes.
static std::string v6_text(const char* addr, uint8_t prefix_len, size_t cap = 64) {
  rmnet::RuntimeSettings s{};
  std::vector<uint8_t> a = ipv6(addr);
  memcpy(s.v6_addr, a.data(), 16);
  s.v6_prefix_len = prefix_len;
  std::vector<char> out(cap + 1, 'x');
  rmnet::format_ipv6(s, out.data(), cap);
  return out.data();
}

TEST(prefix_length_counts_mask_bits) {
  CHECK_EQ(prefix_of("0.0.0.0"), 0);
  CHECK_EQ(prefix_of("255.0.0.0"), 8);
  CHECK_EQ(prefix_of("255.255.255.240"), 28);
  CHECK_EQ(prefix_of("255.255.255.252"), 30);
  CHECK_EQ(prefix_of("255.255.255.255"), 32);
}

TEST(format_ipv4_gives_address_prefix_and_gateway) {
  rmnet::RuntimeSettings s{};
  std::vector<uint8_t> addr = ipv4("10.168.1.201"), mask = ipv4("255.255.255.252"), gw = ipv4("10.168.1.202");
  memcpy(s.v4_addr, addr.data(), 4);
  memcpy(s.v4_mask, mask.data(), 4);
  memcpy(s.v4_gateway, gw.data(), 4);
  char out[64];
  rmnet::format_ipv4(s, out, sizeof out);
  CHECK_EQ(std::string(out), "10.168.1.201/30 gw 10.168.1.202");
}

TEST(format_ipv6_gives_rfc5952_text_and_prefix) {
  CHECK_EQ(v6_text("::", 0), "::/0");
  CHECK_EQ(v6_text("::1", 128), "::1/128");
  CHECK_EQ(v6_text("fe80::1", 64), "fe80::1/64");
  CHECK_EQ(v6_text("2001:db8:86d3:14d7:dc03:2f3f:7aef:84e6", 64), "2001:db8:86d3:14d7:dc03:2f3f:7aef:84e6/64");
  CHECK_EQ(v6_text("2001:db8:0:1:1:1:1:1", 64), "2001:db8:0:1:1:1:1:1/64");  // one zero group stays
  CHECK_EQ(v6_text("2001:db8:0:0:1:0:0:1", 64), "2001:db8::1:0:0:1/64");    // the first of two equal runs
  CHECK_EQ(v6_text("2001:db8::", 32), "2001:db8::/32");                      // a trailing run
}

TEST(format_ipv6_truncates_to_cap) {
  const char* addr = "2001:db8:86d3:14d7:dc03:2f3f:7aef:84e6";
  std::string full = v6_text(addr, 64);
  rmnet::RuntimeSettings s{};
  std::vector<uint8_t> a = ipv6(addr);
  memcpy(s.v6_addr, a.data(), 16);
  s.v6_prefix_len = 64;
  char out[16];
  memset(out, 'x', sizeof out);
  rmnet::format_ipv6(s, out, 8);
  REQUIRE(memchr(out, 0, 8) != nullptr);  // NUL-terminated within cap
  CHECK_EQ(full.compare(0, strlen(out), out), 0);  // a prefix of the full text
  CHECK_EQ(strlen(out), 7);
  for (size_t i = 8; i < sizeof out; ++i) CHECK_EQ(out[i], 'x');  // nothing written past cap
}

TEST(worth_is_true_for_powers_of_two) {
  CHECK(!rmnet::worth(0));
  CHECK(rmnet::worth(1));
  CHECK(rmnet::worth(2));
  CHECK(!rmnet::worth(3));
  CHECK(rmnet::worth(4));
  CHECK(!rmnet::worth(6));
  CHECK(rmnet::worth(1024));
}
