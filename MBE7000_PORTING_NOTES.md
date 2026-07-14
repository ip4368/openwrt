# Linksys MBE7000 (Velop Pro 7 BE11000) — porting notes

Branch: `linksys_mbe7000`. Status: DTS + device Makefile entry written and
**DTS-compiles** against this tree's real patched kernel source (a full
initramfs/sysupgrade image has also been built). **Not yet booted on real
hardware.** Note: "compiles" only proves DT *syntax* - it does not validate
DT properties against the drivers. A code review on 2026-07-11 found a
driver-level bug that a compile cannot catch (wrong PPE clock/reset names)
plus other gaps; see "Post-review fixes" below.

## Summary

- SoC: Qualcomm IPQ9554 (per the user; the reference design and vendor
  firmware both actually identify as IPQ9574 - see "SoC identity" below).
- No new OpenWrt subtarget was needed. `target/linux/qualcommbe/ipq95xx`
  already covers the whole IPQ95xx family (hosts `8devices_kiwi-dvk` and
  `qcom_rdp433`). IPQ9554 has no dedicated upstream `.dtsi`; like the open
  Xiaomi BE7000 PR (openwrt/openwrt#20604, also IPQ9554), this port builds
  on `ipq9574.dtsi`, which is register/pin compatible.
- The board turns out to be a near-stock Qualcomm **IPQ9574/AP-AL02-C4**
  reference design (see "Vendor firmware teardown" below) - electrically
  close to the already-supported `qcom_rdp433` device.

## Files changed

- `target/linux/qualcommbe/dts/ipq9574-mbe7000.dts` (new) - the board DTS
  (incl. eMMC/`sdhc_1` config, PPE port clock/reset names, and a `pwm-leds`
  RGBW status LED - see "Post-review fixes").
- `target/linux/qualcommbe/image/ipq95xx.mk` - added `Device/linksys_mbe7000`
  (`FitImage` + `EmmcImage`, `SOC := ipq9574`,
  `kmod-ath12k ath12k-firmware-qcn9274`, and
  `IMAGE/factory.bin := qsdk-ipq-factory-nor` for a combined kernel+rootfs
  factory image - see "Post-review fixes").
- `target/linux/qualcommbe/ipq95xx/base-files/etc/board.d/02_network` - added
  `linksys,mbe7000` case: `lan1 lan2 lan3 lan4` + `wan`.
- `target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh` -
  added `linksys,mbe7000` case, modeled on `8devices,kiwi-dvk`
  (`CI_KERNPART="0:HLOS"`, `CI_ROOTPART="rootfs"`, `emmc_do_upgrade`).

## How the hardware facts were established

1. **GPL source dump was a dead end.** Linksys publishes a GPL compliance
   tarball at
   `https://downloads.linksys.com/support/assets/gpl/MBE7000_v1.0.14.216607.tgz`
   (~650 MB). It only contains generic upstream GPL packages (busybox,
   dnsmasq, a vanilla `linux-5.4.213.tar.xz`, etc.) - no board-specific
   kernel patches, no DTS, no BSP. Qualcomm's proprietary QSDK/NSS bits
   aren't in there.

2. **Decompiled the actual vendor firmware image instead.** Found an older
   firmware build (`MBE7000_1.0.10.215314`) mirrored on archive.org:
   `https://archive.org/download/Linksys_MBE7000_1.0.10.215314_41f25/41f25658f0b8abf6addb0a4f26e6db86.img`
   (~47 MB). `binwalk` identified a U-Boot FIT image inside. Extraction:
   ```
   dd if=firmware.img of=fit.itb bs=1 skip=12288 count=5359780
   dumpimage -T flat_dt -p 1 -o extracted.fdt fit.itb   # pulls out the fdt@1 sub-image
   dtc -I dtb -O dts -f extracted.fdt -o extracted.dts
   ```
   This gave the **real, shipped kernel device tree** the router boots with
   on that firmware version. That's where the confirmed facts below (eMMC,
   button GPIOs, UART pins, PCIe wifi usage, ethernet topology) come from.

3. **Cross-checked against this tree's own patched kernel source.** Ran
   `make target/linux/prepare` to fetch + patch the actual Linux 6.18 tree
   this OpenWrt target builds, then compiled the new
   `ipq9574-mbe7000.dts` directly against the real patched
   `arch/arm64/boot/dts/qcom/ipq9574.dtsi` with `dtc` (not just a
   downloaded/generic copy). Also read the real, already-upstream
   `ipq9574-rdp433.dts` / `ipq9574-rdp-common.dtsi` from that same prepared
   tree to get the exact label names, WAN-port pattern (discrete PHY over
   `pcs2`/UNIPHY2), etc. This is how the ethernet port mapping got fixed
   after the first pass was wrong (see "Corrections made" below).

### SoC identity

Vendor firmware's DT says `model = "Qualcomm Technologies, Inc.
IPQ9574/AP-AL02-C4"`, `compatible = "qcom,ipq9574-ap-al02-c4", ...`. The
user is confident the physical chip on the board is marked IPQ9554 (a
lower-binned/cheaper variant in the same family - quad Cortex-A73, just
lower clock and fewer MU-MIMO streams than IPQ9574). This is consistent
with the Xiaomi BE7000 precedent: that device is also documented as
IPQ9554 but its accepted OpenWrt DTS still declares
`compatible = "xiaomi,be7000", "qcom,ipq9574"` and includes
`ipq9574.dtsi`, because upstream Linux has no separate `ipq9554.dtsi` and
the two are pin/register compatible. Same approach used here.

## Confirmed facts (from the vendor firmware DT dump)

- **Storage: eMMC**, not NAND. The vendor DT has `nand@79b0000` present but
  `status = "disabled"`, while `sdhci@7804000`/`sdcc1ice@7808000` are
  `status = "ok"`, non-removable, 8-bit bus. This matters - the Xiaomi
  BE7000 template (the closest prior art) uses NAND/UBI, which would have
  been the wrong storage backend to copy. `qcom_rdp433` (already in this
  tree) also uses eMMC, which is what this port's `Device/EmmcImage`
  mirrors.
- **UART console**: `blsp1_uart2`, pins gpio34/gpio35 (`function =
  "blsp2_uart"`), matches the `uart2_pins` group already predefined in
  mainline `ipq9574.dtsi` - no need to redefine it in the board DTS.
- **Buttons**: reset = gpio40, WPS = gpio37, both `bias-pull-up` (i.e.
  active-low).
- **PCIe wifi radios**: 4 PCIe root complexes exist on the SoC
  (`pcie0`@28000000 through `pcie3`@18000000). Vendor firmware has
  `pcie1`@10000000 and `pcie2`@20000000 `status = "ok"` with an attached
  `wifi@1`/`wifi@2` node each; `pcie0` is disabled/unpopulated; `pcie3` has
  a `wifi@3` child node present but is `status = "disabled"` in this
  firmware build. Perst GPIOs: pcie1=gpio26, pcie2=gpio29, pcie3=gpio32
  (from the `pciN-pinmux` groups). This port enables pcie1 + pcie2 and
  leaves pcie3 disabled, matching the vendor's own choice - it's unclear
  whether pcie3 is simply unpopulated hardware or just software-disabled
  on this (Feb 2024) firmware build.
- **On-die 2.4 GHz radio** (`wifi@c0000000`, `qcom,cnss-qca9574`) is
  enabled in the vendor firmware, but this OpenWrt tree's `ipq9574.dtsi`
  patches don't add any such on-die wifi node yet (checked: no patch in
  `target/linux/qualcommbe/patches-6.18/` touches `cnss`/on-die wifi), so
  it's **left out** of this DTS - not a regression, just not supported by
  this tree yet.
