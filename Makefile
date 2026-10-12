# Makefile for xhisper

CC = gcc
CFLAGS = -O2 -Wall -Wextra
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin
UNAME := $(shell uname)

ifeq ($(UNAME),Darwin)
# macOS: the native parts live in one Swift app, Xhisper.app (see macos/).
APP = build/Xhisper.app
APP_BIN = $(APP)/Contents/MacOS/Xhisper
APP_SOURCES = $(wildcard macos/*.swift)
LOGIC_SOURCES = macos/Runtime.swift macos/LevelMeter.swift
SWIFTFLAGS = -O -swift-version 5 -target $(shell uname -m)-apple-macos13.0
# A stable signature keeps the Accessibility / Input Monitoring grants across
# rebuilds; ad-hoc (-) changes identity each time. See macos/make-cert.sh.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"xhisper Code Signing"' && echo 'xhisper Code Signing' || echo -)
INSTALL_USER ?= $(or $(SUDO_USER),$(shell stat -f %Su /dev/console))
INSTALL_HOME = $(shell dscl . -read /Users/$(INSTALL_USER) NFSHomeDirectory | awk '{print $$2}')
AGENT = io.github.abszar.xhisper.hotkey
APPLICATIONS = $(DESTDIR)/Applications

all: $(APP_BIN)

$(APP_BIN): $(APP_SOURCES) macos/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp macos/Info.plist $(APP)/Contents/Info.plist
	swiftc $(SWIFTFLAGS) $(APP_SOURCES) -o $(APP_BIN)
	codesign --force --sign "$(SIGN_ID)" --identifier io.github.abszar.xhisper $(APP)

build/selftest: $(LOGIC_SOURCES) macos/tests/main.swift
	mkdir -p build
	swiftc -swift-version 5 $(LOGIC_SOURCES) macos/tests/main.swift -o build/selftest

check: build/selftest
	build/selftest
	@if [ -d tests ]; then python3 -m unittest discover -s tests -v; fi

install: $(APP_BIN)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 xhisper.sh $(DESTDIR)$(BINDIR)/xhisper
	install -m 755 xhisper-learn $(DESTDIR)$(BINDIR)/xhisper-learn
	rm -rf $(APPLICATIONS)/Xhisper.app
	ditto $(APP) $(APPLICATIONS)/Xhisper.app
	for sub in notify history hotkey; do \
	  printf '#!/bin/sh\nexec /Applications/Xhisper.app/Contents/MacOS/Xhisper %s "$$@"\n' $$sub > $(DESTDIR)$(BINDIR)/xhisper-$$sub; \
	  chmod 755 $(DESTDIR)$(BINDIR)/xhisper-$$sub; \
	done

uninstall:
	rm -rf $(APPLICATIONS)/Xhisper.app
	rm -f $(DESTDIR)$(BINDIR)/xhisper $(DESTDIR)$(BINDIR)/xhisper-learn
	rm -f $(DESTDIR)$(BINDIR)/xhisper-notify $(DESTDIR)$(BINDIR)/xhisper-history $(DESTDIR)$(BINDIR)/xhisper-hotkey

else
all: xhispertool test

xhispertool: xhispertool.c
	$(CC) $(CFLAGS) xhispertool.c -o xhispertool
	ln -sf xhispertool xhispertoold

test: test.c
	$(CC) $(CFLAGS) test.c -o test

check:
	@if [ -d tests ]; then python3 -m unittest discover -s tests -v; fi

install: xhispertool xhisper.sh xhisper-notify xhisper-hotkey xhisper-history xhisper-learn
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 xhispertool $(DESTDIR)$(BINDIR)/xhispertool
	ln -sf xhispertool $(DESTDIR)$(BINDIR)/xhispertoold
	install -m 755 xhisper.sh $(DESTDIR)$(BINDIR)/xhisper
	install -m 755 xhisper-notify $(DESTDIR)$(BINDIR)/xhisper-notify
	install -m 755 xhisper-hotkey $(DESTDIR)$(BINDIR)/xhisper-hotkey
	install -m 755 xhisper-history $(DESTDIR)$(BINDIR)/xhisper-history
	install -m 755 xhisper-learn $(DESTDIR)$(BINDIR)/xhisper-learn

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/xhisper
	rm -f $(DESTDIR)$(BINDIR)/xhispertool
	rm -f $(DESTDIR)$(BINDIR)/xhispertoold
	rm -f $(DESTDIR)$(BINDIR)/xhisper-notify
	rm -f $(DESTDIR)$(BINDIR)/xhisper-hotkey
	rm -f $(DESTDIR)$(BINDIR)/xhisper-history
	rm -f $(DESTDIR)$(BINDIR)/xhisper-learn
endif

clean:
	rm -f xhispertool xhispertoold test
	rm -rf build

.PHONY: all install uninstall clean check
