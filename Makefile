PREFIX ?= /usr/local
APP := build/LidAwake.app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BOTTLE := bottles/lidawake-$(VERSION).all.bottle.tar.gz

.PHONY: all install bottle clean test

all: $(APP)

# Universal, so one build runs on Apple Silicon and Intel Macs.
$(APP): $(wildcard Sources/*.swift) Resources/Info.plist
	rm -rf $@ build/arch
	mkdir -p $@/Contents/MacOS build/arch
	swiftc -O -target arm64-apple-macos13.0 -o build/arch/arm64 Sources/*.swift
	swiftc -O -target x86_64-apple-macos13.0 -o build/arch/x86_64 Sources/*.swift
	lipo -create -output $@/Contents/MacOS/LidAwake build/arch/arm64 build/arch/x86_64
	cp Resources/Info.plist $@/Contents/
	codesign --force --sign - $@

install: $(APP)
	mkdir -p $(PREFIX)
	cp -R $(APP) $(PREFIX)/

# The prebuilt keg brew pours, so installing doesn't need the Xcode Command Line Tools.
# Replaces any older bottle: brew only ever needs the one the formula names.
bottle: $(APP)
	rm -rf build/bottle bottles
	mkdir -p build/bottle/lidawake/$(VERSION) bottles
	cp -R $(APP) build/bottle/lidawake/$(VERSION)/
	COPYFILE_DISABLE=1 tar --no-mac-metadata -C build/bottle -czf $(BOTTLE) lidawake
	shasum -a 256 $(BOTTLE)

test:
	mkdir -p build
	swiftc Sources/DisplaySleep.swift Tests/DisplaySleepTests.swift -o build/display-sleep-tests
	build/display-sleep-tests

clean:
	rm -rf build

test: test-recovery test-session

.PHONY: test-recovery test-session
test-session:
	mkdir -p build
	swiftc -o build/session-test Sources/Session.swift Tests/SessionTests.swift
	build/session-test

test-recovery:
	mkdir -p build
	swiftc -o build/recovery-test Sources/Recovery.swift Tests/recovery/main.swift
	python3 Tests/recovery/check.py "$(CURDIR)/build/recovery-test"