- **Ethernet: 4 LAN + 1 WAN** (confirmed against user's physical port
  count). The vendor DT's mdio bus has PHYs at raw addresses `0x10-0x13`
  (4 sequential addresses matching a 4-port switch package) plus one more
  at `0x1c` (28) - a separate, non-sequential address, i.e. a discrete
  PHY chip, not part of the 4-port package. The vendor `ess-switch` node's
  clock list has `uniphy0_port1..5_*` clocks (ports 1-5, all on UNIPHY0)
  and separately `uniphy2_port6_*` clocks (port 6 on UNIPHY2) - port 6 is
  electrically distinct from ports 1-5, and it's that discrete PHY on the
  separate UNIPHY that provides WAN. This exactly matches how the
  already-upstream `qcom_rdp433`/`ipq9574-rdp433.dts` wires its own WAN
  port (`port@6`, `phy-mode = "usxgmii"`, `pcs-handle = <&pcs2_ch0>`, a
  discrete clause-45 PHY) - this port's `port@6`/`wan` was modeled
  directly on that. The `phy-reset-gpio` property in the vendor DT
  decodes to two GPIOs: tlmm60 (matches `&mdio`'s `reset-gpios`, the
  4-port switch package's reset) and tlmm36 (used here as the discrete WAN
  PHY's own `reset-gpios`).
- **No `gpio-leds` node** in the vendor kernel DT - but this turned out to
  be a red herring: the MBE70WRT teardown (see below) shows the status LEDs
  are **PWM RGBW** (`pwm-leds`: pwm:red/green/blue/white on
  `qti,ipq9574-pwm`), not GPIO and not the K32W061. The board does still
  carry an NXP K32W061 (Zigbee/Thread coprocessor) on UART4 (gpio50-53,
  reset gpio31, isp gpio57, PTA/coex pins gpio54-56), just not for the
  LEDs. Now wired up in this DTS as `pwm-leds` (see "Post-review fixes").
- Regulators/USB/clocks sections were adapted from the Xiaomi BE7000
  pattern (fixed 3.3V/0.925V regulators for USB PHY, `rpm_requests`
  regulators block, `ref_48mhz_clk`/`xo_board_clk`/`xo_clk` trim) rather
  than the vendor's own QSDK-style regulator setup (`cpr4-ipq9574-apss`,
  dummy-regulators), since the vendor's scheme doesn't match what this
  tree's mainline-style `ipq9574.dtsi` expects.

## Corrections made mid-port

The first pass copied the Xiaomi BE7000 dts's 4-port ethernet block
verbatim and mislabeled `port@1` as `"wan"` with `port@2-4` as
`"lan1-3"` (3 LAN + 1 WAN = 4 total ports). The user, going from the
physical unit, said it's **4 LAN + 1 WAN** (5 total ports). Re-examining
the vendor DT (see "Ethernet" above) confirmed the user was right: all 4
switch-package ports are LAN, and WAN is a *5th, separate* discrete PHY
port that the first pass had missed entirely. Fixed by relabeling
`port@1-4` as `lan1-4` and adding a new `port@6` for WAN per the
`qcom_rdp433` pattern. Re-validated against the real patched
`ipq9574.dtsi` afterward - clean compile.

## Post-review fixes (2026-07-11)

A review cross-checked the DTS against this tree's actual drivers (not just
the compiler) and fixed three concrete defects:

1. **PPE clock/reset names were wrong - this broke ALL wired ethernet
   (both LAN and WAN).** The `ethernet-ports` block had been written with
   QSDK downstream names `clock-names/reset-names = "port_mac", "port_rx",
   "port_tx"`, but this tree's mainline PPE driver
   (`drivers/net/ethernet/qualcomm/ppe/ppe_port.c`) looks the clocks/resets
   up by the fixed names `"mac"`, `"rx"`, `"tx"` (`ppe_port_clk_rst_name[]`),
   via `of_clk_get_by_name()` / `of_reset_control_get_exclusive()`. A
   mismatch makes `ppe_port_clock_init()` fail, which aborts the whole PPE
   port init - i.e. no ethernet interfaces at all. A DTS compile can't catch
   this because clock-names is just a string list. Fixed to `"mac"/"rx"/"tx"`
   on all five ports (matches the in-tree, working `ipq9574-rdp433.dts`).
   The `NSS_CC_PORT*_*` clock *references* were already correct; only the
   names were wrong.

2. **`&sdhc_1` (eMMC) was incomplete.** It only had `status = "okay"` - no
   `bus-width`, no HS200/HS400 modes, and crucially no `pinctrl` (and no SDC
   pin group under `&tlmm`). As written the eMMC would not come up, which
   would block booting from flash and any sysupgrade/factory install. Filled
   in from the kiwi-dvk pattern (8-bit, HS400-ES, `sdc_default_state` pin
   group on gpio0-10), plus `non-removable` since the vendor DT marks the
   eMMC non-removable. This does not affect a RAM/initramfs boot, only
   persistent install.

3. **Wi-Fi firmware package was missing.** `DEVICE_PACKAGES` had only
   `kmod-ath12k` (the driver) but not `ath12k-firmware-qcn9274` (the actual
   radio firmware). Added. **Still missing: board-specific calibration data.**
   ath12k needs a matching BDF in `board-2.bin`; an `ipq-wifi-linksys_mbe7000`
   package (board-2.bin extracted from vendor firmware) still has to be
   created - the stock qcn9274 board-2.bin is unlikely to match. Until then
   the two PCIe radios probably won't calibrate/come up. The on-die 2.4 GHz
   radio remains unsupported by this tree regardless (see below), so full
   tri-band is not achievable here yet.

4. **PWM RGBW status LED wired up** (added after the MBE70WRT teardown
   identified it). Added a `pwm-leds` node (red/green/blue/white on PWM
   channels 0-3), a `pwm_pins` pinctrl group (gpio44-47, function `"pwm"`),
   and enabled `&pwm`. Uses the mainline 3-cell `pwms` form
   (`<&pwm ch 1250000 0>`). Unverified on hardware: LED polarity (assumed
   active-high; flip to `PWM_POLARITY_INVERTED` if common-anode) and whether
   the driver's channel index truly maps ch0->gpio44 etc. as the vendor DT
   implies (it should, given the `8*ch` register stride).

5. **Combined single-file factory image.** `Device/EmmcImage`'s default
   `factory.bin` is rootfs-only (`append-rootfs | pad-rootfs | pad-to 64k`),
   so it is *not* a complete install image - it carries no kernel. Added
   `IMAGE/factory.bin := qsdk-ipq-factory-nor` (as `8devices_kiwi-dvk`
   does), which instead emits a QSDK-format FIT bundling two named
   sub-images, `hlos` (the kernel `.itb`) and `rootfs` (the squashfs) - one
   file that a QSDK-derived U-Boot flashes to the HLOS and rootfs partitions
   in one shot. This is the same container structure as the extracted
   MBE70WRT vendor firmware (`hlos` + `rootfs` + `wifi_fw*` sub-images). Note
   this only changes what we *produce*; it does not defeat secure boot. On a
   retail MBE7000 the stock/loader path will still reject it unless the
   bootloader is made permissive. It exists so a single combined image is
   ready if/when that becomes possible. Install on this eMMC board otherwise
   remains: serial -> U-Boot -> TFTP the initramfs `.itb` -> `sysupgrade`.

After these fixes the DTS still compiles cleanly (only pre-existing upstream
`ipq9574.dtsi` i2c/spi unit-address warnings), and the compiled dtb was
verified to carry `clock-names = "mac", "rx", "tx"` on the ports plus the
enabled `pwm`/`pwm-leds` nodes.

