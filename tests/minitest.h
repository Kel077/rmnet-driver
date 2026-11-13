// Minimal self-registering test harness. Tests may use the STL; Core may not.
#pragma once

#include <stdint.h>
#include <stddef.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

namespace minitest {

struct TestCase {
  const char* name;
  void (*fn)();
};

inline std::vector<TestCase>& registry() {
  static std::vector<TestCase> tests;
  return tests;
}

// Name and number of failed checks of the test that is currently running.
inline const char*& current_name() {
  static const char* name = "";
  return name;
}
inline int& current_failures() {
  static int failures = 0;
  return failures;
}

struct Registrar {
  Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

inline void fail(const char* file, int line, const std::string& message) {
  std::printf("[%s] %s:%d: %s\n", current_name(), file, line, message.c_str());
  ++current_failures();
}

template <typename T>
std::string show(const T& v) {
  std::ostringstream out;
  if constexpr (std::is_enum_v<T>) {
    return show(static_cast<std::underlying_type_t<T>>(v));
  } else if constexpr (std::is_same_v<T, bool>) {
    out << (v ? "true" : "false");
  } else if constexpr (std::is_integral_v<T> && std::is_signed_v<T>) {
    out << static_cast<long long>(v);
    if (v < 0) return out.str();
    out << " (0x" << std::hex << static_cast<long long>(v) << ")";
  } else if constexpr (std::is_integral_v<T>) {
    out << static_cast<unsigned long long>(v) << " (0x" << std::hex
        << static_cast<unsigned long long>(v) << ")";
  } else {
    out << v;
  }
  return out.str();
}

template <typename A, typename B>
void check_eq(const char* file, int line, const char* a_expr, const char* b_expr, const A& a,
              const B& b) {
  if (a == b) return;
  fail(file, line,
       std::string("CHECK_EQ(") + a_expr + ", " + b_expr + ") failed: " + show(a) + " != " +
           show(b));
}

inline std::string to_hex(const uint8_t* p, size_t n) {
  std::string s;
  char buf[4];
  for (size_t i = 0; i < n; ++i) {
    std::snprintf(buf, sizeof buf, i ? " %02x" : "%02x", p[i]);
    s += buf;
  }
  return s;
}

// Parses whitespace-separated hex bytes, e.g. "01 0b 00". Aborts on malformed text.
inline std::vector<uint8_t> hex(const char* text) {
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  std::vector<uint8_t> out;
  for (const char* p = text; *p;) {
    if (*p == ' ' || *p == '\n' || *p == '\t') {
      ++p;
      continue;
    }
    int hi = nibble(p[0]);
    int lo = hi < 0 ? -1 : nibble(p[1]);
    if (lo < 0) {
      std::fprintf(stderr, "hex(): malformed input \"%s\"\n", text);
      std::abort();
    }
    out.push_back(static_cast<uint8_t>(hi << 4 | lo));
    p += 2;
  }
  return out;
}

inline void check_bytes(const char* file, int line, const char* expr, const uint8_t* p, size_t n,
                        const char* expected_text) {
  std::vector<uint8_t> expected = hex(expected_text);
  bool same = n == expected.size() && (n == 0 || std::equal(p, p + n, expected.begin()));
  if (same) return;
  fail(file, line,
       std::string("CHECK_BYTES(") + expr + ") failed:\n    actual:   " + to_hex(p, n) +
           "\n    expected: " + to_hex(expected.data(), expected.size()));
}

inline void check_bytes(const char* file, int line, const char* expr,
                        const std::vector<uint8_t>& v, const char* expected_text) {
  check_bytes(file, line, expr, v.data(), v.size(), expected_text);
}

}  // namespace minitest

using minitest::hex;

#define TEST(name)                                                          \
  static void minitest_test_##name();                                       \
  static const ::minitest::Registrar minitest_registrar_##name(#name,       \
                                                               minitest_test_##name); \
  static void minitest_test_##name()

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) ::minitest::fail(__FILE__, __LINE__, "CHECK(" #cond ") failed"); \
  } while (0)

#define CHECK_EQ(a, b) ::minitest::check_eq(__FILE__, __LINE__, #a, #b, (a), (b))

// CHECK_BYTES(pointer, length, "01 0b 00") or CHECK_BYTES(vector, "01 0b 00").
#define CHECK_BYTES(...) ::minitest::check_bytes(__FILE__, __LINE__, #__VA_ARGS__, __VA_ARGS__)
