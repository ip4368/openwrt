# Copyright (C) 2026
# This is free software, licensed under the MIT License.

include $(TOPDIR)/rules.mk

PKG_NAME:=travelwizard
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/travelwizard
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Travel-router VPN wizard backend
  DEPENDS:=+ubus +uci +firewall4 +dnsmasq +curl +ca-bundle +iwinfo +jsonfilter +jshn +coreutils-base64
endef

define Package/travelwizard/description
 Backend helpers for a single-purpose travel-router setup: upstream Wi-Fi
 scan/join with subnet-conflict avoidance, captive-portal detection, and
 policy-routed VPN/proxy (WireGuard, OpenVPN, sing-box) locked to one SSID.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/travelwizard/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/usr/lib/travelwizard
	$(INSTALL_CONF) ./files/etc/config/travelwizard $(1)/etc/config/travelwizard
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-travelwizard $(1)/etc/uci-defaults/90-travelwizard
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/30-tw-subnet $(1)/etc/hotplug.d/iface/30-tw-subnet
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/80-tw-uplink $(1)/etc/hotplug.d/iface/80-tw-uplink
	$(INSTALL_BIN) ./files/usr/sbin/tw-wan-scan $(1)/usr/sbin/tw-wan-scan
	$(INSTALL_BIN) ./files/usr/sbin/tw-wan-join $(1)/usr/sbin/tw-wan-join
	$(INSTALL_BIN) ./files/usr/sbin/tw-subnet-fix $(1)/usr/sbin/tw-subnet-fix
	$(INSTALL_BIN) ./files/usr/sbin/tw-captive-check $(1)/usr/sbin/tw-captive-check
	$(INSTALL_BIN) ./files/usr/sbin/tw-vpn-health $(1)/usr/sbin/tw-vpn-health
	$(INSTALL_BIN) ./files/usr/sbin/tw-vpn-apply $(1)/usr/sbin/tw-vpn-apply
	$(INSTALL_BIN) ./files/usr/sbin/tw-sub-import $(1)/usr/sbin/tw-sub-import
	$(INSTALL_BIN) ./files/usr/sbin/tw-wifi-apply $(1)/usr/sbin/tw-wifi-apply
	$(INSTALL_BIN) ./files/usr/sbin/tw-upstream $(1)/usr/sbin/tw-upstream
	$(INSTALL_DATA) ./files/usr/lib/travelwizard/common.sh $(1)/usr/lib/travelwizard/common.sh
endef

$(eval $(call BuildPackage,travelwizard))
