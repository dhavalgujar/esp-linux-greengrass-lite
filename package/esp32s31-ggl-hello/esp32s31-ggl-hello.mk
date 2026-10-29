################################################################################
#
# esp32s31-ggl-hello
#
################################################################################

# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0

ESP32S31_GGL_HELLO_VERSION = 1.0.0
ESP32S31_GGL_HELLO_SITE = $(BR2_EXTERNAL_ESP32S31_GGL_PATH)/examples/cloud/greengrass-hello
ESP32S31_GGL_HELLO_SITE_METHOD = local
ESP32S31_GGL_HELLO_LICENSE = CC0-1.0
ESP32S31_GGL_HELLO_DEPENDENCIES = aws-greengrass-lite

# The example's own Makefile, with Buildroot's compiler and flags.
define ESP32S31_GGL_HELLO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)"
endef

define ESP32S31_GGL_HELLO_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" \
		DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))
