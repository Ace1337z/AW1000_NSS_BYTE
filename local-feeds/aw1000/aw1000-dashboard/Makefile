# Arcadyan AW1000 dashboard widgets.
#
# Taken from https://github.com/XT-Martinez/aw1000-feed, package
# aw1000/aw1000-defaults at commit a7e14ad ("aw1000-defaults: show IPv6 of a
# dual-stack call on the mobile tab").
#
# Only the dashboard part is vendored here, not the whole aw1000-defaults
# package: that one also ships the "wwan" quectel-proto interface, an open
# 2.4 GHz board.d default, fstab anon-mount, the LED ownership changes and a
# theme override. This image runs QModem instead, so those defaults would fight
# the QModem data path. The widgets read what aw1000-leds stores in
# /tmp/aw1000-status, so the poller ships with them.
#
# Local change against XT's tree: aw1000-leds calls the AT tool as sms_tool_q
# instead of sms_tool, so the image does not need a second AT/sms binary next
# to QModem's (both are the same obsy/sms_tool CLI, "-d <port> at <cmd>").
include $(TOPDIR)/rules.mk

PKG_NAME:=aw1000-dashboard
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/aw1000-dashboard
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=Arcadyan AW1000 dashboard widgets (modem, thermal, storage)
  # TARGET_qualcommax_ipq807x_DEVICE_arcadyan_aw1000 is a profile choice, not a
  # symbol set by CONFIG_TARGET_DEVICE_* in per-device-rootfs builds, so gating
  # on it leaves the package unsettable (=m at best). The subtarget symbol is
  # set; this tree builds the AW1000 and nothing else.
  DEPENDS:=@TARGET_qualcommax_ipq807x \
	+luci-base +luci-mod-dashboard +jsonfilter +flock +sms-tool_q
  PKGARCH:=all
endef

define Package/aw1000-dashboard/description
 Modem, temperature and storage widgets for the LuCI dashboard, plus the
 aw1000-leds poller that feeds them and drives the front panel LEDs. The
 poller talks to the modem's second AT port and writes its readings to
 /tmp/aw1000-status; the widgets hide themselves until those files exist.
endef

define Package/aw1000-dashboard/conffiles
/etc/config/aw1000_leds
endef

define Build/Compile
endef

define Package/aw1000-dashboard/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) ./files/usr/sbin/aw1000-leds $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/etc/init.d/aw1000-leds $(1)/etc/init.d/
	$(INSTALL_CONF) ./files/etc/config/aw1000_leds $(1)/etc/config/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-aw1000-dashboard.json \
		$(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/aw1000
	$(INSTALL_DATA) ./files/www/luci-static/resources/aw1000/cell.js \
		./files/www/luci-static/resources/aw1000/mcc.js \
		$(1)/www/luci-static/resources/aw1000/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/dashboard/include
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/dashboard/include/40_mobile.js \
		./files/www/luci-static/resources/view/dashboard/include/45_thermal.js \
		./files/www/luci-static/resources/view/dashboard/include/50_storage.js \
		$(1)/www/luci-static/resources/view/dashboard/include/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/dashboard/icons
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/dashboard/icons/mobile.svg \
		./files/www/luci-static/resources/view/dashboard/icons/thermal.svg \
		./files/www/luci-static/resources/view/dashboard/icons/storage.svg \
		$(1)/www/luci-static/resources/view/dashboard/icons/
endef

$(eval $(call BuildPackage,aw1000-dashboard))
