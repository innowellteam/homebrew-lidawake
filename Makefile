PREFIX ?= /usr/local
APP := build/LidAwake.app

.PHONY: all install clean

all: $(APP)

$(APP): Sources/main.swift Resources/Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	swiftc -O -target $(shell uname -m)-apple-macos13.0 -o $@/Contents/MacOS/LidAwake Sources/main.swift
	cp Resources/Info.plist $@/Contents/
	codesign --force --sign - $@

install: $(APP)
	mkdir -p $(PREFIX)
	cp -R $(APP) $(PREFIX)/

clean:
	rm -rf build
