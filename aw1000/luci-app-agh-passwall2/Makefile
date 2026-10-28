include $(TOPDIR)/rules.mk

# LuCI front-end for Ace1337z/openwrt-agh-passwall2 (MIT).
#
# AdGuard Home and PassWall2 both want port 53. Upstream ships a shell script
# that moves dnsmasq to :54, points AdGuard at PassWall2's resolver on
# 127.0.0.1:15353 and turns off SafeSearch. This package puts a button on that
# script and vendors it, so the setup is one click in LuCI instead of an SSH
# session and a `wget | sh`.
#
# The installer is vendored rather than fetched at click time: a LuCI button
# must not pipe a remote script into a root shell, and the router may have no
# working WAN at the moment the user presses it.
PKG_NAME:=luci-app-agh-passwall2
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Ace1337z (installer) / AW1000_NSS_BYTE (LuCI wrapper)
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=One-click AdGuard Home + PassWall2 DNS setup
  # adguardhome and luci-app-adguardhome are deliberately NOT dependencies:
  # they are installed on demand by the installer from the package feed.
  # Requiring them here would pull a ~30 MB Go binary into the image.
  DEPENDS:=+luci-base +rpcd +curl
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Wraps the openwrt-agh-passwall2 installer so the AdGuard Home + PassWall2
  DNS chain (dnsmasq on :54, AdGuard on :53, PassWall2 on 127.0.0.1:15353)
  can be configured from LuCI with one button.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./root/agh-passwall2-install.sh $(1)/usr/libexec/agh-passwall2-install.sh
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/agh-passwall2 $(1)/usr/libexec/rpcd/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-agh-passwall2.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-agh-passwall2.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/agh-passwall2
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/agh-passwall2/install.js \
		$(1)/www/luci-static/resources/view/agh-passwall2/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
