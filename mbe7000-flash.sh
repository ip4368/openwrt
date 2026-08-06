#!/usr/bin/env bash
#
# mbe7000-flash.sh — install an OpenWrt image onto a Linksys MBE7000 / MBE70
# (A/B eMMC, IPQ9574, vendor CBT U-Boot `bootipq`) over an existing ROOT SSH
# shell, by writing the *inactive* boot slot and flipping to it.
#
# Works on BOTH the stock vendor firmware and a running OpenWrt (slot detection
# via the raw BOOTCONFIG byte + partition lookup by GPT PARTNAME — no dependence
# on vendor-only /proc/boot_info or OpenWrt-only helpers). It NEVER changes
# U-Boot `bootcmd` (that global env is what bricked an earlier unit) and NEVER
# reboots. Only the inactive slot is touched, so U-Boot auto_recovery reverts to
# the intact current slot if the new one fails to boot.
#
# Safe by default: no flags = read-only preflight; --stage = copy+sha256; only
# --commit writes. See MBE7000_FLASHING_PLAN.md for the verified mechanism.
#
# Usage:  ./mbe7000-flash.sh [options]
#   --image PATH   image to install (default: newest built *factory.bin in bin/)
#   --host HOST    device address        (default 192.168.1.1)
#   --port N       ssh port              (default 2222)
#   --user USER    ssh user              (default root)
#   --key PATH     ssh identity file     (optional; if unset, password/agent auth)
#   --known PATH   known_hosts file      (optional)
#   --insecure     ssh with StrictHostKeyChecking=no (for freshly-imaged units)
#   --stage        also copy image to device + verify sha256
#   --commit       WRITE inactive slot + flip to it (implies --stage)
#   --yes          skip the interactive confirm before writing
#   --ignore-secureboot  allow --commit even if the unit has secure boot fused
#                  on (authenticate=1). A custom/unsigned kernel will NOT boot on
#                  such a unit (auto_recovery reverts); only useful for testing
#                  or if your image is signed with the OEM key.
#   -h|--help
#
# The image must be [kernel (bare FIT or ELF/MBN-wrapped), padded to 8 MiB][rootfs
# squashfs][...]; the first 8 MiB go to the kernel slot, the remainder to rootfs
# (the vendor's own count=2/skip=2 split).

set -euo pipefail

IMAGE="" HOST="192.168.1.1" PORT="2222" USER_="root" KEY="" KNOWN="" INSECURE=0
DO_STAGE=0 DO_COMMIT=0 ASSUME_YES=0 IGNORE_SECBOOT=0
REMOTE_IMG="/tmp/mbe7000-flash-image.bin"

while [ $# -gt 0 ]; do case "$1" in
	--image) IMAGE="$2"; shift 2 ;;
	--host)  HOST="$2";  shift 2 ;;
	--port)  PORT="$2";  shift 2 ;;
	--user)  USER_="$2"; shift 2 ;;
	--key)   KEY="$2";   shift 2 ;;
	--known) KNOWN="$2"; shift 2 ;;
	--insecure) INSECURE=1; shift ;;
	--stage) DO_STAGE=1; shift ;;
	--commit) DO_COMMIT=1; DO_STAGE=1; shift ;;
	--yes)   ASSUME_YES=1; shift ;;
	--ignore-secureboot) IGNORE_SECBOOT=1; shift ;;
	-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac; done

