# Extra flags for swift (e.g. SWIFTFLAGS=--disable-sandbox when building inside another sandbox).
SWIFTFLAGS ?=
# With only the Command Line Tools installed (no Xcode), swift test needs to be told
# where the Swift Testing macro plugin lives.
TESTING_PLUGIN := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGIN)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGIN))

.PHONY: build test install uninstall clean

build:
	swift build -c release $(SWIFTFLAGS)

test:
	swift test $(SWIFTFLAGS) $(TEST_FLAGS)

install: build
	.build/release/mac-display-guard install

uninstall:
	.build/release/mac-display-guard uninstall

clean:
	rm -rf .build
