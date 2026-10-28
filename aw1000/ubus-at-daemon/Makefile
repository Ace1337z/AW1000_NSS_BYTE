include $(TOPDIR)/rules.mk

# Vendored from FUjr/QModem @ 052f8447 (application/ubus_at_daemon), MPL-2.0.
# fxsd (the AW1000 RJ11 phone daemon) sends every AT command through
# 'ubus call at-daemon sendat'; without this daemon the phone sits at
# "Waiting for the modem" even though the modem answers sms_tool fine.
# Vendored instead of adding the whole QModem feed, which would also drag in
# qmodem itself - this image uses quectel-cm + qmi_wwan_q for the data path.
PKG_NAME:=ubus-at-daemon
PKG_VERSION:=2.8.9
PKG_RELEASE:=1
PKG_LICENSE:=MPL-2.0
PKG_MAINTAINER:=FUjr <https://github.com/FUjr>

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Ubus AT Command Daemon
  DEPENDS:=+libubus +libubox +libblobmsg-json +libjson-c
endef

define Package/$(PKG_NAME)/description
  A ubus daemon for handling AT commands with OpenWRT.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) src/* $(PKG_BUILD_DIR)/
endef

# src/Makefile sets CFLAGS with '=' (not '+='), so it has to be fed through
# TARGET_DIR and the OpenWrt toolchain variables rather than CFLAGS= on the
# command line: the file's own CFLAGS wins over anything passed in the
# environment, and it expects -I$(TARGET_DIR)/usr/include to find ubus/ubox.
define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		STRIP="$(TARGET_CROSS)strip" \
		TARGET_DIR="$(STAGING_DIR)" \
		STAGING_DIR="$(STAGING_DIR)" \
		CFLAGS="$(TARGET_CFLAGS) -Wall -Wextra -std=c99 -D_GNU_SOURCE -I$(STAGING_DIR)/usr/include -I$(STAGING_DIR)/usr/include/libubox -I$(STAGING_DIR)/usr/include/json-c" \
		LDFLAGS="$(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib -lubus -lubox -lblobmsg_json -ljson-c -lpthread"
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ubus-at-daemon $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ubus-at-daemon $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ubus-at-daemon $(1)/etc/config/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