log()  { printf '\033[1;36m[flash]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

SSH=(ssh -o ConnectTimeout=10)
[ -n "$KEY" ]   && SSH+=(-i "$KEY")
[ -n "$KNOWN" ] && SSH+=(-o UserKnownHostsFile="$KNOWN")
[ "$INSECURE" -eq 1 ] && SSH+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH+=(-p "$PORT" "$USER_@$HOST")
SCP=(scp -P "$PORT" -o ConnectTimeout=10)
[ -n "$KEY" ]   && SCP+=(-i "$KEY")
[ -n "$KNOWN" ] && SCP+=(-o UserKnownHostsFile="$KNOWN")
[ "$INSECURE" -eq 1 ] && SCP+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
sshd() { "${SSH[@]}" "$@"; }

# Remove the staged /tmp image on exit (only if we ever staged one). The slot
# is written directly from it, so it's redundant once we're done; --commit
# re-copies fresh anyway. Guarded so a read-only preflight does no extra SSH.
cleanup() { [ "$DO_STAGE" -eq 1 ] && "${SSH[@]}" "rm -f $REMOTE_IMG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ---- locate + validate image (host side) ------------------------------------
if [ -z "$IMAGE" ]; then
	IMAGE=$(ls -t bin/targets/qualcommbe/*/*linksys_mbe7000-squashfs-factory.bin 2>/dev/null | head -1 || true)
fi
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || die "image not found (use --image PATH)"
IMG_SIZE=$(stat -c%s "$IMAGE")
KMAGIC=$(dd if="$IMAGE" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
RMAGIC=$(dd if="$IMAGE" bs=4 skip=$((8*1024*1024/4)) count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
case "$KMAGIC" in
	d00dfeed) KTYPE="bare FIT" ;;
	7f454c46) KTYPE="ELF/MBN-wrapped" ;;
	*) die "image does not start with a FIT (d00dfeed) or ELF (7f454c46); got $KMAGIC" ;;
esac
[ "$RMAGIC" = "68737173" ] || die "no squashfs (hsqs) at 8 MiB; got $RMAGIC — wrong image layout"
[ "$IMG_SIZE" -gt $((8*1024*1024)) ] || die "image smaller than the 8 MiB kernel slot"
HOST_KSHA=$(dd if="$IMAGE" bs=4M count=2 2>/dev/null | sha256sum | cut -d' ' -f1)
HOST_RSHA=$(dd if="$IMAGE" bs=4M skip=2 2>/dev/null | sha256sum | cut -d' ' -f1)
HOST_FULLSHA=$(sha256sum "$IMAGE" | cut -d' ' -f1)
ROOT_BYTES=$((IMG_SIZE - 8*1024*1024))
log "image: $IMAGE ($IMG_SIZE bytes, kernel=$KTYPE)"

# =============================================================================
# STAGE 1 — preflight (read-only). Environment-agnostic: raw BOOTCONFIG byte +
# PARTNAME lookup. Works on stock vendor fw AND on a running OpenWrt.
# =============================================================================
log "connecting to $USER_@$HOST:$PORT ..."
PROBE=$(sshd 'sh -s' <<'REMOTE'
# resolve a GPT partition device by PARTNAME (no vendor/OpenWrt helpers needed)
part_by_name() {
	local uev name
	for uev in /sys/class/block/mmcblk*p*/uevent; do
		name=$(sed -n 's/^PARTNAME=//p' "$uev" 2>/dev/null)
		[ "$name" = "$1" ] && { echo "/dev/$(basename "$(dirname "$uev")")"; return 0; }
	done
	return 1
}
model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')
board=$(cat /tmp/sysinfo/board_name 2>/dev/null)
osrel=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")
[ -z "$osrel" ] && osrel="stock/$(cat /etc/version 2>/dev/null)"

bc0=$(part_by_name 0:BOOTCONFIG)
bc1=$(part_by_name 0:BOOTCONFIG1)
ka=$(part_by_name 0:HLOS);   ra=$(part_by_name rootfs)     # slot A
kb=$(part_by_name 0:HLOS_1); rb=$(part_by_name rootfs_1)   # slot B

# active slot (0=A, 1=B): prefer the kernel's boot_info view (authoritative on
# vendor fw where it owns the live copy); fall back to the raw BOOTCONFIG
# primaryboot byte via whichever hex tool exists (od or hexdump). Read BOTH the
# HLOS pointer (@128) and the rootfs pointer (@148) so the host side can refuse
# to run if a prior half-completed flip left them disagreeing.
read_pb() { # $1 = boot_info node (0:HLOS|rootfs), $2 = raw BOOTCONFIG byte offset
	if [ -r "/proc/boot_info/bootconfig0/$1/primaryboot" ]; then
		cat "/proc/boot_info/bootconfig0/$1/primaryboot" 2>/dev/null | tr -cd '0-9'
	else
		dd if="$bc0" bs=1 skip="$2" count=1 2>/dev/null | { od -An -tu1 2>/dev/null || hexdump -v -e '1/1 "%d"' 2>/dev/null; } | tr -cd '0-9'
	fi
}
active=$(read_pb 0:HLOS 128)
active_r=$(read_pb rootfs 148)

bootcmd=$(fw_printenv -n bootcmd 2>/dev/null || echo "?")
bootpart=$(fw_printenv -n boot_part 2>/dev/null || echo "?")
tmpfree=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')
caps=""
[ -f /usr/sbin/switch_boot_image ] && caps="${caps}vendor "
command -v mbe7000-bootslot >/dev/null 2>&1 && caps="${caps}openwrt "
[ -d /proc/boot_info ] && caps="${caps}boot_info "

# secure-boot fuse state: the QCA qfprom driver exposes a world-readable
# 'authenticate' node = "1" when OEM secure boot is fused ON (kernel MBN is
# RSA-authenticated against the QFPROM root-key hash -> an unsigned custom kernel
# will not boot). "?" if the node isn't present (non-QCA / no driver).
secboot="?"
for n in /sys/devices/system/qfprom/qfprom0/authenticate \
         /sys/devices/*/qfprom*/qfprom0/authenticate; do
	[ -r "$n" ] || continue
	v=$(cat "$n" 2>/dev/null | tr -cd '0-9' | cut -c1)
	[ -n "$v" ] && { secboot="$v"; break; }
done

echo "MODEL=$model"
echo "BOARD=$board"
echo "OS=$osrel"
echo "ACTIVE=$active"
echo "ACTIVE_R=$active_r"
echo "BOOTCMD=$bootcmd"
echo "BOOT_PART=$bootpart"
echo "BC0=$bc0"; echo "BC1=$bc1"
echo "KA=$ka"; echo "RA=$ra"; echo "KB=$kb"; echo "RB=$rb"
echo "TMP_FREE_KB=$tmpfree"
echo "CAPS=$caps"
echo "SECBOOT=$secboot"
REMOTE
)
echo "$PROBE" | sed 's/^/    /'
get() { echo "$PROBE" | sed -n "s/^$1=//p"; }
MODEL=$(get MODEL); OS=$(get OS); ACTIVE=$(get ACTIVE); BOOTCMD=$(get BOOTCMD)
ACTIVE_R=$(get ACTIVE_R); SECBOOT=$(get SECBOOT)
BC0=$(get BC0); BC1=$(get BC1); CAPS=$(get CAPS); TMP_FREE_KB=$(get TMP_FREE_KB)
KA=$(get KA); RA=$(get RA); KB=$(get KB); RB=$(get RB)

# ---- safety gates + target selection ----------------------------------------
case "$MODEL" in *MBE70*|*IPQ9574*) ;; *) warn "model not recognised: '$MODEL'";; esac
[ "$BOOTCMD" = "bootipq" ] || die "bootcmd is '$BOOTCMD', not 'bootipq' — refusing (env may be modified; brick risk)"
[ -n "$BC0" ] || die "0:BOOTCONFIG not found"
[ "$ACTIVE" = "$ACTIVE_R" ] || die "inconsistent boot pointer: HLOS=$ACTIVE rootfs=$ACTIVE_R — refusing (a prior flip may be half-done; fix the slot pointers first)"
case "$ACTIVE" in
	0) NEWSLOT=1; NEWBOOTPART=2; KDEV="$KB"; RDEV="$RB"; ADESC="A (0:HLOS/rootfs)"; TDESC="B (0:HLOS_1/rootfs_1)" ;;
	1) NEWSLOT=0; NEWBOOTPART=1; KDEV="$KA"; RDEV="$RA"; ADESC="B (0:HLOS_1/rootfs_1)"; TDESC="A (0:HLOS/rootfs)" ;;
	*) die "could not read active slot from BOOTCONFIG (got '$ACTIVE')" ;;
