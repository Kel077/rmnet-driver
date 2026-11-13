CXX := clang++

CORE_FLAGS := -std=c++17 -Wall -Wextra -Werror -fno-exceptions -fno-rtti
TEST_FLAGS := -std=c++17 -Wall -Wextra -Werror

CORE_SRCS := $(wildcard core/src/*.cpp)
TEST_SRCS := $(wildcard tests/test_*.cpp)

CORE_OBJS := $(patsubst core/src/%.cpp,build/obj/core/%.o,$(CORE_SRCS))
TEST_OBJS := $(patsubst tests/%.cpp,build/obj/tests/%.o,$(TEST_SRCS))

.PHONY: test check-driverkit clean

test: build/tests
	./build/tests $(FILTER)

build/tests: $(CORE_OBJS) $(TEST_OBJS)
	$(CXX) -o $@ $^

build/obj/core/%.o: core/src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -MMD -MP -c $< -o $@

build/obj/tests/%.o: tests/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(TEST_FLAGS) -Icore/include -Itests -MMD -MP -c $< -o $@

check-driverkit:
	./scripts/check-driverkit-compile.sh

clean:
	rm -rf build

-include $(CORE_OBJS:.o=.d) $(TEST_OBJS:.o=.d)
