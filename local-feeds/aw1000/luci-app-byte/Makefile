#
# Copyright (C) 2026 Ace1337z
#
# This is free software, licensed under the GNU General Public License v3.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-byte
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_MAINTAINER:=Ace1337z
PKG_LICENSE:=GPL-3.0-only

LUCI_TITLE:=BYTE - AdGuard Home + PassWall2 one-page panel
LUCI_DESCRIPTION:=Single LuCI page under Tools to install, wire, inspect and undo the AdGuard Home + PassWall2 DNS chain. Ships the vendored upstream installer, so no runtime network fetch.
# luci-base: JS framework + resource loading. rpcd: the ubus exec plugin host.
# libubox/jsonfilter: jshn.sh + jsonfilter used by the backend script.
LUCI_DEPENDS:=+luci-base +rpcd +libubox +jsonfilter +ubus

# luci.mk installs ./htdocs -> /www and ./root -> / automatically, so the
# menu json, rpcd acl, backend script, uci-defaults and the vendored installer
# all land in the right place without a custom Package/install block.
include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,luci-app-byte))