## Secure boot / flashing (important - may block installation entirely)

The newer official firmware
(`FW_MBE7000_1.0.14.216607_prod.signed.img`) was inspected directly. It is
**not** a bare FIT: it's a **Qualcomm authenticated-boot ELF image**. Three
program headers; the `LOAD` segment at file offset `0x3000` (load addr
`0x44000000`) is the FIT (`d00dfeed` magic sits exactly at offset 12288),
and it is preceded by a segment containing an **X.509 DER certificate chain
(SEQUENCE at offset 4664) plus an RSA signature** over the segment hashes.
That is precisely the format the Qualcomm PBL -> SBL -> TZ -> U-Boot
secure-boot chain authenticates, and the literal `prod.signed` in the name
matches. For a 2024 commercial mesh router this strongly implies the QFPROM
secure-boot fuses are blown and the boot chain enforces signatures.

**However, there is a second SKU: the MBE70WRT ("Velop WRT Pro 7"), the
developer/OpenWrt variant.** Its firmware
(`FW_MBE70WRT_v1.2.0.15.img`) was also inspected: it is a **raw, UNSIGNED
U-Boot FIT** (starts directly with `d00dfeed` at offset 0 - no ELF wrapper,
no cert chain). That is strong evidence the **WRT variant does not enforce
secure boot** and will boot/flash unsigned images. So:
- If the unit in hand is (or can run) the **MBE70WRT**, an unsigned OpenWrt
  image very likely boots - this is the good case.
- If it is the **retail MBE7000**, the signed-ELF evidence says secure boot
  is probably enforced and unsigned images are rejected. The two SKUs are
  different here; do not assume the retail unit inherits the WRT's openness.
  Confirm which bootloader posture the actual unit has (serial console).

Consequences for the retail MBE7000 (unconfirmed on hardware, likely posture):
- **Flashing an OpenWrt image via the stock updater/sysupgrade path will be
  rejected** - it validates that signature and our image is unsigned.
- **The U-Boot serial console may itself be locked** (`CONSOLE_STATE=locked`
  is a documented Linksys practice). If so there is no TFTP path either.
- **Even with an open U-Boot, a `tftpboot`+`bootm` of our unsigned FIT may be
  authenticated and rejected.** Some Qualcomm U-Boots only enforce auth on
  the flash-boot path and will `bootm` an unsigned RAM image - that is the
  one crack where the initramfs test might succeed - but it is device-
  specific and unknowable without the unit on serial.
- This is the key way the MBE7000 likely differs from the Xiaomi BE7000
  precedent: the BE7000 is installable because its secure boot is not
  enforced the same way. Do not assume "initramfs boots fine over TFTP" on
  the BE7000 carries over here. **Treat persistent installation as blocked
  until fuse/console status is confirmed on real hardware.**

## MBE70WRT firmware teardown (2026-07-11) - confirmed hardware facts

Decompiled the OpenWrt-variant firmware `FW_MBE70WRT_v1.2.0.15.img` (a raw
FIT). It bundles a `flash.scr`, two QSDK wifi-firmware squashfs partitions,
the HLOS kernel FIT, and a 35 MB rootfs squashfs. The **HLOS FIT embeds the
real, shipped board DTS** (QSDK 5.4, `model = "Qualcomm Technologies, Inc.
IPQ9574/AP-AL02-C4"`, `compatible = "qcom,ipq9574-ap-al02-c4", ...`).
Extracted artifacts saved to `/home/daniel/mbe7000_wrt_extract/`
(`mbe70wrt_real_board.dts` + the raw `bdwlan*` board-data files).

Confirmed from that real DTS:
- **Ethernet matches this port's DTS.** MDIO PHYs at `0x10-0x13` (4-port
  switch package) + a discrete PHY at `0x1c` = WAN. `phy-reset-gpio`
  decodes to gpio60 (switch) and gpio36 (WAN PHY) - exactly what the
  MBE7000 DTS already uses. WAN-via-0x1c is now confirmed, not inferred.
- **PCIe radios: pcie1 + pcie2 `status = "ok"` with wifi@1/wifi@2; pcie3
  `status = "disabled"`** - matches this port's choice exactly (pcie3 left
  off). pcie0 unused.
- **Radios are QCN9224** (Wi-Fi 7), per the `qcn9224` firmware dirs and
  `qcn9000_qcn9224_v2_dualmac` partition. NOTE: this port's DTS currently
  declares the PCIe wifi as `pci17cb,1109` (QCN9274). QCN9224 is closely
  related and is believed to enumerate in the same 0x1109 family, but the
  actual PCI device-id must be confirmed on hardware; if it differs, both
  the `compatible` and the firmware package need changing.
- **On-die 2.4 GHz radio** is `wifi@c0000000`, `"qcom,cnss-qca9574"` -
  confirmed present and enabled in vendor fw, still unsupported by mainline
  ath12k in this tree. Left out (correct).
- **LEDs are PWM RGBW, NOT the K32W061 guess** - and are now **wired up**
  (see "Post-review fixes"). Vendor DT: red=ch0/gpio44, green=ch1/gpio45,
  blue=ch2/gpio46, white=ch3/gpio47, period 1250000 ns, on the SoC PWM
  block. This tree's `ipq9574.dtsi` already carries the `pwm@1941010` node
  (`qcom,ipq6018-pwm`, `#pwm-cells = <3>`, `status=disabled`) and the driver
  (`drivers/pwm/pwm-ipq.c`, `CONFIG_PWM_IPQ=y`) registers 4 channels at
  reg-offset `8*ch`, so channel numbering matches the vendor's pin mapping.
  Mainline pinctrl exposes a single `"pwm"` function on gpio44-47 (not the
  QSDK `pwm00/10/20/30` names).
- **eMMC install is via a U-Boot `flash.scr`** doing raw `mmc write` to
  fixed sectors in two banks (A/B). It does not reveal GPT partition
  *names*, so the `platform.sh` `CI_KERNPART="0:HLOS"` / `CI_ROOTPART="rootfs"`
  (copied from kiwi-dvk) are still unconfirmed against Linksys's GPT.

### Wi-Fi board data (answer to "can we extract calibration data?")

