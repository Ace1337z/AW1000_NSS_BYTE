include $(TOPDIR)/rules.mk

# One LuCI page for the two switches that are specific to this image and have
# no home of their own, so each can be used without an SSH session:
#
#   NSS / ECM flow offload   /usr/bin/nss-offload
#   AdGuard Home + PassWall2 Ace1337z/openwrt-agh-passwall2 (MIT), vendored
#
# TTL is not here. It is owned by QModem's qmodem_ttl service
# (luci-app-qmodem-ttlfw4, /etc/config/qmodem_ttl) and configured at
# Modem -> QModem -> TTL. This page only reports its state, because the two are
# mutually exclusive - ECM bypasses netfilter, so offloaded flows keep their
# original TTL - and the page says so before you toggle offload.
PKG_NAME:=luci-app-custom
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=AW1000_NSS_BYTE
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Image-specific switches (NSS offload, AdGuard+PassWall2)
  # adguardhome / luci-app-adguardhome are NOT dependencies: the installer
  # pulls them on demand from the feed. Requiring them here would put a ~30 MB
  # Go binary in every image that ships this page.
  DEPENDS:=+luci-base +rpcd +curl
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  One page for the NSS/ECM flow-offload switch and the AdGuard Home +
  PassWall2 DNS chain, plus a read-only view of the QModem TTL service that
  offload cannot coexist with.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/custom $(1)/usr/libexec/rpcd/
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./root/agh-passwall2-install.sh $(1)/usr/libexec/agh-passwall2-install.sh
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-custom.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-custom.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/custom
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/custom/overview.js \
		$(1)/www/luci-static/resources/view/custom/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache*
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
