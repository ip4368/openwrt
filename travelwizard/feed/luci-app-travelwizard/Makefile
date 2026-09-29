# Copyright (C) 2026
# This is free software, licensed under the MIT License.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-travelwizard
PKG_VERSION:=0.1.0
PKG_RELEASE:=12
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-travelwizard
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI travel-router setup wizard
  # Lua controller + template: needs the Lua runtime, which modern LuCI no
  # longer ships by default.
  DEPENDS:=+luci-base +luci-compat +travelwizard
endef

define Package/luci-app-travelwizard/description
 End-user setup wizard for the single-purpose travel-router: join upstream
 Wi-Fi, pass captive portals, select the wired LAN path, configure VPN/proxy
 for the vault network, and verify the tunnel. Links out to full LuCI as
 "Advanced".
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-travelwizard/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/travelwizard
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/travelwizard.lua \
		$(1)/usr/lib/lua/luci/controller/travelwizard.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/travelwizard/wizard.htm \
		$(1)/usr/lib/lua/luci/view/travelwizard/wizard.htm
endef

$(eval $(call BuildPackage,luci-app-travelwizard))
