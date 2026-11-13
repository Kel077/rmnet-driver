// Runs every registered test, or only those whose name contains argv[1].
#include <cstdio>
#include <cstring>

#include "minitest.h"

int main(int argc, char** argv) {
  const char* filter = argc > 1 ? argv[1] : nullptr;
  int run = 0;
  int failed = 0;
  for (const minitest::TestCase& t : minitest::registry()) {
    if (filter && !std::strstr(t.name, filter)) continue;
    ++run;
    minitest::current_name() = t.name;
    minitest::current_failures() = 0;
    t.fn();
    if (minitest::current_failures() > 0) {
      ++failed;
      std::printf("FAIL %s\n", t.name);
    }
  }
  std::printf("%d tests, %d failed\n", run, failed);
  return failed == 0 ? 0 : 1;
}
