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

.PHONY: test driver-test check-driverkit app-test script-test harness driver clean

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

# CoreHost (driver/core_host.cpp) on the host, behind fakes of UsbPort and RxSink, built with Core's
# flags, tests and runner included. `make driver-test FILTER=kept` runs only tests whose name contains it.
DRIVER_TEST_OBJS := build/obj/driver/core_host.o build/obj/driver-tests/test_core_host.o \
	build/obj/driver-tests/test_main.o

driver-test: build/driver-tests
	./build/driver-tests $(FILTER)

build/driver-tests: $(CORE_OBJS) $(DRIVER_TEST_OBJS)
	$(CXX) -o $@ $^

build/obj/driver/core_host.o: driver/core_host.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -MMD -MP -c $< -o $@

build/obj/driver-tests/test_core_host.o: tests/driver/test_core_host.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -Idriver -Itests -MMD -MP -c $< -o $@

build/obj/driver-tests/test_main.o: tests/test_main.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Itests -MMD -MP -c $< -o $@

harness: build/rmnet-harness

build/rmnet-harness: $(CORE_OBJS) $(HARNESS_OBJS)
	$(CXX) -o $@ $^ -framework IOUSBHost -framework IOKit -framework Foundation

build/obj/harness/%.o: harness/%.mm
	@mkdir -p $(dir $@)
	$(CXX) $(HARNESS_FLAGS) -Icore/include -MMD -MP -c $< -o $@

check-driverkit:
	./scripts/check-driverkit-compile.sh
	./scripts/check-personalities.sh

# The app's status model, SMS model, AT answer logic, the Messages tab's controller, the gps verb's
# NMEA logic and its port reader, tested without Xcode or hardware (neither the AT port nor the NMEA
# port is opened: the reader reads a pseudo-terminal the test makes, and no window is made).
app-test: build/app-tests build/sms-tests build/at-tests build/smsui-tests build/nmea-tests build/gpsread-tests
	./build/app-tests
	./build/sms-tests
	./build/at-tests
	./build/smsui-tests
	./build/nmea-tests
	./build/gpsread-tests

build/app-tests: app/StatusModel.swift tests/app/StatusModelTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/sms-tests: app/SmsModel.swift tests/app/SmsModelTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/at-tests: app/AtPort.swift tests/app/AtPortTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/smsui-tests: app/SmsModel.swift app/SmsController.swift tests/app/SmsControllerTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/nmea-tests: app/Nmea.swift tests/app/NmeaTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/gpsread-tests: app/Nmea.swift app/GpsCommand.swift tests/app/GpsReadTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The scripts' decisions that need neither the network nor an install: the install script's kept-app
# and running-driver checks (scripts/install-checks.sh), soak.sh's status classes (--classify), and the
# driver's personalities against the model list (scripts/check-personalities.sh).
script-test:
	sh tests/scripts/test-install-checks.sh
	sh tests/scripts/test-soak-classify.sh
	sh tests/scripts/test-personalities.sh

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

-include $(CORE_OBJS:.o=.d) $(TEST_OBJS:.o=.d) $(HARNESS_OBJS:.o=.d) $(DRIVER_TEST_OBJS:.o=.d)