esac
[ -n "$KDEV" ] && [ -n "$RDEV" ] || die "could not resolve target partitions (k=$KDEV r=$RDEV)"
ok "OS: $OS"
ok "active slot: $ADESC  ->  will write INACTIVE slot: $TDESC   [$KDEV + $RDEV]"
[ -n "$TMP_FREE_KB" ] && [ "$TMP_FREE_KB" -gt $((IMG_SIZE/1024 + 4096)) ] || warn "/tmp free ${TMP_FREE_KB:-?}KB may be tight for $((IMG_SIZE/1024))KB image"

# secure-boot gate: a fused unit (authenticate=1) RSA-authenticates the kernel MBN
# against the OEM key in QFPROM, so a non-OEM-signed image cannot boot (proven on
# the retail MBE7000: written+flipped fine, then auto_recovery reverted). Writing
# is still non-bricking, just futile — so warn always and refuse --commit unless
# explicitly overridden. See MBE7000_RETAIL_FLASHING.md.
case "$SECBOOT" in
	1) warn "SECURE BOOT FUSED ON (authenticate=1): kernel MBN is RSA-authenticated against the OEM key in QFPROM."
	   warn "  A non-OEM-signed (custom OpenWrt) kernel will NOT boot here — auto_recovery reverts to the current slot." ;;
	0) ok "secure boot fuse off (authenticate=0): unsigned kernels are permitted to boot." ;;
	*) warn "secure-boot fuse state unknown (authenticate='$SECBOOT'; no qfprom node) — cannot confirm a custom kernel will boot." ;;
