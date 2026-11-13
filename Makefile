CXX := clang++

CORE_FLAGS := -std=c++17 -Wall -Wextra -Werror -fno-exceptions -fno-rtti
TEST_FLAGS := -std=c++17 -Wall -Wextra -Werror
HARNESS_FLAGS := -std=c++17 -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

CORE_SRCS := $(wildcard core/src/*.cpp)
TEST_SRCS := $(wildcard tests/test_*.cpp)
HARNESS_SRCS := $(wildcard harness/*.mm)

CORE_OBJS := $(patsubst core/src/%.cpp,build/obj/core/%.o,$(CORE_SRCS))
TEST_OBJS := $(patsubst tests/%.cpp,build/obj/tests/%.o,$(TEST_SRCS))
HARNESS_OBJS := $(patsubst harness/%.mm,build/obj/harness/%.o,$(HARNESS_SRCS))

.PHONY: test check-driverkit harness driver clean

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

harness: build/rmnet-harness

build/rmnet-harness: $(CORE_OBJS) $(HARNESS_OBJS)
	$(CXX) -o $@ $^ -framework IOUSBHost -framework IOKit -framework Foundation

build/obj/harness/%.o: harness/%.mm
	@mkdir -p $(dir $@)
	$(CXX) $(HARNESS_FLAGS) -Icore/include -MMD -MP -c $< -o $@

check-driverkit:
	./scripts/check-driverkit-compile.sh

# Unsigned build of the driver and the host app that embeds it. gen.rb writes RMNet.xcodeproj.
XCODEBUILD := xcodebuild -project RMNet.xcodeproj -configuration Debug -parallelizeTargets \
	SYMROOT="$(CURDIR)/build/xcode" OBJROOT="$(CURDIR)/build/xcode/obj" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

driver:
	/usr/bin/ruby gen.rb
	$(XCODEBUILD) -target RMNetDriver build
	$(XCODEBUILD) -target RMNet build
	@echo "driver build ok"

# build/installed keeps the apps that can deactivate an installed driver (scripts/install-driver.sh).
clean:
	[ ! -d build ] || find build -mindepth 1 -maxdepth 1 ! -name installed -exec rm -rf {} +

-include $(CORE_OBJS:.o=.d) $(TEST_OBJS:.o=.d) $(HARNESS_OBJS:.o=.d)
