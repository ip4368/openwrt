PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head hexdump'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

#
# Linksys MBE7000 A/B dual-boot.
#
# The vendor U-Boot (bootcmd=bootipq) boots one of two OS slots, selected by the
# "primaryboot" flags in the 0:BOOTCONFIG / 0:BOOTCONFIG1 partitions:
#   offset 128 = HLOS (kernel), offset 148 = rootfs
#   value 0 = slot A: kernel 0:HLOS  (p28), rootfs "rootfs"   (p29), root=mmcblk0p29
#   value 1 = slot B: kernel 0:HLOS_1(p30), rootfs "rootfs_1" (p31), root=mmcblk0p31
# (offset 168 = WIFIFW is left untouched.) The kernel is a raw FIT read from the
# slot's kernel partition and booted as `bootm ...#config@1`.
#
# sysupgrade writes the *inactive* slot and then flips BOOTCONFIG to it, so the
# currently running system is left intact as a fallback (auto_recovery / a
# manual BOOTCONFIG edit can return to it if the new slot fails to boot).
#

mbe7000_boot_slot() {
	local cfgpart
	cfgpart=$(find_mmc_part "0:BOOTCONFIG") || return 1
	[ -e "$cfgpart" ] || return 1
	dd if="$cfgpart" bs=1 count=1 skip=128 2>/dev/null | hexdump -e '"%d"'
}

mbe7000_set_slot() {
	local slot="$1" cfgpart off cur
	for cfgpart in "$(find_mmc_part "0:BOOTCONFIG")" "$(find_mmc_part "0:BOOTCONFIG1")"; do
		[ -e "$cfgpart" ] || continue
		for off in 128 148; do
			cur=$(dd if="$cfgpart" bs=1 count=1 skip="$off" 2>/dev/null | hexdump -e '"%d"')
			[ "$cur" = "$slot" ] && continue
			printf "\\x0${slot}" | \
				dd of="$cfgpart" bs=1 count=1 seek="$off" conv=notrunc 2>/dev/null
		done
	done
	sync
}

platform_check_image() {
	return 0
}

platform_do_upgrade() {
	case "$(board_name)" in
	8devices,kiwi-dvk)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	linksys,mbe70|linksys,mbe7000)
		local active target
		active=$(mbe7000_boot_slot)
		# always write the slot we are NOT running from
		case "$active" in
		0)	target=1; CI_KERNPART="0:HLOS_1"; CI_ROOTPART="rootfs_1" ;;
		1)	target=0; CI_KERNPART="0:HLOS";   CI_ROOTPART="rootfs" ;;
		*)	echo "MBE7000: cannot determine active boot slot (got '$active'); aborting" >&2
			return 1 ;;
		esac
		echo "MBE7000: active slot $active -> writing inactive slot $target ($CI_KERNPART/$CI_ROOTPART)"
		emmc_do_upgrade "$1"
		mbe7000_set_slot "$target"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}

platform_copy_config() {
	case "$(board_name)" in
	8devices,kiwi-dvk|linksys,mbe70|linksys,mbe7000)
		emmc_copy_config
		;;
	esac
}