esac
if [ "$DO_COMMIT" -eq 1 ] && [ "$SECBOOT" = "1" ] && [ "$IGNORE_SECBOOT" -eq 0 ]; then
	die "refusing --commit: secure boot is fused ON and this image is not OEM-signed → it cannot boot (would just waste the inactive slot; auto_recovery reverts). Re-run with --ignore-secureboot only if your image is OEM-signed or you're testing."
fi

if [ "$DO_STAGE" -eq 0 ]; then
	echo; ok "PREFLIGHT ONLY — nothing copied or written."
	log "next: --stage to copy+verify, or --commit to install."
	exit 0
fi

# =============================================================================
# STAGE 2 — copy + verify sha256
# =============================================================================
log "copying image to $HOST:$REMOTE_IMG ..."
"${SCP[@]}" "$IMAGE" "$USER_@$HOST:$REMOTE_IMG"
DEV_FULLSHA=$(sshd "sha256sum $REMOTE_IMG | cut -d' ' -f1")
[ "$DEV_FULLSHA" = "$HOST_FULLSHA" ] || die "staged sha256 mismatch (host=$HOST_FULLSHA dev=$DEV_FULLSHA)"
ok "staged image verified (sha256 $DEV_FULLSHA)"
if [ "$DO_COMMIT" -eq 0 ]; then
	echo; ok "STAGED ONLY — nothing written."
	log "next: --commit to write slot $TDESC and flip to it."
	exit 0
fi

# =============================================================================
# STAGE 3 — write inactive slot, verify, flip (NO reboot)
# =============================================================================
echo
warn "WRITE inactive slot and flip boot pointer:"
warn "   image : $IMAGE ($KTYPE kernel)"
warn "   device: $USER_@$HOST   $KDEV + $RDEV   (slot $TDESC)"
warn "   running slot ($ADESC) left intact; bootcmd untouched; NO reboot."
if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Type "flash" to proceed: '; read -r ans
	[ "$ans" = "flash" ] || die "aborted by user"
fi

log "writing kernel slot ($KDEV) ..."
sshd "dd if=$REMOTE_IMG of=$KDEV bs=4M count=2 conv=fsync" 2>&1 | sed 's/^/    /'
log "writing rootfs slot ($RDEV) ..."
sshd "dd if=$REMOTE_IMG of=$RDEV bs=4M skip=2 conv=fsync" 2>&1 | sed 's/^/    /'

