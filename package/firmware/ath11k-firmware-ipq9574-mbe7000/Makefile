include $(TOPDIR)/rules.mk

PKG_NAME:=ath11k-firmware-ipq9574-mbe7000
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/ath11k-firmware-ipq9574-mbe7000
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=ath11k firmware for the IPQ9574 on-die 2.4 GHz radio (Linksys MBE7000)
  DEPENDS:=@TARGET_qualcommbe
endef

define Package/ath11k-firmware-ipq9574-mbe7000/description
 Q6 (secure PIL) + WLAN firmware for the IPQ95xx on-die Wi-Fi 6 (QCN5024-class)
 radio, extracted from the Linksys MBE7000 vendor firmware. WIP - see
 MBE7000_ATH11K_24G_BACKPORT.md.
endef

define Build/Compile
endef

define Package/ath11k-firmware-ipq9574-mbe7000/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ9574/hw1.0
	$(INSTALL_DATA) ./files/* $(1)/lib/firmware/ath11k/IPQ9574/hw1.0/
endef

$(eval $(call BuildPackage,ath11k-firmware-ipq9574-mbe7000))
