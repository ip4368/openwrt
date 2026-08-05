DTS_DIR := $(DTS_DIR)/qcom

# Wrap the kernel FIT in the Qualcomm ELF/MBN container the MBE7000/MBE70 vendor
# U-Boot `bootipq` expects (it parses the ELF program headers, loads the PT_LOAD
# segment to 0x44000000, then bootm's the FIT). The retail MBE7000 `bootipq` (a
# different CBT 7.0.25 build from the MBE70's, verified: 847/786432 bytes differ)
# ships an ELF/MBN-wrapped stock kernel, so a bare FIT is not guaranteed to boot
# there. The wrapper is the QCA-standard superset both bootipq builds accept, so
# one image serves both SKUs. Boot enforces only crc32+sha1 on the FIT (no RSA /
# no MBN-hash check on this path). See MBE7000_FLASHING_PLAN.md.
define Build/mbn-wrap
	$(TOPDIR)/target/linux/qualcommbe/image/mbn-wrap.py $@ $@.mbn
	mv $@.mbn $@
endef

# Append the 256-byte Linksys firmware footer the stock MBE7000 updater checks.
# usr/sbin/fwcc:verify_linksys_header validates ONLY two things: the last 256
# bytes start with the magic ".LINKSYS." (bytes 1-9), and bytes 33-40 hold the
# uppercase-hex POSIX cksum (CRC-32) of everything before the footer. There is
# no cryptographic signature on the flash path, and none on the boot path
# (U-Boot verifies the FIT with crc32+sha1 only). The SKU/version fields are
# filled to mirror the vendor image but are not enforced (fwcc's SKU compare is
# commented out; the kernel/rootfs offset fields are unused on the eMMC flash
# path, which dd's a fixed 8 MiB kernel slot + remainder rootfs slot).
define Build/linksys-mbe7000-footer
	crc="$$(cksum $@ | cut -d' ' -f1)"; \
	hex="$$(printf '%08X' $$crc)"; \
	ftr="$@.lksftr"; \
	head -c 256 /dev/zero > $$ftr; \
	printf '.LINKSYS.'  | dd of=$$ftr bs=1 conv=notrunc 2>/dev/null; \
	printf '01'         | dd of=$$ftr bs=1 seek=9  conv=notrunc 2>/dev/null; \
	printf '8MBE7000'   | dd of=$$ftr bs=1 seek=16 conv=notrunc 2>/dev/null; \
	printf '%s' "$$hex" | dd of=$$ftr bs=1 seek=32 conv=notrunc 2>/dev/null; \
	cat $$ftr >> $@; \
	rm -f $$ftr
endef

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

# The Linksys IPQ9574 mesh routers ship in two hardware-identical SKUs that must
# build as separate targets because their stock bootloaders differ (verified:
# the two 0:APPSBL U-Boots differ, and the retail unit's stock kernel is
# ELF/MBN-wrapped while the MBE70's is a bare FIT):
#
#   * MBE70  (developer/"WRT" variant): `bootipq` boots a BARE FIT. Installed via
#     the vendor OpenWrt-fork LuCI (sysupgrade.bin). This is the verified path.
#   * MBE7000 (retail): `bootipq` expects a Qualcomm ELF/MBN-wrapped kernel (see
#     Build/mbn-wrap). Installed by dd'ing factory.bin onto the inactive A/B slot
#     from a root shell on the stock firmware (webui is GPG-gated).
#
# Distinct compatibles (linksys,mbe70 / linksys,mbe7000) keep each image bound to
# its own unit. Both use config@1: the vendor U-Boot boots with a hardcoded
# `bootm ...#config@1`, so the FIT config node must be exactly "config@1".
# DEVICE_PACKAGES are shared (identical hardware): the QCN9274 PCIe radio needs
# ipq-wifi-linksys_mbe7000's board-2.bin (keyed to qmi-board-id 255), and wifi
# needs CONFIG_CMA=y. See MBE7000_FLASHING_PLAN.md / MBE7000_PORTING_NOTES.md.

define Device/linksys_mbe70
	$(call Device/FitImage)
	$(call Device/EmmcImage)
	DEVICE_VENDOR := Linksys
	DEVICE_MODEL := MBE70
	DEVICE_DTS_CONFIG := config@1
	SOC := ipq9574
	DEVICE_PACKAGES := kmod-ath12k ath12k-firmware-qcn9274 ipq-wifi-linksys_mbe7000 \
		kmod-ath11k-ahb ath11k-firmware-ipq9574-mbe7000
	# Bare-FIT kernel (default FitImage KERNEL). factory.bin is a QSDK multi-image
	# FIT with sections named "hlos" (kernel) + "rootfs" - the format the MBE70's
	# vendor OpenWrt-fork sysupgrade/LuCI recognises (its flash_section flashes
	# hlos->kernel slot, rootfs->rootfs slot; sections it doesn't know, e.g. a
	# plain kernel FIT's kernel-1/fdt-1, are "ignored" and the upgrade aborts).
	# This is the verified vendor-LuCI install image. OpenWrt->OpenWrt afterwards
	# uses sysupgrade.bin (the A/B platform.sh tar path).
	IMAGE/factory.bin := qsdk-ipq-factory-nor
endef
TARGET_DEVICES += linksys_mbe70

define Device/linksys_mbe7000
	$(call Device/FitImage)
	$(call Device/EmmcImage)
	# Wrap the kernel FIT in the vendor ELF/MBN container the retail `bootipq`
	# expects (Build/mbn-wrap). Applies to the kernel in both sysupgrade.bin (tar
	# `kernel` member) and factory.bin (append-kernel).
	KERNEL = kernel-bin | libdeflate-gzip | fit gzip $$(KDIR)/image-$$(DEVICE_DTS).dtb | mbn-wrap
	DEVICE_VENDOR := Linksys
	DEVICE_MODEL := MBE7000
	DEVICE_DTS_CONFIG := config@1
	SOC := ipq9574
	DEVICE_PACKAGES := kmod-ath12k ath12k-firmware-qcn9274 ipq-wifi-linksys_mbe7000 \
		kmod-ath11k-ahb ath11k-firmware-ipq9574-mbe7000
	# Flat vendor-webui install image the stock updater / our dd install expects:
	#   [ ELF/MBN kernel padded to 8 MiB ][ rootfs squashfs ][ 256-byte .LINKSYS. footer ]
	# First 8 MiB -> inactive kernel slot, remainder -> inactive rootfs slot. The
	# footer satisfies fwcc:verify_linksys_header (magic + cksum) but the live
	# retail webui is GPG-gated, so install is via the dd-to-slot script instead.
	IMAGE/factory.bin := append-kernel | check-size 8192k | pad-to 8192k | \
		append-rootfs | pad-to 64k | linksys-mbe7000-footer
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