Partly. The WRT firmware ships **QSDK-format board data** - `bdwlan.bin`
plus per-region/per-chain `bdwlan.bXX` files and a `qcn9224/` dir - loaded
by the proprietary cnss/qcn9224 platform driver via the `11-wifi-fw`
hotplug script. It does **not** contain a mainline `board-2.bin`, which is
what OpenWrt's `kmod-ath12k` needs. Converting the raw `bdwlan` BDF into a
`board-2.bin` (via `ath12k-bdencoder`) requires knowing the exact board-id
mainline ath12k requests for these radios. **UPDATE 2026-07-13: the QSDK
board-id is now known - `0x1006` for the QCN9224 radios** (see "Live-device
teardown"), and the exact `b1006` BDF is saved in
`~/mbe7000_wrt_extract/board-data/`. The remaining unknown is only the
*string form* mainline requests (`bus=pci,qmi-board-id=...`), read from a
booted mainline `dmesg`. The raw BDFs are preserved for that conversion. There is also an optimistic path: since this is a stock
AP-AL02-C4 reference design, the reference `board-2.bin` already shipped in
`ath12k-firmware-qcn9274` may contain a matching board-id and Just Work -
to be checked on hardware.

## Live-device teardown (2026-07-13) - from a booting MBE70WRT unit

Got serial console + a root shell on an actual **MBE70WRT** (the WRT SKU)
running vendor QSDK firmware (Linux 5.4.213). Full boot log at
`~/MBE70.log`. This confirms a pile of previously-inferred facts and resolves
the Wi-Fi board-id gap. Dumped artifacts + a README in
`~/mbe7000_wrt_extract/board-data/`.

Confirmed from the running device:
- **4 PWM LEDs** - vendor prints `>>> Register 4 PWM-LEDs`. Matches this
  port's 4-channel `pwm-leds`. Was inference; now confirmed.
- **eMMC** - `mmcblk0 ... 8GTF4R 7.28 GiB`, HS200, boot0/boot1 4 MiB each,
  33 GPT partitions (`p1..p33`). `&sdhc_1` config validated.
- **Ethernet** - 4 LAN (macid 1-4) + WAN (macid 6) come up (`dp1..dp5`).
  PPE port map confirmed.
- **Radios = QCN9224** (not QCN9274) - live PCI enum `pci ... [17cb:1109]`,
  cnss `QCN9224_PCI2`, dual-MAC firmware `qcn9224/amss_dualmac.bin`. Two PCIe
  radios (5 GHz + 6 GHz) + on-die QCA9574 2.4 GHz. The DTS `pci17cb,1109`
  device-id is right; the *silicon* is QCN9224, which mainline ath12k does
  not support (see below).
- **Wi-Fi board-id = `0x1006`** for the QCN9224 radios - the boot log shows
  `Downloading BDF: qcn9224/bdwlan.b1006, size: 161792`. The on-die QCA9574
  uses the default `bdwlan.bin`. **This resolves the "board-id unknown" gap.**
  Both BDFs (generic, from the firmware's WIFI_FW squashfs) are stashed in
  `board-data/`.
- **MAC base = `80:69:1A:B2:C1:07`** (Linksys OUI); eth = base, wlan =
  base+08/+09. Stored per-unit in ART/appsblenv, read at runtime - not baked
  into any image. (U-Boot couldn't parse `eth1addr`, so GMACs fell back to
  random MACs in this boot - cosmetic.)
- **machid `0x8050301`**; bootargs `console=ttyMSM0,115200n8
  root=PARTUUID=37580e59-... gpt rootwait vmalloc=1G`.
- **Per-device cal lives on the device** - ART on `mmcblk0p20`, WIFI_FW
  squashfs on `mmcblk0p26`. The per-unit `caldata.bin` is ~identical to the
  generic `bdwlan.bin` (15660 vs 15661 non-zero bytes; differs in a handful),
  so per-unit variation is negligible and handled at runtime from the unit's
  own ART.

### eMMC layout & A/B boot (from `fw_printenv` + `/proc/partitions`)

The vendor uses a dual-slot (A/B) scheme with **raw eMMC block offsets for the
kernel** and **GPT partitions for rootfs** - not partition *labels* for the
kernel. Key env:

```
boot_part=1  auto_recovery=yes  boot_part_ready=3   machid=8050301
prikern=0x00010a22 (=68130) altkern=0x0010ea22 (=1108514) kernsize=0x4000 (=8 MiB)
bootcmd=bootipq
bootpart1 = mmc read $loadaddr $prikern $kernsize && bootm $loadaddr#config@1
            partbootargs  = init=/sbin/init root=/dev/mmcblk0p29 ro rootfstype=squashfs rootwait
bootpart2 = mmc read $loadaddr $altkern $kernsize && bootm $loadaddr#config@1
            partbootargs2 = init=/sbin/init root=/dev/mmcblk0p31 ro rootfstype=squashfs rootwait
flashimg  = tftp $loadaddr $image && mmc erase $prikern $imgsize && mmc write ...   (image=MBE70.img)
ipaddr=192.168.1.1  serverip=192.168.1.254   ethaddr=80:69:1A:B2:C1:08
```

`prikern`/`kernsize` match the very first boot log line exactly: `MMC read ...
block # 68130, count 16384`. Partition sizes (`/proc/partitions`, KiB) resolve
the slot map:

| part | size | role |
|------|------|------|
| p20 | 1 MiB | ART (per-device cal) |
| p26 / p27 | 10 MiB each | WIFI_FW squashfs (A / B) |
| **p28 / p30** | 8 MiB each | **HLOS kernel A / B** (= prikern / altkern regions) |
| **p29 / p31** | 500 MiB each | **rootfs A / B** (root=p29 / root=p31) |
| p33 | ~2.5 GiB | data/overlay |

So the real layout is `[kernA][rootA][kernB][rootB]`, A/B mirrored. This
**supersedes the copied-from-kiwi-dvk `CI_KERNPART="0:HLOS"` /
`CI_ROOTPART="rootfs"` guess** - rootfs is a real GPT partition (p29/p31) but
the **kernel is flashed to raw block offsets** and booted with a hardcoded
`#config@1` (our FitImage names its config `config@mbe7000` - a mismatch to
reconcile if we ever reuse the vendor `bootcmd`).

**Two safe test paths now fully mapped:**
1. **RAM boot** (no flash touched): interrupt U-Boot, `tftp` the
   `-initramfs-uImage.itb` to `$loadaddr` and `bootm` it (plain, no `#config`).
   There's even a built-in `flashimg` tftp recovery path.
2. **A/B slot test** (no serial needed, non-bricking): from a vendor root
   shell, write OpenWrt kernel → slot-B kernel region (altkern / p30) and
   rootfs → p31, `fw_setenv boot_part 2`, reboot. If it fails to come up,
   `auto_recovery` falls back to the intact vendor slot 1. Reversible via
   `fw_setenv boot_part 1`.

**GPT partition table (CONFIRMED 2026-07-13** from a raw dump of the first 40
sectors, parsed - `gdisk`/`sgdisk` aren't on the vendor fw):

```
p20 0:ART      1 MiB    (per-device cal)
p26 0:WIFIFW   10 MiB   p27 0:WIFIFW_1 10 MiB
p28 0:HLOS     8 MiB   start LBA 68130   = prikern (slot A kernel)
p29 rootfs     500 MiB                    = slot A rootfs (root=mmcblk0p29)
p30 0:HLOS_1   8 MiB   start LBA 1108514 = altkern (slot B kernel)
p31 rootfs_1   500 MiB                    = slot B rootfs (root=mmcblk0p31)
p33 syscfg     2.5 GiB (data)
```

Key result: **`altkern` (0x10ea22 = 1108514) is exactly p30's start LBA**, so
`dd of=/dev/mmcblk0p30` == the raw kernel offset the bootloader reads, but
bounded by the partition. The kernel FIT (5.73 MiB) fits the 8 MiB slot;
`root.squashfs` (10.1 MiB) fits the 500 MiB rootfs slot. This **confirms the
port's `CI_KERNPART="0:HLOS"` / `CI_ROOTPART="rootfs"` are correct** (they were
copied from kiwi-dvk and are now verified against the real Linksys GPT), and
gives the exact A/B slot-B flash targets (p30 + p31).

### Universal-image architecture (one image for all MBE70/MBE7000)

Three-way split - only the first belongs in a shared firmware image:
1. **Board data** (`b1006` + default `bdwlan.bin`) - board-DESIGN level,
   identical on every unit → ships in image (as a converted `board-2.bin`,
   once the driver supports the radios).
2. **Per-device RF cal** (ART `p20`) - unique per unit → NOT in image; read
   from each device's own flash at runtime.
3. **Per-device MAC** - unique per unit → NOT in image; read at runtime.
So: do **not** embed the per-device `caldata`/ART. Standard OpenWrt practice.

### Secure boot - what this unit proves (and doesn't)

This MBE70WRT's U-Boot loads a plain kernel FIT and verifies it with
**crc32 + sha1 hashes only - no RSA/cert signature check** (`Verifying Hash
Integrity ... crc32+ sha1+ OK`). So on the **MBE70WRT**, an unsigned
OpenWrt FIT should be accepted. This says **nothing** about the retail
**MBE7000**, whose stock firmware is a signed Qualcomm ELF and whose
secure-boot fuse state is unknown - see the "Secure boot / flashing" section.

### Serial console gotcha (RX dead)

If TX works (you see the log) but RX doesn't (can't interrupt autoboot /
can't type), it's almost always **host-side hardware flow control** with
RTS/CTS unwired - the host holds off TX waiting for CTS. The console header
is 2-wire (TX/RX/GND). Fix: run the terminal with flow control off
(`tio --flow none ...`). Not a firmware issue; independent of whether the
SoC supports flow control.

## First successful boot + ethernet root cause (2026-07-13)

Flashed the `config@1` factory image via the vendor LuCI sysupgrade (writes to
the inactive A/B slot automatically) and it **booted mainline OpenWrt to
userspace**: U-Boot loaded `config@1`, kernel 6.18.38 came up (`Machine model:
Linksys MBE7000`), rootfs mounted from p31, f2fs overlay initialised, procd/
console reached. The bringup fundamentally works. Two fixes got us here:
- FIT config renamed `config@mbe7000` -> `config@1` (vendor U-Boot hardcodes
  `bootm ...#config@1`; otherwise "Config not available"). Committed in the
  DTS/image tree.
- (behaviourally) the A/B + auto_recovery flow: a bad slot self-reverts after
  3 failed boots, so LuCI-flash + power-cycle is a safe no-serial loop.

**Ethernet does NOT work.** dmesg:
```
mdio_bus 90000.mdio-1: MDIO device at address 28 is missing   (WAN phy @0x1c absent)
nss_cc_srds1_sys_clk status stuck at 'on'
WARNING ... clk_branch_toggle+0x168  (x6, clk-branch.c:87)
Qualcomm QCA8084 90000.mdio-1:01: phy_poll_reset failed: -110
qcom_ppe 3a000000.ethernet: PPE port 1 failed to connect phylink: -ETIMEDOUT
... sync_state() pending due to 3a000000.ethernet
```
The MDIO *bus* works (it scans). The QCA8084 switch-PHY never comes alive:
the nsscc SerDes clock is stuck and the 4 internal PHYs don't respond
(`phy_poll_reset -110`).

**This is an unsolved mainline problem, not just our port.** OpenWrt PR #20604
(Xiaomi BE7000, also IPQ9574 + QCA8084) has the **identical** qca8084 DTS block
to ours - same `qca8k_nsscc` clocks `<&cmn_pll ETH0_50MHZ_CLK>, <0>,<0>,<0>,<0>,
<uniphy1_rx312p5m>, <uniphy1_tx312p5m>`, same `reset-gpios = <&tlmm 60>` on
`&mdio` (our "sonnet 5" patch shares its origin). That PR is **draft with
ethernet NOT working** ("links are up, but no IP; ping doesn't work"). A fork
(@kravasuper) reportedly has working ethernet but others (@BrainSlayer) can't
replicate; suspected HW-revision differences. So the `<0>` clock stubs are
*not* obviously the bug - they're the shared community state.

**Our symptom is worse than the BE7000's** (they get "links up"; we get
`-110`, PHY not responding at all), which points to an *additional*
board-specific issue - most likely the **QCA8084 reset**: the vendor MBE70 DTS
uses `phy-reset-gpio = <&tlmm 60 0 &tlmm 36 0>` (BOTH gpio60 and gpio36,
flags 0), whereas we drive only gpio60 (active-low) on `&mdio` and assign
gpio36 to the WAN PHY. If the qca8084 needs gpio36 released too, or the
polarity differs, it stays in reset -> `-110`. Unverified.

**Fix attempt (2026-07-13): `reset-gpios` -> `phy-reset-gpio` on `&mdio`.**
Comparing against the *working* TP-Link Archer BE800 (PR #20373, the reference
the BE7000 dev copied) revealed the one real difference: BE800 names the
QCA8084 chip reset **`phy-reset-gpio`** (a QSDK property mainline's MDIO core
does NOT read), whereas our "sonnet 5" patch used **`reset-gpios`** (which
mainline DOES act on). Theory: U-Boot already brings the QCA8084 up (its log
reads the PHY IDs); mainline then re-asserts gpio60 during bus registration
and the chip can't recover in the scan window -> `phy_poll_reset -110` +
`srds1_sys_clk stuck`. This explains why ours is *worse* than BE800 (they never
disturb the chip). Changed to `phy-reset-gpio` to match BE800 exactly, leaving
the U-Boot-initialised chip untouched (the package's `NSS_CC_GEPHY_FULL_ARES`
reset still handles the internal PHYs). Our whole qualcommbe ethernet patch
stack (0301-0361, incl. nsscc-qca8k clock driver + full IPQ9574 PCS) is present
and current - the gap to BE800 was purely this DT property name. NOTE: even if
this fixes `-110`, BE800/BE7000 additionally needed a not-upstreamed XPCS
`qca8084_qxgmii_set_speed()` fix to pass traffic, so a second hurdle may remain.

**Result of the `phy-reset-gpio` change (2026-07-13, boot log `_2`): advanced
one layer, new blocker.** The `-110` is GONE - the QCA8084 is now reachable
over MDIO. New failure: `nss_cc_gephy0_sys_clk status stuck at 'off'` ->
`clk_branch2_enable` WARN in `qca8084_probe` -> `error -EBUSY: Enable PHY clock
failed`; all 4 QCA8084 PHYs fail probe (`-16`), PPE falls back to Generic PHY
for lan1-4, WAN gets `-ENODEV`. So: chip reachable, but its internal GEPHY
clock won't start (parent = the SoC's `cmn_pll ETH0_50MHZ` 50 MHz ref). Our SoC
clock ref is correct (`xo_clk=48MHz`, `ref_48mhz`, `xo_board_clk` per the RDP
reference), so the 50 MHz should be produced - the chip's internal clock just
won't run.

