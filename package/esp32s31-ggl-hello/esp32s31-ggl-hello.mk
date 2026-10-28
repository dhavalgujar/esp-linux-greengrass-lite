################################################################################
#
# esp32s31-ggl-hello
#
################################################################################

ESP32S31_GGL_HELLO_VERSION = 1.0.0
ESP32S31_GGL_HELLO_SITE = $(BR2_EXTERNAL_ESP32S31_GGL_PATH)/components/esp32s31-ggl-hello
ESP32S31_GGL_HELLO_SITE_METHOD = local
ESP32S31_GGL_HELLO_LICENSE = Apache-2.0
ESP32S31_GGL_HELLO_DEPENDENCIES = aws-greengrass-lite

# gg-sdk is an LTO archive built with -fvisibility=hidden; -flto lets the
# compiler driver pull its bitcode in.
define ESP32S31_GGL_HELLO_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -std=gnu11 -flto -o $(@D)/esp32s31-ggl-hello \
		$(@D)/hello.c $(TARGET_LDFLAGS) -flto -lgg-sdk -lpthread
endef

define ESP32S31_GGL_HELLO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/esp32s31-ggl-hello \
		$(TARGET_DIR)/usr/bin/esp32s31-ggl-hello
	$(INSTALL) -D -m 0644 $(@D)/recipe.yaml \
		$(TARGET_DIR)/usr/share/esp32s31-ggl-hello/com.espressif.esp32s31.Hello-1.0.0.yaml
endef

$(eval $(generic-package))
