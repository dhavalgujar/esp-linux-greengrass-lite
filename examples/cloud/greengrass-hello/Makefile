# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
#
# SPDX-License-Identifier: CC0-1.0

TARGET := build/esp32s31-ggl-hello
SOURCE := src/hello.c
RECIPE := recipe.yaml
COMPONENT := com.espressif.esp32s31.Hello
VERSION := 1.0.0

# The compiler must find the Greengrass SDK (gg/*.h, libgg-sdk.a) in its
# sysroot, as the Buildroot toolchain wrapper of this repository does.
CROSS_COMPILE ?= riscv64-esp-linux-musl-

ifeq ($(origin CC), default)
ifneq ($(MAKECMDGOALS),clean)
ifeq ($(strip $(CROSS_COMPILE)),)
$(error CROSS_COMPILE is not set; specify the RISC-V toolchain prefix)
endif
endif
CC := $(CROSS_COMPILE)gcc
endif

CFLAGS ?= -O2 -Wall -Wextra
# libgg-sdk.a is an LTO archive built with -fvisibility=hidden: the program
# must be compiled and linked with -flto for its symbols to resolve.
SDK_CFLAGS := -std=gnu11 -flto
SDK_LDLIBS := -lgg-sdk -lpthread

prefix ?= /usr
bindir ?= $(prefix)/bin
datadir ?= $(prefix)/share
DESTDIR ?=
INSTALL ?= install

.PHONY: all install clean

all: $(TARGET)

$(TARGET): $(SOURCE) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SDK_CFLAGS) $< $(LDFLAGS) -flto \
		$(SDK_LDLIBS) -o $@

build:
	mkdir -p $@

# The recipe goes where "ggl-cli deploy -r" can read it: its file name must
# be <component>-<version>.yaml.
install: $(TARGET)
	$(INSTALL) -d $(DESTDIR)$(bindir) $(DESTDIR)$(datadir)/esp32s31-ggl-hello
	$(INSTALL) -m 0755 $(TARGET) $(DESTDIR)$(bindir)/esp32s31-ggl-hello
	$(INSTALL) -m 0644 $(RECIPE) \
		$(DESTDIR)$(datadir)/esp32s31-ggl-hello/$(COMPONENT)-$(VERSION).yaml

clean:
	rm -rf build
