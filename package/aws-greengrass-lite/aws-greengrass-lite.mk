################################################################################
#
# aws-greengrass-lite
#
################################################################################

AWS_GREENGRASS_LITE_VERSION = 2.7.0
AWS_GREENGRASS_LITE_SITE = $(call github,aws-greengrass,aws-greengrass-lite,v$(AWS_GREENGRASS_LITE_VERSION))
AWS_GREENGRASS_LITE_LICENSE = Apache-2.0
AWS_GREENGRASS_LITE_LICENSE_FILES = LICENSE
AWS_GREENGRASS_LITE_DEPENDENCIES = host-pkgconf openssl libcurl sqlite \
	libyaml libevent liburiparser util-linux libzip

# The upstream build pulls these with CMake FetchContent (fc_deps.json at
# v2.7.0). Buildroot downloads them instead so that the configure step
# never needs the network and the sources are hash-checked like any other.
AWS_GREENGRASS_LITE_CORE_MQTT_REV = bda794aa54785aa96224f19e37d2e19e66bcd7ab
AWS_GREENGRASS_LITE_AWS_SIGV4_REV = v1.3.1
AWS_GREENGRASS_LITE_GG_SDK_REV = cdb3a2871d6a3db7f67444ff9f4c05da38d6f2d9
AWS_GREENGRASS_LITE_UNITY_REV = cbcd08fa7de711053a3deec6339ee89cad5d2697

AWS_GREENGRASS_LITE_EXTRA_DOWNLOADS = \
	https://github.com/FreeRTOS/coreMQTT/archive/$(AWS_GREENGRASS_LITE_CORE_MQTT_REV)/coreMQTT-$(AWS_GREENGRASS_LITE_CORE_MQTT_REV).tar.gz \
	https://github.com/aws/SigV4-for-AWS-IoT-embedded-sdk/archive/$(AWS_GREENGRASS_LITE_AWS_SIGV4_REV)/SigV4-$(AWS_GREENGRASS_LITE_AWS_SIGV4_REV).tar.gz \
	https://github.com/aws-greengrass/aws-greengrass-component-sdk/archive/$(AWS_GREENGRASS_LITE_GG_SDK_REV)/gg-sdk-$(AWS_GREENGRASS_LITE_GG_SDK_REV).tar.gz \
	https://github.com/ThrowTheSwitch/Unity/archive/$(AWS_GREENGRASS_LITE_UNITY_REV)/Unity-$(AWS_GREENGRASS_LITE_UNITY_REV).tar.gz

define AWS_GREENGRASS_LITE_EXTRACT_FETCHCONTENT_DEPS
	$(foreach dep,\
		core_mqtt:coreMQTT-$(AWS_GREENGRASS_LITE_CORE_MQTT_REV) \
		aws_sigv4:SigV4-$(AWS_GREENGRASS_LITE_AWS_SIGV4_REV) \
		gg_sdk:gg-sdk-$(AWS_GREENGRASS_LITE_GG_SDK_REV) \
		unity:Unity-$(AWS_GREENGRASS_LITE_UNITY_REV),
		mkdir -p $(@D)/_deps/$(firstword $(subst :, ,$(dep)))
		$(call suitable-extractor,$(lastword $(subst :, ,$(dep))).tar.gz) \
			$(AWS_GREENGRASS_LITE_DL_DIR)/$(lastword $(subst :, ,$(dep))).tar.gz | \
			$(TAR) --strip-components=1 \
				-C $(@D)/_deps/$(firstword $(subst :, ,$(dep))) \
				$(TAR_OPTIONS) -
	)
endef
AWS_GREENGRASS_LITE_POST_EXTRACT_HOOKS += AWS_GREENGRASS_LITE_EXTRACT_FETCHCONTENT_DEPS

# Buildroot defaults BUILD_SHARED_LIBS=ON, which turns the vendored gg-sdk
# into a shared library; upstream builds everything with
# -fvisibility=hidden, so that library would export nothing. Link it
# statically as upstream does.
AWS_GREENGRASS_LITE_CONF_OPTS = \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_TESTING=OFF \
	-DBUILD_EXAMPLES=OFF \
	-DGGL_RELEASE=ON \
	-DGG_LOG_LEVEL=INFO \
	-DFETCHCONTENT_FULLY_DISCONNECTED=ON \
	-DFETCHCONTENT_SOURCE_DIR_CORE_MQTT=$(@D)/_deps/core_mqtt \
	-DFETCHCONTENT_SOURCE_DIR_AWS_SIGV4=$(@D)/_deps/aws_sigv4 \
	-DFETCHCONTENT_SOURCE_DIR_GG_SDK=$(@D)/_deps/gg_sdk \
	-DFETCHCONTENT_SOURCE_DIR_UNITY=$(@D)/_deps/unity

ifeq ($(BR2_TOOLCHAIN_USES_GLIBC),)
AWS_GREENGRASS_LITE_DEPENDENCIES += argp-standalone
endif

ifeq ($(BR2_PACKAGE_SYSTEMD),y)
AWS_GREENGRASS_LITE_DEPENDENCIES += systemd
AWS_GREENGRASS_LITE_CONF_OPTS += \
	-DGGL_PORTABLE_CORE=OFF \
	-DGGL_SYSTEMD_SYSTEM_DIR=lib/systemd/system

# Start the nucleus at boot, as the upstream install guide does with
# "systemctl enable greengrass-lite.target" and its member services.
define AWS_GREENGRASS_LITE_INSTALL_INIT_SYSTEMD
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants \
		$(TARGET_DIR)/etc/systemd/system/greengrass-lite.target.wants
	ln -sf ../../../../usr/lib/systemd/system/greengrass-lite.target \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/greengrass-lite.target
	for unit in $(TARGET_DIR)/usr/lib/systemd/system/ggl.*; do \
		grep -q '^WantedBy=greengrass-lite.target' $$unit || continue; \
		ln -sf ../../../../usr/lib/systemd/system/$${unit##*/} \
			$(TARGET_DIR)/etc/systemd/system/greengrass-lite.target.wants/; \
	done
endef
else
AWS_GREENGRASS_LITE_CONF_OPTS += -DGGL_PORTABLE_CORE=ON
endif

# Native components link the Greengrass component SDK (gg-sdk) that the
# nucleus build vendors; export it to staging. It is an LTO archive, so
# components must be linked with the same toolchain.
AWS_GREENGRASS_LITE_INSTALL_STAGING = YES
define AWS_GREENGRASS_LITE_INSTALL_GG_SDK
	$(INSTALL) -D -m 0644 $(@D)/gg-sdk/libgg-sdk.a \
		$(STAGING_DIR)/usr/lib/libgg-sdk.a
	mkdir -p $(STAGING_DIR)/usr/include
	cp -a $(@D)/_deps/gg_sdk/include/gg $(STAGING_DIR)/usr/include/
endef
AWS_GREENGRASS_LITE_POST_INSTALL_STAGING_HOOKS += AWS_GREENGRASS_LITE_INSTALL_GG_SDK

define AWS_GREENGRASS_LITE_USERS
	ggcore -1 ggcore -1 * /var/lib/greengrass - - Greengrass core services
	gg_component -1 gg_component -1 * /home/gg_component /bin/sh - Greengrass components
endef

$(eval $(cmake-package))