log "verifying written slots ..."
DEV_KSHA=$(sshd "dd if=$KDEV bs=4M count=2 2>/dev/null | sha256sum | cut -d' ' -f1")
DEV_RSHA=$(sshd "head -c $ROOT_BYTES $RDEV 2>/dev/null | sha256sum | cut -d' ' -f1")
[ "$DEV_KSHA" = "$HOST_KSHA" ] || die "kernel slot verify FAILED (host=$HOST_KSHA dev=$DEV_KSHA) — NOT flipping"
[ "$DEV_RSHA" = "$HOST_RSHA" ] || die "rootfs slot verify FAILED (host=$HOST_RSHA dev=$DEV_RSHA) — NOT flipping"
ok "kernel slot verified ($DEV_KSHA)"
ok "rootfs slot verified ($DEV_RSHA)"

log "flipping boot pointer to slot $TDESC (no reboot) ..."
sshd "NEWSLOT=$NEWSLOT NEWBOOTPART=$NEWBOOTPART BC0='$BC0' BC1='$BC1' sh -s" <<'REMOTE'
# 1) raw primaryboot bytes @128 (HLOS) and @148 (rootfs) in both BOOTCONFIG copies
#    (proven mechanism; U-Boot bootipq reads these). Works on stock and OpenWrt.
for dev in "$BC0" "$BC1"; do
	[ -e "$dev" ] || continue
	for off in 128 148; do
		printf "\\x0${NEWSLOT}" | dd of="$dev" bs=1 count=1 seek="$off" conv=notrunc 2>/dev/null
	done
done
# 2) if the kernel exposes the vendor boot_info interface, use it as the
#    AUTHORITATIVE flip: set primaryboot then persist the driver-generated
#    BOOTCONFIG binary (getbinary_bootconfig). This is required on vendor
#    firmware (stock retail MBE7000 AND the MBE70 19.07 build) where the driver
#    owns the live copy and the raw poke above is a no-op. bootconfig0 maps to
#    0:BOOTCONFIG, bootconfig1 to 0:BOOTCONFIG1.
if [ -d /proc/boot_info ]; then
	for bc in bootconfig0 bootconfig1; do
		echo "$NEWSLOT" > /proc/boot_info/$bc/0:HLOS/primaryboot 2>/dev/null || true
		echo "$NEWSLOT" > /proc/boot_info/$bc/rootfs/primaryboot 2>/dev/null || true
	done
	[ -e "$BC0" ] && cat /proc/boot_info/bootconfig0/getbinary_bootconfig > "$BC0" 2>/dev/null
	[ -e "$BC1" ] && cat /proc/boot_info/bootconfig1/getbinary_bootconfig > "$BC1" 2>/dev/null
	sync
fi
# 3) keep U-Boot text env in sync (bootcmd left ALONE)
fw_setenv boot_part_ready 3 2>/dev/null || true
fw_setenv boot_part "$NEWBOOTPART" 2>/dev/null || true
sync
echo "flip done: primaryboot=$NEWSLOT boot_part=$NEWBOOTPART"
REMOTE
ok "boot pointer flipped to slot $TDESC"

echo; ok "INSTALL COMPLETE (not yet rebooted)."
ORIG_SLOT_ARG=$([ "$ACTIVE" = 0 ] && echo a || echo b)
cat <<EOF

Next steps (run when ready):
  * Boot the new slot:   ${SSH[*]} 'sync; reboot'
  * If it fails to boot, U-Boot auto_recovery reverts to the intact slot
    ($ADESC) automatically (bootcmd untouched).
  * Roll back the flip BEFORE rebooting (return to slot $ADESC):
      ${SSH[*]} 'for d in $BC0 $BC1; do for o in 128 148; do printf "\\x0$ACTIVE" | dd of=\$d bs=1 count=1 seek=\$o conv=notrunc 2>/dev/null; done; done; fw_setenv boot_part $([ "$ACTIVE" = 0 ] && echo 1 || echo 2) 2>/dev/null; sync'
    (on OpenWrt you can also just run:  mbe7000-bootslot $ORIG_SLOT_ARG )
EOF
