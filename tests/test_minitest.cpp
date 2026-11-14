// Tests of the test framework itself.
#include "minitest.h"

#include <vector>

TEST(minitest_hex_takes_crlf_as_white_space) {
  CHECK_BYTES(hex("01\r\n02"), "01 02");
}

TEST(minitest_equal_compares_mixed_signedness_by_value) {
  CHECK(minitest::equal(2, size_t(2)));
  CHECK(minitest::equal(size_t(2), 2));
  CHECK(!minitest::equal(-1, 0xffffffffu));
  CHECK(!minitest::equal(0xffffffffu, -1));
  std::vector<int> v(2);
  CHECK_EQ(v.size(), 2);  // compiles with no u suffix
}
