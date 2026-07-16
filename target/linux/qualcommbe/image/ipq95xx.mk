DTS_DIR := $(DTS_DIR)/qcom

define Device/8devices_kiwi-dvk
	$(call Device/FitImage)
	$(call Device/EmmcImage)
	DEVICE_VENDOR := 8devices
	DEVICE_MODEL := Kiwi-DVK
	DEVICE_DTS_CONFIG := config@8dev-kiwi
	SOC := ipq9570
	DEVICE_PACKAGES := kmod-ath12k ath12k-firmware-qcn9274 \
		ipq-wifi-8devices_kiwi f2fsck mkf2fs kmod-sfp \
		kmod-phy-maxlinear kmod-phy-realtek rtl826x-firmware
	IMAGE/factory.bin := qsdk-ipq-factory-nor
endef
TARGET_DEVICES += 8devices_kiwi-dvk

define Device/linksys_mbe7000
	$(call Device/FitImage)
	$(call Device/EmmcImage)
	DEVICE_VENDOR := Linksys
	DEVICE_MODEL := MBE7000
	# Vendor U-Boot boots with a hardcoded `bootm ...#config@1` (config_name env),
	# so the FIT's config node must be named exactly "config@1" or the stock
	# bootloader aborts with "Config not available". Confirmed on a live MBE70WRT.
	DEVICE_DTS_CONFIG := config@1
	SOC := ipq9574
	# The QCN9274 PCIe radio needs board-specific data (the stock qcn9274
	# board-2.bin has no entry for this board's qmi-board-id=255). The
	# ipq-wifi-mbe7000 package supplies a board-2.bin built from the vendor
	# BDF + regdb, keyed to board-id 255, and overrides the generic one.
	# Wifi also requires CONFIG_CMA=y (config-6.18) for the fw host memory.
	DEVICE_PACKAGES := kmod-ath12k ath12k-firmware-qcn9274 ipq-wifi-linksys_mbe7000
	# Combined single-file factory image (kernel "hlos" + "rootfs" as named
	# QSDK-FIT sub-images), same as 8devices_kiwi-dvk and the same structure
	# as the MBE70WRT vendor firmware. Overrides the rootfs-only factory.bin
	# that Device/EmmcImage sets by default. Whether the stock (secure-boot)
	# U-Boot will accept it is unconfirmed - see MBE7000_PORTING_NOTES.md.
	IMAGE/factory.bin := qsdk-ipq-factory-nor
endef
TARGET_DEVICES += linksys_mbe7000

define Device/qcom_rdp433
	$(call Device/FitImageLzma)
	DEVICE_VENDOR := Qualcomm Technologies, Inc.
	DEVICE_MODEL := RDP433
	DEVICE_VARIANT := AP-AL02-C4
	BOARD_NAME := ap-al02.1-c4
	DEVICE_DTS_CONFIG := config@rdp433
	DEVICE_DTS_DIR := $(DTS_DIR)
	SOC := ipq9574
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 6096k
	IMAGE_SIZE := 25344k
	IMAGE/sysupgrade.bin := append-kernel | pad-to 64k | append-rootfs | pad-rootfs | check-size | append-metadata
endef
TARGET_DEVICES += qcom_rdp433