**Reconciliation with the reference ports - our board has its own quirk:**
- Xiaomi BE7000 (PR #20604, closest analog: consumer router + vendor U-Boot)
  uses `reset-gpios` (no delay), no kernel patches, and gets **"links up but no
  IP"**. Its qca8084 *does* come up.
- TP-Link BE800 (PR #20373) uses `phy-reset-gpio` and works (different
  board/bootloader), plus PCS patches we already have.
- **Ours behaves differently from BOTH**: `reset-gpios` -> `-110` (chip
  unreachable); `phy-reset-gpio` -> `-EBUSY` (chip reachable, GEPHY clock
  stuck). So the MBE7000 has a board/U-Boot-specific QCA8084 clock/reset-state
  quirk beyond what the reference DTs handle. The Linksys U-Boot evidently
  leaves the chip in a state mainline's clock-enable can't drive, and our
  board's reset recovery differs from BE7000's.

This is now genuinely at the frontier: the remaining issue is QCA8084 internal
clock/reset state that needs **live register inspection to diagnose** - exactly
what this unit can't provide (dead serial RX). Candidate next experiments if
resumed: (a) `reset-gpios` + generous `reset-delay-us`/`reset-post-delay-us`
(bet: our `-110` was reset-recovery-too-short; aim for BE7000's "links up");
(b) track PR #20604/#20373 for the eventual consumer-device qca8084 fix.

**Experiment (a) result (boot log `_3`): REGRESSED to `-110`.** `reset-gpios`
+ `reset-delay-us=10000` + `reset-post-delay-us=150000` gave the same
`phy_poll_reset failed: -110` as plain `reset-gpios` (now with `clk_branch2_
disable` warnings on several nss_cc clocks stuck 'on' - clk_disable_unused
can't reach the reset chip). So reset **timing is not the issue** - asserting
gpio60 at all breaks the QCA8084 on this board, because the Linksys U-Boot
initialises the chip and mainline does not re-init it after a reset.

**Conclusion / parked state:** `phy-reset-gpio` is the furthest-progress config
(chip reachable, only the internal GEPHY clock won't start) and is what the
committed DTS now uses. The three tested states:

| &mdio reset            | result                                        |
|------------------------|-----------------------------------------------|
| reset-gpios            | -110 (chip unreachable)                       |
| reset-gpios + delays   | -110 (unchanged - timing ruled out)           |
| **phy-reset-gpio**     | chip reachable; -EBUSY, gephy0_sys_clk stuck  |

The remaining `-EBUSY`/GEPHY-clock-stuck is a QCA8084 internal clock-state
issue that needs **live register inspection to solve** - impossible on this
unit (dead serial RX). **Ethernet is parked here.** Resume when either: a unit
with a working serial console is available, or the QCA8084 consumer-device
bring-up matures upstream (track PR #20604 / #20373). Everything else works:
boot, eMMC, config@1, PWM LEDs, A/B factory-flash via LuCI + auto-recovery.

**Vendor-firmware SSH investigation (2026-07-13) - root cause narrowed.**
Got root SSH into the running QSDK vendor firmware (working QCA8084) and read
the known-good hardware state:
- **gpio60 (QCA8084 reset) = `out high`** while working (active-low confirmed;
  chip must be left HIGH / out of reset - do NOT pulse it). gpio36 (WAN) = high
  too. MDC=gpio38, MDIO=gpio39 (func1).
- **CMN PLL is NOT the problem.** Working `CMN_PLL_REFCLK_CONFIG` (0x9b784) =
  `0x8017` -> reference INDEX=7, DIV=1, internal. Mainline
  `ipq_cmn_pll_find_freq_index(48000000)` also returns **index 7**, so our
  48 MHz DT ref makes the mainline driver program the identical config. The
  50 MHz `ETH0_50MHZ` reference that feeds the QCA8084 should be present in
  mainline. (Regs captured: locked@0x9b064=0x07, refsrc@0x9b028=0x555,
  reset@0x9b780=0xFF, ctrl@0x9b78c=0x5D0, div@0x9b794=0x6C7D.)
- **The mainline clock chain is sane**: `nss_cc_gephy0_sys_clk` <-
  `nss_cc_sys_clk_src` (RCG, /2 -> 25 MHz) <- `DT_XO` = index 0 =
  `<&cmn_pll ETH0_50MHZ_CLK>`. Parent is provided (not a `<0>` stub).

Conclusion: the 50 MHz reference and gpio reset are fine; the failure is
**inside the QCA8084's own GEPHY power/clock bring-up**. The Linksys U-Boot
only minimally inits the chip (its log shows just one uniphy path up), and
mainline's qca8084 driver - which was developed against RDP/TP-Link U-Boots
that pre-init the switch - doesn't do the full GEPHY power-up that QSDK's
`ssdk` does. With `phy-reset-gpio` the GEPHYs stay in U-Boot's powered-down
state (`gephy0_sys_clk` won't start, -EBUSY); with `reset-gpios` the gpio pulse
leaves the chip unreachable (-110). Fixing this needs **driver-level GEPHY
init + live iteration on our OpenWrt** (compare mainline's qca8084 register
writes against the vendor's working state). Requires network access into our
image -> add USB-Ethernet (`kmod-usb-net-*`) so a dongle gives a shell, since
this unit has no serial RX. Vendor SSH (192.168.1.1) remains available for
targeted known-good register reads during that work.

### ROOT CAUSE FOUND + fix built (2026-07-13, awaiting flash test)

Reading the mainline qca8084 driver (`drivers/net/phy/qcom/qca808x.c`) pinned
the exact bug. The driver programs the switch **work mode + EPHY LDO + package
clock tree** only in `.config_init`
(`qca8084_phy_package_config_init_once`), whose own comment says it is "the
necessary config sequence after GPIO reset". But `.config_init` runs AFTER the
per-PHY probe (`qca8084_probe` -> `devm_clk_get_enabled` + PHY reset poll).

- Reference boards (RDP / TP-Link BE800): **U-Boot pre-inits the QCA8084**, so
  the per-PHY clock enable + reset poll succeed at probe; `.config_init` just
  re-applies config. Works.
- **Linksys MBE7000: U-Boot does NOT init the switch.** The chip is cold at
  probe -> per-PHY clock enable fails `-EBUSY` (`gephy0_sys_clk` stuck), or with
  a GPIO reset the PHY reset poll times out `-110` - and `.config_init` is
  never reached. This explains ALL three earlier symptoms exactly.

**Fix:** patch `patches-6.18/0362-net-phy-qca8084-cold-init-package-in-probe-
for-consum.patch` moves the chip config (work mode + EPHY LDO + package clock
init) into `qca8084_phy_package_probe_once()`, right after the package reset is
deasserted and **before** any per-PHY access. Idempotent, so RDP/BE800 are
unaffected. DTS paired back to plain `reset-gpios = <&tlmm 60 GPIO_ACTIVE_LOW>`
(the driver's intended "GPIO reset -> config" flow).

Supported by the vendor-SSH evidence: gpio60 rests high (out of reset), CMN PLL
50 MHz ref config is identical to mainline (ruled out), clock parent chain is
sane - the only gap was the chip never being configured before per-PHY access.

**STATUS: BUILT, NOT YET FLASHED.** Test factory image:
`bin/targets/qualcommbe/ipq95xx/openwrt-...-linksys_mbe7000-squashfs-factory.bin`
sha256 `ab9311630c7500c98ac10423cfbf427a0a047f91a5566eae646d0226f133275a`.

**TOMORROW:** flash via LuCI (-> slot 2 -> reboot), capture serial TX boot log.
Verdicts: (win) no -110/-EBUSY, QCA8084 PHYs probe, lan1-4 up -> if DHCP works,
cracked it (and 0362 is upstream-worthy); (partial) links up but no traffic ->
add the XPCS `qca8084_qxgmii_set_speed()` fix; (fail) boot log shows the next
register step - vendor SSH (192.168.1.1, pw in chat) still open as known-good
reference. If it works, the build_dir edit is already captured as patch 0362.

### 0362 flashed (boot log `_4`): still `-110` - but it isolated the variable (2026-07-14)

Flashed the `reset-gpios` + `0362` image. Result: **still `phy_poll_reset
failed: -110` at `90000.mdio-1:01`**, and now the on-chip `nss_cc_*` clocks are
"stuck at **on**" during `clk_disable_unused` (clk_branch2_disable can't confirm
the disable). That "stuck" pattern is the tell: **the QCA8084 register window is
not responding at all.** Re-reading the driver made it obvious why moving config
into probe_once didn't help *with reset-gpios*:

- The chip's config interface is a **fixed MDIO window at 0x10-0x1f**
  (`LOW_ADDR_PREFIX=0x10`, `HIGH_ADDR_PREFIX=0x18`), and every `qca8084_mii_*`
  write is a plain **MDIO C22 write, which returns 0 whether or not the chip
  ACKs**. So 0362's work-mode / LDO / clock-init writes *silently succeed* even
  when the window is dead -> probe_once "passes", but nothing was programmed ->
  PHYs never move to addr 1-4 -> `phy_poll_reset -110`.
- With `reset-gpios`, mainline's MDIO core **pulses gpio60 low during bus
  registration**, and that pulse is what kills the 0x10-0x1f window (Linksys
  U-Boot init is lost, mainline never re-inits). Confirmed by the nsscc clocks
  reading "stuck on".

**The two variables were always coupled.** Full truth table now:

| `&mdio` reset          | 0362 | result                                        |
|------------------------|------|-----------------------------------------------|
| reset-gpios            | no   | -110 (window dead)                            |
| reset-gpios + delays   | no   | -110 (timing ruled out)                       |
| phy-reset-gpio         | no   | -EBUSY, gephy0_sys_clk stuck (**window ALIVE**)|
| reset-gpios            | yes  | -110 (log `_4`; window dead, writes no-op)    |
| **phy-reset-gpio**     | **yes** | **UNTESTED <- this build**                  |

`phy-reset-gpio` is the only config that kept the window alive; it only failed
because the GEPHY power-up hadn't run before per-PHY access - which is exactly
what 0362 adds in probe_once. So `phy-reset-gpio` + `0362` is the predicted-good
combination and the one empty cell. **Change (2026-07-14):** DTS `&mdio` reset
flipped `reset-gpios` -> `phy-reset-gpio = <&tlmm 60 GPIO_ACTIVE_LOW>`; 0362 kept
as-is. Rebuilding for a flash test. `config_init_once` (incl. the QXGMII PCS
`qca8084_qxgmii_set_mode`) still runs after per-PHY probe, so 0362 need not
replicate it.

**BUILT (2026-07-14), awaiting flash.** Verified the compiled DTB carries
`phy-reset-gpio = <&tlmm 60 GPIO_ACTIVE_LOW>` on `mdio@90000` (no `reset-gpios`
on the bus node). Test factory image:
`bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-squashfs-factory.bin`
sha256 `a01885588ed11fc4391b4346f7d52a0abb4fb0d17d7dcde8dd6b275c055f3d3f`.
Flash via LuCI (-> inactive slot -> power-cycle), capture serial TX log `_5`.
Win: no `-110`/`-EBUSY`, `QCA8084 ...:01-:04` PHYs probe, `lan1-4` up.

Note: serial is **read-only** (device TX only; RX pad dead) so `/dev/ttyUSB0` +
tio can *capture* the boot log but cannot type - no live poking of the failing
OpenWrt. Interactive debugging still goes through vendor-firmware SSH (other A/B
slot) as the known-good reference.

### `phy-reset-gpio` + 0362 flashed (boot log `_5`): -110 GONE, new deeper blocker (2026-07-14)

The predicted-good cell. Result: **`-110` is gone** - `phy-reset-gpio` kept the
chip register window alive and `probe_once` now runs deep into
`qca8084_package_clock_init`. New failure there:
```
nss_cc_switch_core_clk_src: rcg didn't update its configuration   <- package_clock_init+0x28
nss_cc_apb_bridge_clk status stuck at 'off'                       <- package_clock_init+0x78
QCA8084 90000.mdio-1:01..:04 ... failed with error -16 (EBUSY)
mdio_bus 90000.mdio-1:06: Get PCS reset failed
```
An RCG that "didn't update" = **its selected source clock isn't physically
running**. `nss_cc_switch_core_clk_src` (cmd_rcgr 0x0, `clk_rcg2_mux_closest_ops`)
has only two parents: `P_XO` (DT_XO = `<&cmn_pll ETH0_50MHZ_CLK>`, 50 MHz) and
`P_UNIPHY1_TX312P5M` (`<&qca8k_uniphy1_tx312p5m>`, 312.5 MHz). `package_clock_init`
does `clk_set_rate(APB_BRIDGE, 312.5MHz)`, so the mux picks the 312.5 MHz parent -
which is the QCA8084's **own internal uniphy1 SerDes clock**, and in our DTS is a
`fixed-clock` (always-on *to the framework*, but physically absent until the chip
SerDes is initialised). Reference boards' U-Boot inits that SerDes; Linksys
U-Boot does not -> the fixed-clock "lies", the RCG locks to a dead source and
never updates -> switch_core/apb_bridge never start -> `-16`.

### Vendor-QSDK SSH deep dump (2026-07-14) - root cause pinned, uniphy ruled in

Root SSH into the working vendor firmware (`192.168.1.1`, Linux 5.4.213). Saved:
`~/openwrt_debug/vendor_qsdk_dump_2026-07-14.txt`. Findings:
- **QCA8084 is on SoC UNIPHY0** (`pcs0`/`ethernet-pcs@7a00000`), matching our DTS
  (`pcs-handle = <&pcs0_ch0..3>`). Vendor `clk_summary`: `uniphy0_gcc_tx/rx`
  ENABLED (cnt 2) @125 MHz; `uniphy1`/`uniphy2` DISABLED (cnt 0). Vendor dmesg:
  **`ssdk_clock_rate_set_and_enable: UNIPHY 1 is not available on this SKU!`**.
  So the SoC-side uniphy wiring is CORRECT - not the bug.
- **CMN PLL locked & identically configured** (0x9b064=0x07, 0x9b784=0x8017) -
  PLL/50 MHz ref ruled out (again).
- **Vendor never models the QCA8084's internal clock tree in Linux** - ssdk pokes
  it over MDIO directly. So mainline's whole `nsscc-qca8k` model
  (switch_core sourced from the internal 312.5 MHz uniphy1) is a *mainline-only*
  construct that assumes the chip SerDes is already up.
- **WAN PHY @0x1c is a QCA8081**, not a generic c45 PHY - vendor dmesg registers
  `qca808x phydev 90000.mdio:1c`. Fixed our DTS `phy4` compatible ->
  `ethernet-phy-id004d.d101` (evidence-based; untestable until LAN works).

**Refined root cause (LAN):** The stock Linksys U-Boot (same for vendor fw and
our OpenWrt) does **not** bring up the QCA8084's internal SerDes/uniphy1. The
vendor QSDK ssdk does it in-kernel; mainline's qca8084 phy driver does **not** -
it assumes a pre-inited SerDes (RDP/BE800 U-Boots do it). So on this consumer
board `package_clock_init` deadlocks trying to clock switch_core from a SerDes
that isn't running. This is the upstream-frontier gap the notes predicted.

**Next experiment (scoped):** replicate the QSDK QCA8084 SerDes/uniphy1 init in
`qca8084_phy_package_probe_once()` *before* `package_clock_init`, OR make
switch_core source from XO (50 MHz) so the AHB/register core comes up independent
of the SerDes (defer SerDes to the PCS driver). Need the exact QSDK sequence -
pull from the vendor UART boot log (ssdk `uniphy`/serdes lines) + QSDK ssdk
source (`qca8084_interface_uniphy_mode_set` / serdes calibration). Vendor SSH at
192.168.1.1 remains open for targeted known-good register reads.

### FIX FOUND: it's a REORDER, not a port (2026-07-14, via QSDK + vendor UART)

User supplied the vendor UART log (`~/openwrt_debug/vendor_boot.log`) and a QSDK
mirror (`~/qsdk`, github.com/everything411/qsdk). Two things fell out:

1. **Vendor U-Boot does NOT touch ethernet** (43 U-Boot lines, no phy/switch/mdio
   init). The QCA8084 SerDes is brought up **in-kernel by ssdk** - so the fix
   belongs in our phy driver, and the *same* stock U-Boot means our OpenWrt can't
   rely on any pre-init.
2. **QSDK `qca_mht_hw_init()` order** (`src/init/ssdk_mht.c`): `work_mode_init`
   -> **`interface_mode_init` (SerDes calibration + uniphy QXGMII mode)** ->
   `switch_reset` -> `switch_init` -> **`ssdk_mht_gcc_clock_init`**. The SerDes is
   calibrated *before* the clock init. And QSDK's `mht_switch_core_pdata` uses the
   **same** two sources as mainline (XO 50 MHz, UNIPHY1_TX312P5M) with switch_core
   only supporting the 312.5 MHz rate - so mainline's source choice was never
   wrong, only its **ordering**.

Mainline already ships the entire SerDes bring-up: `qca8084_qxgmii_set_mode()`
(`qca8084_serdes.c`) -> `qca8084_pcs_set_mode` -> **`qca8084_do_calibration`**.
It uses plain MDIO (`mdiodev_c45_modify`) to the PCS/XPCS devices, so it does
**not** depend on the package clocks - it can safely run before them. Mainline
only calls it in `.config_init` (after `package_clock_init`), so on a cold board
the clock init hangs first and the SerDes step is never reached.

**Fix (patch 0362, extended):** in `qca8084_phy_package_probe_once()`, after
work-mode + EPHY LDO and **before** `qca8084_package_clock_init()`, call
`qca8084_qxgmii_set_mode(mdiodev[1], mdiodev[0])` (gated on QXGMII package mode).
Exactly QSDK's serdes-before-clock order. `config_init_once` still re-runs it
later; idempotent. This is a pure reorder of code mainline already has - no
register tables ported. Rebuilding (build_6) for a flash test.

Also confirmed via vendor dmesg + this analysis: the discrete WAN PHY at mdio
0x1c is a **QCA8081** (`ethernet-phy-id004d.d101`, already fixed in DTS).

### Boot log `_6`: WAN QCA8081 works; LAN failure moved one call deeper (2026-07-14)

Flashed 0362-with-serdes-reorder. Two results:
- **WAN QCA8081 now binds correctly:** `wan: PHY [90000.mdio-1:1c] driver
  [Qualcomm QCA8081]`, `configuring for inband/usxgmii link mode`. The DTS
  compatible fix works.
- **LAN failure moved from `package_clock_init` into `qca8084_qxgmii_set_mode`:**
  `nss_cc_mac1_rx_clk_src: rcg didn't update` at `qca8084_qxgmii_set_mode+0x40`
  -> QCA8084 :01-:04 fail -16. So the early qxgmii_set_mode call runs, but its
  FIRST step, `qca8084_xpcs_clock_parent_set()`, reparents mac*_rx/tx_clk_src
  onto the 312.5 MHz SerDes root - which still isn't running because
  `qca8084_pcs_set_mode()`'s calibration runs AFTER it, later in the same
  function. Ordering bug *inside* qxgmii_set_mode.

**Fix (patch 0363):** swap the two calls in `qca8084_qxgmii_set_mode()` so
`qca8084_pcs_set_mode` (SerDes calibration) runs before
`qca8084_xpcs_clock_parent_set` (clock reparenting). Calibration doesn't depend
on the reparenting, so it's safe on all boards, and matches QSDK (all SerDes
calibration in interface_mode_init, before the port clocks in gcc_clock_init).
Rebuilding (build_7). PR #23900 (qxgmii_set_speed + ppe reset loop fixes)
confirmed already present in this base, so the traffic path is covered.

Blind iteration is the only channel (this unit has **no usable serial RX** -
only the TX pad carries 1.8 V; the RX pad is dead/unpopulated, confirmed with
a loopback-tested 1.8 V adapter). Next investigative steps, when picked up:
- Diff our DTS against @kravasuper's fork (the only claimed-working qca8084).
- Try releasing gpio36 alongside gpio60 as qca8084 reset; test reset polarity.
- Track PR #20604 upstream for the eventual qca8084 fix.

## Known gaps / things NOT verified against real hardware

- **WAN PHY chip identity.** `phy4` in the DTS uses a generic
  `"ethernet-phy-ieee802.3-c45"` compatible as a placeholder (same pattern
  `qcom_rdp433` uses for its own discrete PHYs) at mdio address `0x1c`.
  The actual chip (likely an Aquantia/Marvell AQR-class multi-gig PHY,
  going by the `qcom_rdp433` precedent) is unconfirmed - if it needs
  firmware via `nvmem-cells` (like `rdp433`'s `aqr_fw`), that's not wired
  up here at all. **Check the boot log once serial console works** - the
  phy driver probe should identify the chip.
- **LEDs**: RESOLVED - 4 PWM RGBW LEDs, wired up and confirmed by the vendor
  boot log (`>>> Register 4 PWM-LEDs`). See "Post-review fixes" and
  "Live-device teardown". Polarity/active-state still unverified on mainline.
- **pcie3** (3rd external radio slot): left disabled, matching the vendor
  firmware's own choice on the 1.0.10 build. Unknown whether later
  firmware (up to 1.0.14, the latest GPL release seen) enables it, i.e.
  whether the board actually has a 3rd radio chip populated.
- **eMMC partition names** RESOLVED - `CI_KERNPART="0:HLOS"` /
  `CI_ROOTPART="rootfs"` are confirmed correct against the real Linksys GPT
  (see "eMMC layout & A/B boot"). Note the layout is A/B dual-slot
  (0:HLOS/0:HLOS_1, rootfs/rootfs_1); a proper sysupgrade that participates in
  the vendor A/B + `boot_count` scheme is still to be designed - the current
  test path writes slot B manually.
- **On-die 2.4 GHz radio** not enabled (this tree doesn't support it yet -
  see above). MBE7000 would need it added upstream/locally for full
  tri-band operation; for now only the two PCIe radios (likely 5 GHz +
  6 GHz) are wired up.
- The DTS has **not been booted**. Everything above is inference from a
  decompiled vendor DT (a different kernel/driver stack - QSDK 5.4, not
  mainline 6.18) plus cross-referencing the real `ipq9574.dtsi` and
  `ipq9574-rdp433.dts` in this tree. It compiles; it hasn't run.

## Build environment gotcha

This host (Manjaro, very new glibc) can't build OpenWrt's pinned host
tools from source (`tools/m4`, `tools/sed`, `tools/libressl` all fail with
gnulib `off64_t`/`stdio.h` errors - old gnulib vs. too-new glibc, unrelated
to this device). Building works fine in a plain `ubuntu:22.04` Docker
container. Recipe used:

```bash
docker run --name mbe7000-build \
  -v /home/daniel/openwrt:/openwrt \
  -v <path-to-docker-build.sh>:/docker-build.sh \
  ubuntu:22.04 bash /docker-build.sh
```

where `docker-build.sh` does `apt-get install` of the standard OpenWrt
build-depends list, creates a `builder` user matching the host UID/GID
(1000:1000 here) so output files land with correct ownership, then runs
`su builder -c "cd /openwrt && make -j16 IGNORE_ERRORS=1"`. The built
toolchain persists in `staging_dir/toolchain-aarch64_cortex-a53_gcc-*`
across runs, so only the first build pays the full toolchain-build cost.

This produced, successfully:
- `bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-initramfs-uImage.itb`
- `bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-squashfs-factory.bin`
- `bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-squashfs-sysupgrade.bin`

## Next steps

1. Get UART access (1.8V header on PCB, 115200 8n1 per the Xiaomi BE7000
   PR's flashing instructions for the same SoC family - MBE7000's exact
   header location unconfirmed).
2. Interrupt U-Boot, TFTP the `-initramfs-uImage.itb`, `bootm` it. This
   runs from RAM and touches no flash - safe first test.
3. Watch the boot log for: does eMMC show up, does the console work
   (already should, since you're reading it over serial), do the switch
   PHYs and the discrete WAN PHY probe correctly, what's the WAN PHY's
   actual driver/chip ID.
4. Only after that, look at real partition names/layout before ever
   trying `sysupgrade` or factory flashing.
5. Update this file and the DTS as facts get confirmed or corrected.
