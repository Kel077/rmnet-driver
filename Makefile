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
# flags, tests and runner included.
# Every tests/driver/test_*.cpp is built. `make driver-test FILTER=kept` runs only tests whose name
# contains it.
DRIVER_TEST_SRCS := $(wildcard tests/driver/test_*.cpp)
DRIVER_TEST_OBJS := build/obj/driver/core_host.o \
	$(patsubst tests/driver/%.cpp,build/obj/driver-tests/%.o,$(DRIVER_TEST_SRCS)) \
	build/obj/driver-tests/test_main.o

driver-test: build/driver-tests
	./build/driver-tests $(FILTER)

build/driver-tests: $(CORE_OBJS) $(DRIVER_TEST_OBJS)
	$(CXX) -o $@ $^

build/obj/driver/core_host.o: driver/core_host.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CORE_FLAGS) -Icore/include -MMD -MP -c $< -o $@

build/obj/driver-tests/%.o: tests/driver/%.cpp
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
# NMEA logic, its port reader and its GNSS switching (against a fake switch and a scripted port), the
# network model, the settings model, the modem service (against a scripted port), the modem verbs (against
# a fake service), the modem tabs' controller and the quit gate (with both controllers), tested without
# Xcode or hardware (neither the AT port nor the NMEA port is opened: the reader reads a pseudo-terminal
# the test makes, and no window is made).
app-test: build/app-tests build/sms-tests build/at-tests build/smsui-tests build/nmea-tests build/gpsread-tests \
		build/modemnet-tests build/modemset-tests build/modemsvc-tests build/modemcli-tests build/modemui-tests \
		build/quit-tests
	./build/app-tests
	./build/sms-tests
	./build/at-tests
	./build/smsui-tests
	./build/nmea-tests
	./build/gpsread-tests
	./build/modemnet-tests
	./build/modemset-tests
	./build/modemsvc-tests
	./build/modemcli-tests
	./build/modemui-tests
	./build/quit-tests

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

# The gps verb switches GNSS over the AT port: AtPort.swift, ModemService.swift (AtCommanding), SmsService.swift
# (describe) and what they need. The tests drive a fake switch and a scripted port; no port is opened.
build/gpsread-tests: app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/ModemNetwork.swift \
		app/ModemSettings.swift app/ModemService.swift app/Nmea.swift app/GpsCommand.swift tests/app/GpsReadTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemnet-tests: app/ModemNetwork.swift tests/app/ModemNetworkTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemset-tests: app/ModemNetwork.swift app/ModemSettings.swift tests/app/ModemSettingsTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# SmsService.swift brings describe(_: AtError).
build/modemsvc-tests: app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/ModemNetwork.swift \
		app/ModemSettings.swift app/ModemService.swift tests/app/ModemServiceTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemcli-tests: app/ModemNetwork.swift app/ModemSettings.swift app/ModemCli.swift tests/app/ModemCliTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/modemui-tests: app/ModemNetwork.swift app/ModemSettings.swift app/ModemController.swift tests/app/ModemControllerTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

build/quit-tests: app/SmsModel.swift app/SmsController.swift app/ModemNetwork.swift app/ModemSettings.swift \
		app/ModemController.swift app/QuitGate.swift tests/app/QuitGateTests.swift
	@mkdir -p build
	xcrun swiftc -swift-version 5 -parse-as-library -o $@ $^

# The scripts' decisions that need neither the network nor an install: the install script's
# installed-app ID, kept-app and running-driver checks (scripts/install-checks.sh), soak.sh's status
# classes (--classify), the driver's personalities against the model list
# (scripts/check-personalities.sh), and the build's team and bundle IDs from config.local or the
# environment (scripts/config.sh, gen.rb's options).
script-test:
	sh tests/scripts/test-install-checks.sh
	sh tests/scripts/test-soak-classify.sh
	sh tests/scripts/test-personalities.sh
	sh tests/scripts/test-config.sh

# Unsigned build of the driver and the host app that embeds it. gen.rb writes RMNet.xcodeproj, with
# the bundle ID in RMNET_BUNDLE_ID when it is set (environment or make's command line; config.local
# is not read here), else the default.
XCODEBUILD := xcodebuild -project RMNet.xcodeproj -configuration Debug -parallelizeTargets \
	SYMROOT="$(CURDIR)/build/xcode" OBJROOT="$(CURDIR)/build/xcode/obj" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

driver:
	/usr/bin/ruby gen.rb $(if $(RMNET_BUNDLE_ID),--bundle-id $(RMNET_BUNDLE_ID))
	$(XCODEBUILD) -target RMNetDriver build
	$(XCODEBUILD) -target RMNet build
	@echo "driver build ok"

# build/installed keeps the apps that can deactivate an installed driver (scripts/install-driver.sh).
clean:
	[ ! -d build ] || find build -mindepth 1 -maxdepth 1 ! -name installed -exec rm -rf {} +

-include $(CORE_OBJS:.o=.d) $(TEST_OBJS:.o=.d) $(HARNESS_OBJS:.o=.d) $(DRIVER_TEST_OBJS:.o=.d)
