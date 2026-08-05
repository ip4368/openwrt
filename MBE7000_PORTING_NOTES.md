# Linksys MBE7000 (Velop Pro 7 BE11000) — porting notes

Branch: `linksys_mbe7000`. Status: DTS + device Makefile entry written and
**DTS-compiles** against this tree's real patched kernel source (a full
initramfs/sysupgrade image has also been built). **Not yet booted on real
hardware.** Note: "compiles" only proves DT *syntax* - it does not validate
DT properties against the drivers. A code review on 2026-07-11 found a
driver-level bug that a compile cannot catch (wrong PPE clock/reset names)
plus other gaps; see "Post-review fixes" below.

## ⚠️ 2026-07-15 — MAJOR CHIP-IDENTITY CORRECTION (LAN is QCA8075, NOT QCA8084)

The entire prior ~15-flash effort assumed the LAN was a **QCA8084** (Manhattan
2.5G switch-PHY, 10G-QXGMII, internal nss_cc-qca8k, XPCS/PCS SerDes bring-up).
**That was wrong** - inherited uncritically from the initial Sonnet port's DTS
and never checked against hardware. Re-derived the chip identity from
non-circular sources (our own DTS is NOT evidence):

| Source of truth | Reads |
|---|---|
| U-Boot raw PHY-ID read (`failed_boot_MBE70.log:44-64`) | `004d.d0b1` **and** `004d.d101` |
| Vendor QSDK kernel driver probe (`vendor_boot.log:348,350`) | **`malibu`** + **`qca808x`** - never manhattan/qca8084 |
| Vendor clk_summary | uniphy0 @ **125 MHz** (gigabit PSGMII), not 312.5 MHz |
| Authoritative ID tables (QSDK `nss_macsec.h`, mainline `qca80{7,8}x.c`) | d0b1=**QCA8075**, d101=**QCA8081**, d180=QCA8084 (never seen on HW) |

**Conclusion: LAN = QCA8075 (Malibu quad GIGABIT PHY, PSGMII on UNIPHY0,
ports 1-4). WAN = QCA8081 (2.5G, port 6 / UNIPHY2). No QCA8084 exists on
this board.** (Also ruled out an "Aquantia @0x1c" guess from another agent -
the vendor binds `qca808x` to 0x1c and U-Boot reads `004d.d101`; nothing
Aquantia, `03a1.*`, anywhere. The "usxgmii" phy-mode is what misled that guess.)

### The pivot done this session (DTS-only; kernel patches untouched)
Rewrote `ipq9574-mbe7000.dts` to the **IPQ9574 RDP433 model** (which is exactly
this board's LAN topology). This is LOW risk because **WAN already works today
through `qcom_ppe`->`pcs2`->`nsscc`->`cmn_pll`** - proving that whole SoC
ethernet stack is functional; LAN just needed the right PHY package + mode:
- Ports 1-4: `phy-mode = "qsgmii"` + `managed = "in-band-status"`, on `pcs0_ch0-3`.
- `&mdio`: replaced the entire qca8084 apparatus (qca8k_nsscc / qca8084-package /
  xpcs-phy / pcs-phy / 312.5MHz fixed-clocks) with a single
  `ethernet-phy-package@10` `compatible = "qcom,qca8075-package"`,
  `qcom,package-mode = "qsgmii"`, PHYs at 0x10-0x13. WAN phy4@0x1c unchanged.
- Kept the **gpio60 gpio-hog** (renamed `lan_phy_reset_hog`) - still the critical
  bring-up requirement; proven to bring the LAN package alive on MDIO.
- Config already enables the path: `QCOM_PPE=m`, `PCS_QCOM_IPQ9574=m`,
  `IPQ_CMN_PLL=y`, `IPQ_NSSCC_9574=y`, `QCA807X_PHY=y`. DTS pre-check with dtc: clean.
- Driver support verified: `qca807x.c` binds child PHYs by ID `004d.d0b1` and
  parses `qcom,package-mode` (line ~547) + runs PQSGMII package init.

**Still-dormant cleanup (do AFTER LAN confirmed, so as not to destabilise the
working CMN-PLL/WAN state):** the qca8084 driver patches (0301-0312) and our
custom debug patches (0362 cold-init, 0363 serdes-calibrate, build_dir
`qca8084_serdes.c` edits) are now inert - no DT node references them - but
should be stripped when folding to patches. Keep CMN-PLL patches 0364/0365
(the PPE/uniphy path needs a correct PLL). Also remove the WAN-debug
uci-default before release.

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

### Boot log `_7`: failure -> `nss_cc_srds1_sys_clk stuck off`; found the keystone (2026-07-14)

0363 flashed. Failure moved one call deeper again: `nss_cc_srds1_sys_clk status
stuck at 'off'` at `qca8084_qxgmii_set_mode+0x34` -> `qca8084_pcs_set_mode`'s
first op `clk_prepare_enable(PCS_CLK)` (= `nss_cc_srds1_sys_clk`). That branch's
parent is **`nss_cc_sys_clk_src`** - and so is `gephy0..3_sys_clk` (the branch
that failed `-EBUSY` back in the phy-reset-gpio-alone test). Same root every time.

`nss_cc_sys_clk_src` (RCG cmd_rcgr 0x1a0) has one parent, `DT_XO` =
`<&cmn_pll ETH0_50MHZ_CLK>`, and must be programmed to XO -> 25 MHz. **Mainline
never configures it.** `package_clock_init` sets only switch_core (via APB_BRIDGE
rate) and ahb; it assumes the bootloader already parented sys_clk_src. QSDK's
`ssdk_mht_gcc_common_clk_parent_enable()` explicitly does
`ssdk_mht_clk_parent_set(SRDS0_SYS, XO)` + `rate_set(25M)` before enabling the
srds/gephy sys branches. Reference U-Boots do the equivalent; Linksys U-Boot does
not -> sys_clk_src is unconfigured -> every sys branch is "stuck at off". CMN PLL
itself is fine (DT has `assigned-clock-rates-u64 = 12 GHz`, vendor shows it
locked), and the chip's MDIO register window works (the work-mode/LDO/fixup
writes land), so this is specifically the sys-clock RCG never being parented.

**Fix (DTS, no driver patch):** `NSS_CC_SYS_CLK_SRC` (id 85) is exposed as a
clock, so configure it via the standard mainline mechanism on the `qca8k_nsscc`
node:
```
assigned-clocks = <&qca8k_nsscc NSS_CC_SYS_CLK_SRC>;
assigned-clock-rates = <25000000>;
```
This programs sys_clk_src (parent XO, /2 -> 25 MHz) at clock-controller probe,
before the qca8084 phy driver needs the srds/gephy sys clocks - the keystone the
whole nss_cc tree hangs off. Rebuilding (build_8). If it cascades, switch_core /
mac (312.5) should follow once calibration produces the SerDes clock; if a *new*
`sec_ctrl`-class clock is next, QSDK also parents MHT_SEC_CTRL_CLK to XO/25M and
we'd add that too.

### Boot log `_8` -> ROOT CAUSE: mainline CMN PLL lock-bit is wrong on IPQ9574 (2026-07-14)

`assigned-clocks` fired at nsscc probe (1.07s) and the RCG update FAILED:
`nss_cc_sys_clk_src: rcg didn't update` (trace `of_clk_set_defaults ->
clk_rcg2_set_rate -> update_config`, x24=0x17d7840=25 MHz). An RCG can't update
unless its **source (the 50 MHz `ETH0_50MHZ` from the CMN PLL) is running** - so
the 50 MHz reference isn't reaching the chip. Chased it to the CMN PLL driver:

**`drivers/clk/qcom/ipq-cmn-pll.c` polls the wrong lock bit.**
`clk_cmn_pll_set_rate()` waits on `CMN_PLL_CLKS_LOCKED = BIT(8)` at reg 0x64. On
IPQ9574 the lock is **bit 2**, not bit 8:
- Live vendor read (x3): `0x9b064 = 0x00000007` (bits [2:0] set, **bit 8 clear**)
  while ethernet works.
- QSDK `ssdk_clk.c`: `#define CMN_PLL_LOCKED 0x4` (BIT(2)).
- Qualcomm U-Boot (`ipq5018.c`): same `CMN_PLL_LOCKED 0x4` at `0x9B064`.

So mainline's lock poll **always times out** -> `clk_cmn_pll_set_rate` returns
`-ETIMEDOUT`. RDP reference boards mask this (non-fatal via `of_clk_set_defaults`,
PLL physically locks on bit 2 anyway, and their U-Boot already parented the
downstream nss_cc tree off the output); our consumer board, which needs Linux to
bring that tree up, does not.

**Fix (patch 0364):** `CMN_PLL_CLKS_LOCKED` BIT(8) -> BIT(2). Genuine upstream
IPQ9574 bug, not MBE7000-specific - upstreamable on its own. Kept the
`assigned-clocks` sys_clk_src config to test whether, with the PLL now reported
locked, the RCG updates. Rebuilding (build_9). If sys_clk_src configures now,
expect the cascade (srds/gephy sys -> calibration -> 312.5 -> switch_core/mac ->
PHYs probe). If it still fails, the sys config runs too early (before probe_once
powers the chip) and must move into the driver.

### Boot log _9 verdict (BIT(2) fix flashed) - CMN PLL was NOT the blocker

`MBE70_upgrade_boot_9.log` is **byte-for-byte identical** to _8 at the failure:
`1.240s nss_cc_sys_clk_src: rcg didn't update` -> `1.751s nss_cc_srds1_sys_clk
status stuck at 'off'` -> `1.90s qca8084_qxgmii_set_mode -16`. The BIT(2) patch
DID compile in (no CMN PLL lock timeout / no assigned-clock error at cmn_pll
probe now, vs the theory), so the lock bit is genuinely fixed - but it changed
nothing here. **The CMN PLL lock bit was a real latent upstream bug, not the
cause of the LAN failure.** Keep patch 0364 (still correct, upstreamable), but
the diagnosis in the block above was wrong about it being the root.

**Corrected root cause (high confidence):** `nss_cc_sys_clk_src` (RCG 0x1a0) has
*exactly one* possible source, `P_XO` (`ftbl_nss_cc_sys_clk_src = F(25000000,
P_XO, 2, ...)`, `nss_cc_xo_map` has only `{P_XO, 0}`). The RCG update handshake
only completes when the **selected source is physically toggling**. The source
is `DT_XO = <&cmn_pll ETH0_50MHZ_CLK>` - the SoC's 50 MHz reference delivered to
the QCA8084's XO input pin. So "rcg didn't update" means **the 50 MHz is not
reaching the QCA8084's XO pin.** The chip itself is alive and reachable: the
driver reads the CMD_UPDATE bit back (=1, never self-clears), so MDIO R/W to the
nss_cc window works; only the reference clock is absent. `nss_cc_qca8k_probe`
already does `devm_clk_get_enabled(dev, NULL)` on clocks[0] = `ETH0_50MHZ_CLK`,
so the CMN PLL output *gate* is enabled from Linux - yet the clock still isn't
at the pin.

Key contradiction to resolve: the **vendor QSDK firmware works on the same board
and same Linksys U-Boot** with LAN up, so the board CAN deliver this 50 MHz.
Something openwrt does (or fails to do) leaves the chip without its XO. QSDK's
ssdk treats `MHT_XO_CLK_RATE_50M` as an always-present external given and never
sets up a SoC->chip clock - so on the vendor it is delivered by U-Boot/board
hardware and stays up. Candidates for the openwrt-specific regression:
 (a) a board-level enable (GPIO/LDO/load-switch powering the QCA8084's 50 MHz
     oscillator or the SoC clock-output pad) that vendor drives and we don't;
 (b) the SoC 50 MHz clock-output *pinmux* (TLMM) that U-Boot sets but openwrt's
     pinctrl/gcc reverts;
 (c) openwrt's `clk_cmn_pll_set_rate` block reset (`CMN_ANA_EN_SW_RSTN` toggle)
     re-initialising a PLL U-Boot already configured and not restoring the eth
     output the way U-Boot did.
Next: get **ground-truth vendor register/GPIO data over SSH** (see diagnostic
below) rather than guess a 7th time. Specifically need: vendor GPIO states
(which pins are driven that our DTS doesn't), CMN PLL page dump (0x9b000), and
whether the QCA8084 XO is SoC-sourced or a discrete board crystal.

### ROOT CAUSE FOUND (vendor SSH diagnostic) - CMN PLL output clocks ungated

Dumped the working vendor firmware live (`~/openwrt_debug/vendor_diag_out.txt`,
`vendor_diag.sh`). The QCA8084's XO **is** the SoC CMN PLL `eth0-50mhz` output
(no discrete crystal). The decisive difference is a **single register the
mainline `ipq-cmn-pll.c` never writes**:

QSDK's `qca_cmn_clk_config()` (in `qca/src/linux-5.4/drivers/net/phy/mdio-qca.c`,
the "CMN clock reset done" logged at vendor boot) does THREE things to the CMN
PLL: (1) select refclk (0x784), (2) reset the block (0x780, `CMN_ANA_EN_SW_RSTN`),
and **(3) ungate the fixed output clocks at `CMN_PLL_OUTPUT_RELATED_1` = 0x79c**
(`CMN_PLL_CLK25M_EN` BIT15, `CLK50M_62P5M_EN/EN1/EN2` BIT11/10/14). Mainline's
driver does (1) and (2) and the lock poll, but **never touches 0x79c** - it
assumes the bootloader already ungated the outputs (true on RDP, false on
Linksys). So `eth0-50mhz` is produced internally but not driven out to the
QCA8084's XO pin -> the switch's `nss_cc_sys_clk_src` RCG (only parent = that XO)
can never update -> entire switch clock tree dead. Exactly the _8/_9 symptom.

Vendor register proof (`devmem`):
- `0x9b064 = 0x07` (locked, bit 2 - confirms the 0364 lock-bit fix too)
- `0x9b784 = 0x8017` (refclk: internal, index 7 = 48 MHz - same as mainline)
- **`0x9b79c = 0xfc00`** (GENMASK(15,10) all set: 25 MHz + 50/62.5 MHz taps ON)

**Fix (patch 0365):** after the lock poll in `clk_cmn_pll_set_rate()`,
`regmap_update_bits(0x79c, GENMASK(15,10), GENMASK(15,10))`. Reproduces the
vendor's `0x9b79c = 0xfc00`. Upstreamable alongside 0364 (both are IPQ9574 CMN
PLL cold-bring-up bugs mainline masks by relying on the RDP bootloader).

Note the earlier `_8` diagnosis block above (blaming the lock bit) was wrong
about the *cause* - 0364 is a real bug but the missing 0x79c ungate (0365) is
what actually starves the QCA8084. Both patches are kept.

GPIO cross-check (vendor `/sys/kernel/debug/gpio`): gpio60 `out high` (QCA8084
out of reset) and gpio36 `out high` (WAN PHY) match our DTS; no extra
clock/LDO-enable GPIO that we were missing - the gap was purely the 0x79c gate.

**Build note / gotcha:** adding a new patch file to `patches-6.18/` invalidates
the kernel `.prepared` stamp, so the next `make target/linux/*` re-runs prepare
and **re-applies the whole patch stack from pristine** - any manual `build_dir`
edits are discarded and a malformed patch fails the build (no `.rej`, just
"Patch failed! Please fix ..."). Always generate patch bodies with `diff -u`
(a hand-written empty context line = "malformed patch"), and verify with
`patch --dry-run` before building.

### Boot log _11 + second vendor SSH session: ungate alone insufficient

Log _11 proved the probe-time 0x79c ungate **executed** (`IPQ9574: ungated CMN
PLL eth outputs (0x79c), ret=0` at 0.087s) yet `sys_clk_src` still failed at
1.09s -> the 50 MHz is STILL not reaching the QCA8084. Conclusion: the ungate
alone is not enough; QSDK's `qca_cmn_clk_config()` is a 3-step sequence
(refclk select 0x784 -> **block reset pulse 0x780/BIT(6)** -> ungate 0x79c) and
we only did step 3. Plausible failure mode: Linksys U-Boot leaves the CMN PLL
analog block held in reset (0x780 bit6=0) or otherwise unconfigured; vendor
reads `0x9b780 = 0xFF` (bit6=1, out of reset). Mainline never writes 0x780/0x784
outside .set_rate, which never runs (clk core skips set_rate when U-Boot left
CMN_PLL_CLK at the DT-assigned 12 GHz - discovered analyzing _10).

**Current build**: full qca_cmn_clk_config sequence at probe (refclk index 7
internal-48MHz to match vendor 0x9b784=0x8017, reset pulse, ungate) plus
`dev_info` dumps of 0x780/0x784/0x79c/0x64 BEFORE and AFTER - the next boot log
finally shows what U-Boot left in these registers.

**Vendor QCA8084 internal regs read over paged MDIO** (ssdk_sh `debug phy set
0x18 0x0c <page>` then `debug phy get 0x1X <r1>`; MHT split scheme from
mdio-qca.c `split_addr`: r1=A&0x1c, r2=(A>>5)&7 -> lo phy 0x10|r2, page=(A>>8)
&0xffff -> written via phy 0x18 reg (A>>24)&0x1f; reads are stable/repeatable
and cross-validated by `ssdk_sh debug reg get 0x0c8001a0 4` returning identical
data):
- `sys_clk_src CMD 0x1A0 = 0x0682005f`, `CFG 0x1A4 = 0x0005001a` (odd - doesn't
  decode as a cleanly-programmed RCG2; possibly reflects reset/default state,
  NOT decoded confidently yet)
- `SRDS0_SYS_CBCR 0x1A8 = 0x0` (off), **`SRDS1_SYS_CBCR 0x1AC = 0x220c0001`
  (bit0 enabled)** on the working vendor
- `EPHY0..3_SYS_CBCR` = 0x8020 / 0x40400000 / 0x32300000 / 0x1a0 (garbage-ish,
  decode not trusted)
- `WORK_MODE 0xC90F030 = 0x6862` -> bits[5:0] = **0x22**, which matches NONE of
  QSDK's enums (UQXGMII=0x2F which mainline uses, SGMII_UQXGMII=0x27,
  SWITCH_BYPASS_PORT5=0x20, SWITCH=0x10). Unresolved - either the paged reads
  alias somewhere or the vendor genuinely runs an undocumented mode.
- `GCC_GEPHY_MISC 0x304 = 0x40de1` (bits[4:0]=1, not the all-cleared state
  qca_mht_clock_init would leave -> vendor DTB likely lacks `mdio_clk_fixup`,
  i.e. vendor MHT bring-up is done by ssdk's qca_mht_hw_init at ~10s, not by
  the mdio driver at probe).

### *** ROOT CAUSE FOUND (log _13 + live OpenWrt shell): gpio60 held the QCA8084 in reset ***

The WAN-port SSH shell worked (`ssh root@192.168.2.1`), and with `mdio-tools`
baked in the whole multi-week mystery collapsed in minutes:

1. **CMN PLL was never the problem.** Live OpenWrt `dev_info` dump: pre-init
   `0x780=0xff 0x784=0x8017 0x79c=0xfc00 locked(0x64)=0x7` - i.e. **U-Boot
   already configures the CMN PLL identically to the vendor** (locked, refclk
   internal-48MHz, all eth outputs ungated). Patches 0364 (lock bit) and 0365
   (0x79c ungate) plus the probe-time full-init were all fixing a non-problem.
   0364 is still a genuine upstream bug (harmless here); 0365/full-init reverted.
   `.set_rate` is skipped anyway (clk core no-op when U-Boot left CMN_PLL_CLK at
   12 GHz), so none of it ever ran.

2. **The QCA8084 was dead on MDIO the entire time.** `mdio 90000.mdio-1` scan
   showed ONLY the WAN QCA8081 (0x1c) and 0x1d; the switch's own addresses
   (0x01-0x06, 0x18) and the paged nss_cc window (phys 0x10-0x18) all returned
   `0xffff`. The kernel's "sys_clk_src = 3.125 MHz" in clk_summary was an
   **artifact of reading 0xffff** (div field 0x1f -> /16, 50/16 = 3.125). Every
   "rcg didn't update" / "-16" was read/write into a chip that never responded.

3. **gpio60 was the cause.** `/sys/kernel/debug/gpio`: OpenWrt `gpio60 : in low`
   (floating, chip in reset) vs vendor `gpio60 : out high` (driven, out of
   reset). gpio36 (WAN PHY) is `out high` on both - which is exactly why the WAN
   PHY works and the switch does not. Our old `phy-reset-gpio` (which mainline
   ignores) meant **nothing ever drove gpio60**, so the QCA8084 stayed in POR
   reset forever.

4. **Live proof.** `echo 572 > /sys/class/gpio/export` (base 512 + line 60),
   `direction=out`, `value=1` -> instantly the MDIO scan showed all four internal
   PHYs (`0x10-0x14` id 0x004dd0b1) + nss_cc, and the nss_cc registers read
   **byte-identical to the vendor**: WORK_MODE `0x6862`, sys_clk_src CMD
   `0x0682005f`, CFG `0x0005001a`. (Do NOT then unbind/rebind the nss_cc driver
   to force reconfig - `qcom_cc_really_probe` re-registers already-registered
   clocks and NULL-derefs -> kernel panic + reboot. Learned the hard way.)

**THE FIX (DTS):** a `gpio-hog` on `&tlmm` drives gpio60 output-high at pinctrl
probe, before any consumer. Removed the `phy-reset-gpio` from `&mdio`. A static
hog (not reset-gpios) because mainline's MDIO core pulses reset-gpios low
mid-registration and the chip does not recover (the original log _4 -110). Also
removed the CMN PLL probe-time init block (build_dir) as unnecessary/risky.

Everything downstream (patches 0362/0363 work-mode + SerDes bring-up, the DT
`assigned-clocks` sys_clk_src=25MHz) should now run against a LIVE chip and was
only ever failing because the chip was in reset. This is the first build that
can actually work.

### WAN shell plan (breaks the blind-iteration loop)

Log _11 shows the **QCA8081 WAN PHY probes fine on mainline** (`PHY
[90000.mdio-1:1c] driver [Qualcomm QCA8081]`, wan configures usxgmii; the
pcs2 "10GBASE-R link not up" warning is just no-cable). Current build bakes in
`files/etc/uci-defaults/99-mbe7000-debug-wan-access`: wan = static
**192.168.2.1/24**, wan6 deleted, firewall wan-zone input=ACCEPT. If WAN links
up, plug a laptop (static 192.168.2.2/24) into the WAN port -> `ssh
root@192.168.2.1` (no password) -> live devmem/clk_summary/MDIO on OpenWrt.
REMOVE this uci-default once LAN works.

Blind iteration is the only channel (this unit has **no usable serial RX** -
only the TX pad carries 1.8 V; the RX pad is dead/unpopulated, confirmed with
a loopback-tested 1.8 V adapter). Next investigative steps, when picked up:
- Diff our DTS against @kravasuper's fork (the only claimed-working qca8084).
- Try releasing gpio36 alongside gpio60 as qca8084 reset; test reset polarity.
- Track PR #20604 upstream for the eventual qca8084 fix.

## LIVE-DEBUG REFERENCE (WAN SSH + mdio-tools) - everything learned 2026-07-14

This is the consolidated, reproducible reference for debugging this board over
the network. It ended the blind-flash loop.

### Access / environment
- **OpenWrt over WAN:** `ssh -oHostKeyAlgorithms=+ssh-rsa
  -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@192.168.2.1`
  (no password). Enabled by `files/etc/uci-defaults/99-mbe7000-debug-wan-access`
  (wan static 192.168.2.1/24, wan6 deleted, wan-zone input ACCEPT). Laptop on
  the WAN port with static 192.168.2.2/24. REMOVE this uci-default before release.
- **Vendor QSDK over LAN:** `ssh -oHostKeyAlgorithms=+ssh-rsa root@192.168.1.1`,
  password `9fBt6y73p@`, Linux 5.4.213, model string `IPQ9574/AP-AL02-C4` (Linksys
  shipped the QSDK reference DTS). Own device, authorised for debugging.
- **Tooling baked into the OpenWrt debug image:** `mdio-tools` (+
  `kmod-mdio-netlink`) via `CONFIG_PACKAGE_mdio-tools=y` /
  `CONFIG_PACKAGE_kmod-mdio-netlink=y`. `CONFIG_KERNEL_DEVMEM=y` added but busybox
  devmem applet did NOT stick through `make defconfig` - SoC MMIO is readable via
  `/sys/kernel/debug/regmap/<dev>/registers` instead (cmn_pll = `9b000.clock-
  controller`, SoC nss_cc = `39b00000.clock-controller`, gcc = `1800000.clock-
  controller`; the MDIO QCA8084 nss_cc is NOT in regmap debugfs).
- **No `scp`/sftp on the device** (`/usr/libexec/sftp-server: not found`) - push
  files with `ssh root@192.168.2.1 'cat > /tmp/x' < localfile`.
- The vendor QSDK has **no `mdio`/`devmem` raw tool exposed usefully** but has
  `ssdk_sh`; MHT registers read via `ssdk_sh debug phy ...` (see below).

### Raw MDIO / QCA8084 internal register access (the paged scheme)
The QCA8084 ("MHT") 32-bit internal registers are reached over C22 MDIO by a
split-address paging scheme (from QSDK `qca/src/linux-5.4/drivers/net/phy/
mdio-qca.c`, `split_addr()` / `qca8386_read`). For a 32-bit address `A`:
```
r1   =  A        & 0x1c        # low reg (even), hi half at r1|2
r2   = (A >> 5)  & 0x7         # low PHY addr = 0x10 | r2
page = (A >> 8)  & 0xffff      # page value
pr   = (A >> 24) & 0x1f        # page-write reg on PHY (0x18 | (A>>24)>>5) == 0x18
# read:  mdio 0x18 pr page ; lo = mdio (0x10|r2) r1 ; hi = mdio (0x10|r2) r1|2 ; val=(hi<<16)|lo
```
`mdio-tools` raw C22 syntax on OpenWrt: `mdio 90000.mdio-1 <phyaddr> <reg> [val]`
(read omits val). A ready-made helper is staged at `/tmp/mht.sh` on the device
(`sh /tmp/mht.sh dump` / `rd 0xADDR` / `wr 0xADDR 0xVAL`). On the vendor use
`ssdk_sh debug phy set 0x18 0x0c <page>` then `ssdk_sh debug phy get 0x1X <r1>`
after `device id set 1` is NOT needed (page scheme is on dev0's bus directly).

Key QCA8084 register addresses (QSDK names): `WORK_MODE 0xC90F030`
(bits[5:0], QXGMII = 0x2F = BIT5|GENMASK(3,0); observed 0x6862 low byte 0x62 -
top bits are non-mode status), `EPHY_CFG 0xC90F018`, `sys_clk_src CMD 0xC8001A0`
/ `CFG 0xC8001A4`, `SRDS0/1_SYS_CBCR 0xC8001A8/AC`, `EPHY0..3_SYS_CBCR
0xC8001B0..BC`, `GCC_GEPHY_MISC 0xC800304`. CMN PLL (SoC MMIO) at `0x9b000`:
lock `0x64` bit2, power/reset `0x780` bit6, refclk `0x784`, output-enable `0x79c`
(`GENMASK(15,10)`; vendor = 0xfc00).

### THE root cause: gpio60 (see ROOT CAUSE section above for the full story)
`/sys/kernel/debug/gpio`: gpio base is **512** on OpenWrt (vendor base 447);
gpio60 global = 572. Live proof: `echo 572 > /sys/class/gpio/export ; echo out >
.../gpio572/direction ; echo 1 > .../gpio572/value` -> QCA8084 instantly
enumerates on MDIO (0x10-0x14 internal PHYs id `0x004dd0b1`, 0x15, nss_cc) and
all its registers match the vendor byte-for-byte. Without it, every MHT MDIO
addr (0x01-0x18) reads `0xffff`.

### Post-hog boot state (log _14, gpio60 hog in DTS) - what still fails
Chip alive from boot; `nss_cc_sys_clk_src` = **25 MHz enabled**, `srds1_sys` =
25 MHz enabled. BUT:
- `nss_cc_sys_clk_src: rcg didn't update` STILL logged at 0.495s. This is a
  **transient poll-timeout, not fatal**: `clk_rcg2` writes CFG then polls the
  UPDATE bit; the CFG write lands but the source needs time to stabilise, so the
  synchronous poll (`clk-rcg2.c:136`, WARNING) times out while the value
  eventually takes (hence 25 MHz when read later). Same pattern seen for
  `mac2_rx_clk_src` and the "status stuck at on" mac branches during calibration.
- SerDes calibration (`qca8084_do_calibration`, polls `CALIBRATION_DONE`)
  SUCCEEDS (no "PCS calibration timeout!"); the 312.5 MHz roots
  (`qca8k-uniphy1-tx312p5m`/`rx312p5m`, DT fixed-clocks) read 312.5 MHz.
- Failure point: `qca8084_qxgmii_set_mode+0x26c` = `qca8084_xpcs_clock_parent_set`,
  channel 1 (`nss_cc_mac2_rx_clk_src: rcg didn't update`). Channel 0's mac1_rx
  reparented OK (CFG=312.5) but nothing is enabled (all mac clocks count 0), and
  the qca8084 PHY probes then fail `-16`, leaving all 4 LAN PHYs unbound.
- **Bug identified:** `PCS_RX_ROOT_CLK`/`PCS_TX_ROOT_CLK` (the reparent targets)
  are never `clk_prepare_enable`'d - the driver only enables `PCS_CLK`. An RCG
  can only complete its update onto a *running* source; the roots read 312.5 MHz
  but are gated OFF (clk_summary count 0). Fix (build_dir, to fold into 0363):
  enable both PCS root clocks + 10ms settle before the reparent loop in
  `qca8084_xpcs_clock_parent_set()`. Building/flashing as _15.

### Clock-tree facts (live clk_summary, chip out of reset)
- `eth0-50mhz` (CMN PLL) enabled, 50 MHz, consumer `90000.mdio-1:18` (nss_cc-
  qca8k) - this is the QCA8084 XO. `eth1/eth2-50mhz` disabled.
- Post-boot mac clocks are mixed: mac1 all 312.5 MHz (ch0 done), mac2 25/12.5,
  mac3 19.5/1.22M, mac4/5 50 MHz - i.e. only channel 0 got part-way configured.
- The DT `assigned-clocks = <&qca8k_nsscc NSS_CC_SYS_CLK_SRC>` (25 MHz) runs at
  nss_cc probe (~0.5s), which is EARLIER than the qca8084 work-mode/calibration;
  the transient failure there cascades. QSDK order is work_mode -> calibration ->
  switch_reset -> switch_init -> gcc_clock_init(sys_clk) - i.e. sys_clk config
  comes AFTER calibration. If the PCS-root fix is not enough, the next move is to
  stop programming sys_clk_src via premature DT assigned-clocks and do it inside
  the qca8084 driver after work-mode, matching QSDK ordering.

### GOTCHAS learned the hard way
- **Do NOT unbind/rebind the nss_cc clock provider** (`echo ... >
  /sys/bus/mdio_bus/drivers/qcom,qca8k-nsscc/unbind|bind`): re-probe hits
  `qcom_cc_really_probe -> devm_clk_register_regmap -> __clk_register` on
  already-registered clocks and NULL-derefs -> **kernel panic + reboot**. Rebinding
  the qca8084 PHY devices instead just returns EBUSY (sysfs bind rejected), it
  does not cleanly re-run the shared package init. To re-test bring-up, reflash.
- All CMN PLL patches/init (0364 lock-bit, 0365 0x79c ungate, probe-time full
  init) were fixing a NON-problem: U-Boot already leaves the CMN PLL configured
  identically to the vendor (0x780=0xff, 0x784=0x8017, 0x79c=0xfc00, locked=0x7).
  `.set_rate` is skipped by the clk core anyway (rate unchanged at 12 GHz). 0364
  is a real upstream bug (harmless here, keep); 0365 + the probe-init were
  reverted. The "rcg didn't update" was NEVER a CMN PLL problem.
- `mdio 90000.mdio-1` (no args) bus scan is the fastest liveness check: if it
  shows only 0x1c/0x1d, the QCA8084 is in reset; if it shows 0x10-0x15 too, the
  chip is up. WAN QCA8081 is 0x1c (`0x004dd101`), links up at 1 Gbps.
- **Live nss_cc register reads RACE with the kernel's periodic PHY polling.**
  The paged access sets a shared page register (phy 0x18 reg 0x0c); a concurrent
  kernel MDIO access between the page-write and the lo/hi reads returns
  wrong-page data (saw mac2_rx come back as `0x0682005f` = sys_clk_src, mac_tx as
  `0x6862` = WORK_MODE). Only trustworthy right after gpio bring-up before
  drivers poll, or on the vendor via `ssdk_sh` (atomic). Read vendor for ground
  truth instead.

### Boot log _15: PCS-root-enable fix did NOT help; failure still mac2_rx (ch1)

Enabling `PCS_RX/TX_ROOT_CLK` + 10ms settle before the reparent (in
`qca8084_xpcs_clock_parent_set`) did not change the outcome: still
`nss_cc_mac2_rx_clk_src: rcg didn't update` at channel 1, `qca8084_qxgmii_set_mode
+0x2dc`, all four PHYs `-16`. Channel 0 (mac1) reparents; channel 1 (mac2)
consistently fails (deterministic, not random). So the reparent-target being
gated was not the cause.

### QSDK vs mainline: RCG handshake identical, ORDER + PARENT differ

- **RCG update handshake is byte-identical** between QSDK `ssdk_mht_clk_update`
  (poll CMD_UPDATE self-clear, 1000x udelay(1)) and mainline `update_config`
  (`clk-rcg2.c:136`, 500x udelay(1)). So the failure is chip state/order, not
  the poll. (Mainline's timeout is actually 2x shorter - a possible minor factor
  but not the root.)
- **QXGMII parents are CROSSED in QSDK** (`ssdk_mht_gcc_port_clk_parent_set`,
  `MHT_PHY_UQXGMII_MODE`): `port_tx_parent = MHT_P_UNIPHY1_RX312P5M`,
  `port_rx_parent = MHT_P_UNIPHY1_TX312P5M`. Mainline
  `qca8084_xpcs_clock_parent_set` does straight `XPCS_RX_SRC->PCS_RX_ROOT` /
  `XPCS_TX_SRC->PCS_TX_ROOT`. NEEDS VERIFYING whether PCS_RX_ROOT actually maps
  to the crossed uniphy clock (would fail all channels if wrong, though - so this
  alone does not explain ch0-ok/ch1-fail).
- **QSDK enables the common clock infrastructure FIRST**
  (`ssdk_mht_gcc_common_clk_parent_enable`: switch_core->UNIPHY1_TX312P5M +
  enable, apb, ahb->UNIPHY1_TX312P5M, srds1_sys, gephy0-3_sys, sec_ctrl) and
  only THEN does per-port `gcc_port_clk_parent_set` + `port_clk_en_set`. Mainline
  reparents the port clocks inside `qca8084_qxgmii_set_mode` and enables the
  common infra (`qca8084_package_clock_init`: switch_core, apb, ahb) AFTER. Prime
  suspect for the remaining failure: the 312.5 MHz SerDes root the mac RCGs
  reparent onto is not fully brought up because switch_core/UNIPHY1_TX312P5M is
  not enabled yet.
- QSDK overall order (`qca_mht_hw_init`): work_mode_init -> interface_mode_init
  (SerDes calibration) -> switch_reset -> switch_init -> ssdk_mht_gcc_clock_init
  (common infra, THEN per-port). Mainline probe_once order: work_mode -> EPHY LDO
  -> qxgmii_set_mode (calibration + port reparent) -> package_clock_init (common
  infra). To match QSDK, package_clock_init (or at least switch_core enable)
  should run BEFORE the port reparent.

RCG offsets (mainline nsscc-qca8k.c, add 0xC800000 for the QSDK phys addr; CFG =
CMD+4, src_sel = CFG bits[10:8]): switch_core 0x0, mac1_tx 0x40, mac1_rx 0x60,
mac2_tx 0x80, mac2_rx 0xa0, mac3_rx 0xe0, mac4_rx 0x120, sys_clk_src 0x1a0,
SRDS0/1_SYS_CBCR 0x1a8/0x1ac. Vendor read staged in scratchpad
`vendor_macclk.sh` to capture the working src_sel + enable state.

### CORRECTION: userspace paged nss_cc reads are UNRELIABLE - discard them
The QSDK split-address paging (page-write to phy 0x18 reg 0x0c, then read at
phy `0x10|r2`) collides with the QCA8084's REAL internal PHY addresses 0x10-0x15
(the four EPHYs id `0x004dd0b1` sit at 0x10-0x13, and 0x15 answers as
`0x06820805`). The page redirect does not take through `mdio`/`ssdk_sh debug
phy`, so the reads return those PHYs' STANDARD C22 registers, not the paged
nss_cc data. Tells: values like `0x1040` (a BMCR), `0x004d` (PHY-ID hi), and the
same `0x0682005f` coming back for multiple distinct addresses. This means the
"vendor sys_clk_src = 0x0682005f / WORK_MODE = 0x6862 / SRDS1_SYS_CBCR =
0x220c0001" reads from BOTH sessions are bogus and must not be trusted as target
values. What IS trustworthy: the `mdio 90000.mdio-1` bus SCAN (liveness), SoC
MMIO via `/sys/kernel/debug/regmap/*/registers` + devmem, `clk_summary` rates
(the kernel's own qca8k regmap access is correct), and kernel dmesg. The
gpio60 root cause stands (proved by bus enumeration, not paged reads). To read
QCA8084 nss_cc registers reliably, add temporary `dev_info` dumps inside the
driver (which uses the correct regmap) rather than poking from userspace.

### _17: ROOT of the ch1 failure - reparent runs before XPCS is up (reorder fix)

_16 retry ran all 10 times and every one failed -> the ch1 reparent is
**structural, not transient**. Retry reverted.

Live clk debugfs (kernel's correct access) pinned it down:
- `nss_cc_mac1_rx_clk_src`: parent = `qca8k-uniphy1-tx312p5m` (312.5M, reparented)
- `nss_cc_mac2_rx_clk_src`: parent = `eth0-50mhz` (25M, still default)
- both have the SAME possible_parents `{eth0-50mhz, qca8k-uniphy1-tx312p5m}`.

Same target, same mux - ch0 switched, ch1 could not. The target
`qca8k-uniphy1-tx312p5m` is a single DT fixed-clock shared by all mac RCGs, so
the difference is the PHYSICAL per-channel SerDes output: only channel 0's
312.5 MHz is toggling at reparent time. Channels 1-3 only start producing their
clock once the XPCS is reset/enabled in `qca8084_xpcs_set_mode()` (BaseR up ->
USXGMII/QXGMII -> XPCS reset -> per-channel AN config) - which the driver ran
AFTER the reparent.

**Fix (_17):** reorder `qca8084_qxgmii_set_mode()` to
`pcs_set_mode` (calibration) -> `xpcs_set_mode` (XPCS/all-channel bring-up) ->
`xpcs_clock_parent_set` (reparent). Matches QSDK, which does XPCS/interface
config in `qca_mht_interface_mode_init` BEFORE the port-clock reparent in
`ssdk_mht_gcc_clock_init`. (Kept the PCS-root clk_prepare_enable from _15 - it is
QSDK-aligned and harmless.) To fold into patch 0363 once confirmed.

### _17 RESULT: reparent fixed, but exposed XPCS soft-reset failure (next layer)

The reorder WORKED for the reparent: `nss_cc_mac2_rx_clk_src: rcg didn't update`
is GONE (only the harmless `sys_clk_src` transient remains). New failure, one
layer deeper:
```
[1.860] mdio_bus 90000.mdio-1:07: XPCS reset failed!
[1.860] Qualcomm QCA8084 90000.mdio-1:01: probe ... failed with error -110
```
This is `qca8084_xpcs_set_mode()`'s XPCS soft reset (poll DIG_CTRL1
XPCS_RESET/BaseR) timing out, NOT the old `phy_poll_reset failed: -110` (that was
the chip held in reset). Confirmed live: chip fully alive, `mdio 90000.mdio-1`
scans 0x10-0x14 (internal EPHYs) + 0x15 (XPCS `0x06820805`) + 0x1c (WAN). Note
`xpcs_set_mode` had NEVER run before in any boot (the reparent always aborted
first), so this XPCS reset failure was latent all along, only now reachable.
The reorder + gpio60 fix are both correct; keep them. IMPORTANT ordering fact:
in `_17`, `xpcs_set_mode` runs with the mac clocks still at DEFAULT (reparent is
after it) - and QSDK ALSO does its XPCS soft reset before the port-clock
reparent, so the XPCS soft reset must NOT depend on the mac clocks being at
312.5. Its failure is a missing/most-likely uniphy-side step, not clock rate.

### QSDK QXGMII bring-up sequence (authoritative) - the target to match

`qca_mht_hw_init` order (ssdk_mht.c): work_mode_init -> **interface_mode_init**
-> switch_reset -> switch_init -> **gcc_clock_init** (=common infra + per-port
reparent). So ALL SerDes/XPCS bring-up (incl. XPCS soft reset) is in
interface_mode_init, BEFORE any port-clock reparent. Matches our `_17` order.

`mht_interface_uqxgmii_mode_set` (mht_interface_ctrl.c ~428-510), IN ORDER:
1. datapass config = USXGMII (MMD1 GMII_DATAPASS_SEL)
2. **`ssdk_mht_port_clk_reset(UNIPHY|EPHY)` for ports 1-4** (toggle CBCR reset
   bit(2) of the per-port uniphy+ephy clock branches) - BEFORE calibration
3. uniphy PLL ana soft reset (`MHT_UNIPHY_PLL_POWER_ON_AND_RESET` 0x40 bit) ->
   mdelay(10) -> ana soft release
4. **`mht_uniphy_calibration`** (poll calibration done)
5. **enable SSCG** (MMD1 CDA_CONTROL1 bit 0x8 = SSCG_ENABLE)
6. **release XPCS** (`ssdk_mht_clk_deassert(MHT_UNIPHY_XPCS_RST)`)
7. **ethphy software reset for ports 1-4** (`qca808x_phy_reset` per internal EPHY)
8. set BaseR mode (MMD3 PCS_CTRL2 = 10GBASE_R)
9. wait 10G BaseR link up (`mht_uniphy_xpcs_10g_r_linkup`)
10. enable UQXGMII (MMD3 DIG_CTRL1 0x200 = USXGMII_EN)
11. set QXGMII (MMD3 VR_RPCS_TPC 0x1c00 = QXGMII_EN)
12. set AM interval (MMD3 MII_AM_INTERVAL)
13. **XPCS soft reset** (`mht_uniphy_xpcs_soft_reset`: MMD3 DIG_CTRL1 0x8000,
    poll 100x mdelay(1))

Mainline mapping (qca8084_serdes.c): `qca8084_pcs_set_mode` = PCS_CLK enable,
pcs rstc deassert, IPG tune, xpcs rstc ASSERT, pcs_set_interface_mode, reset 4
channels (reset_control_reset xpcs_ch.rstcs), `qca8084_do_calibration` (ana
reset/release + poll CALIBRATION_DONE), SSC_FIX_MODE, xpcs rstc DEASSERT. Then
`qca8084_xpcs_set_mode` = BaseR, wait BaseR up, USXGMII, QXGMII, AM interval,
XPCS soft reset (DIG_CTRL1 0x8000) + wait.

**Steps QSDK does that mainline appears to MISS before the XPCS soft reset (the
suspects for the -110):**
 (a) QSDK step 2: `port_clk_reset(UNIPHY|EPHY)` for all 4 ports (CBCR reset
     pulse) BEFORE calibration. Mainline resets the XPCS *channels*
     (reset_control_reset on xpcs_ch.rstcs) but maybe not the per-port UNIPHY/
     EPHY clock branches. This is the top suspect: the XPCS soft reset needs its
     uniphy clock domain properly reset/running for all channels.
 (b) QSDK step 5: SSCG enable (MMD1 CDA_CONTROL1 0x8). Mainline does SSC_FIX_MODE
     (CDR_CONTRL) instead - different register; may be insufficient.
 (c) QSDK step 7: ethphy software reset of the 4 internal EPHYs BEFORE the XPCS
     soft reset. Mainline resets the EPHYs later (in qca808x per-PHY probe).
 (d) QSDK "release XPCS" (step 6) = deassert a dedicated MHT_UNIPHY_XPCS_RST
     reset. Mainline deasserts xpcs rstc at the END of pcs_set_mode - verify the
     DT `resets`/reset-controller for the xpcs actually maps to the same bit.

### NEXT STEPS (when resumed)
1. Live-inspect the XPCS via C45 while the chip is up: `mdio 90000.mdio-1 0x07
   mmd ...` (XPCS is mdio addr 0x07 = 90000.mdio-1:07) - read MMD3 DIG_CTRL1
   (is XPCS_RESET stuck set? is BaseR up?), and the uniphy PLL/calibration
   status. Compare with QSDK expectations. (Reliable: C45 MMD reads are direct,
   not the broken paged nss_cc hack.)
2. Highest-probability fix: add the missing uniphy/ephy reset steps before the
   XPCS soft reset (suspect (a): per-port UNIPHY/EPHY clock-branch reset pulse),
   matching QSDK step 2. This likely lives in `qca8084_pcs_set_mode` (before/at
   calibration) - the mainline reset_control handling may need the uniphy branch
   resets that the qca8k-nsscc reset controller exposes.
3. Alternative if that fails: the circular-dependency model - reparent ch0 first
   (its SerDes clock is the only one up), then xpcs_set_mode, then reparent
   ch1-3. Less likely (QSDK does xpcs reset before ANY reparent), but keep as
   fallback.
4. When qca8084 PHYs finally bind: have user move cable WAN->LAN for the real
   end-to-end test (confirm port state live first so they don't lose access for
   nothing).

### Current tree state (build_dir, not yet folded to patches)
- `ipq-cmn-pll.c`: clean patched state (0364 BIT(2) lock bit kept; 0365 0x79c
  ungate kept but is redundant since U-Boot sets it - both harmless; probe-time
  full-init REMOVED).
- `qca8084_serdes.c`: (i) `qca8084_xpcs_clock_parent_set` enables PCS_RX/TX_ROOT
  before the reparent loop (from _15, kept); (ii) `qca8084_qxgmii_set_mode`
  reordered to pcs_set_mode -> **xpcs_set_mode -> xpcs_clock_parent_set** (_17).
  The _16 retry was REVERTED. Fold both into patch 0363 once LAN works.
- DTS: gpio60 `qca8084_reset_hog` in `&tlmm` (THE fix); phy-reset-gpio removed.
- Image config: mdio-tools + kmod-mdio-netlink + KERNEL_DEVMEM added (debug).
- `files/etc/uci-defaults/99-mbe7000-debug-wan-access` (WAN static 192.168.2.1,
  input ACCEPT) - **REMOVED 2026-07-15** (LAN works, no longer needed). NOTE:
  it already ran once on devices flashed before this, baking wan=static
  192.168.2.1 + wan-zone input=ACCEPT into their /etc/config; a config-keeping
  sysupgrade preserves that, so clean it on-device (revert wan to dhcp +
  firewall wan input=REJECT) or flash the next image with `sysupgrade -n`.
- Last flashed image `_17` sha256
  a9eb04a01dc01b9b9df79a3f7a4ceb8f70f0a2d012e81fbfe556fe269231438d.

### _16 attempt: bounded retry on the per-channel reparent
Since mac2 (ch1) reparent fails deterministically while mac1 (ch0) succeeds, and
the driver aborts on first failure (so mac2 never recovers, unlike sys_clk_src
which consumers re-enable later), added `qca8084_reparent_retry()` (10x,
5ms apart) around each `clk_set_parent` in `qca8084_xpcs_clock_parent_set`. If
the 312.5 MHz root is merely marginal just after calibration, retry completes
it; if all 10 fail, the failure is structural (not transient) and the next move
is the QSDK ordering: run `qca8084_package_clock_init` (common infra:
switch_core->UNIPHY1_TX312P5M enable, apb, ahb) BEFORE the port reparent, i.e.
split `qca8084_qxgmii_set_mode` into calibrate / reparent halves. Building _16.

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

## Build environment gotcha + EXACT build recipe

This host (Manjaro, very new glibc) can't build OpenWrt's pinned host
tools from source (`tools/m4`, `tools/sed`, `tools/libressl` all fail with
gnulib `off64_t`/`stdio.h` errors - old gnulib vs. too-new glibc, unrelated
to this device). Building works fine in an `ubuntu:22.04`-based Docker
container.

### The prebuilt image (use this - it already has deps + builder user)

A committed image **`mbe7000-build-img:latest`** already contains: the full
OpenWrt build-depends `apt-get install` list AND a `builder` user with
uid=1000/gid=1000 (matching the host user, so output files land with
correct ownership). Verified: `docker run --rm mbe7000-build-img:latest bash
-c 'id builder'` -> `uid=1000(builder) gid=1000(builder)`. So no apt / user
setup is needed anymore - just run make as the builder user.

### The build script (`docker-build.sh`)

Recreate this file (scratchpad is session-specific and gets cleaned up):

```bash
#!/bin/bash
# Build the MBE7000/MBE70 OpenWrt image inside the mbe7000-build-img container.
# The image already has all OpenWrt build-depends + a builder user (uid 1000).
set -o pipefail
cd /openwrt || exit 1
# Remove host-built binaries linked against the host's newer glibc (they fail in
# the container) so they get rebuilt in-container: kconfig conf/mconf AND the
# host apk tool if it was ever rebuilt natively (see 2026-08-05 gotcha below).
rm -f  scripts/config/conf scripts/config/mconf scripts/config/*.o
rm -rf staging_dir/host/bin/apk staging_dir/host/stamp/.apk_installed \
       build_dir/hostpkg/apk-3.0.5
# python3 host symlink must resolve inside the container (ubuntu 22.04:
# /usr/bin/python3 -> 3.10); repoint in case it dangles on the host.
[ -e staging_dir/host/bin ] && ln -sf /usr/bin/python3 staging_dir/host/bin/python3
su builder -c "cd /openwrt && make -j16 IGNORE_ERRORS=1" 2>&1
echo "=== MAKE EXIT: $? ==="
```

### GOTCHA (2026-08-05): dangling `python3` symlink after a host Python upgrade

`staging_dir/host/bin/python3` was a symlink to `/usr/bin/python3.10`. After the
Manjaro host upgraded system Python to 3.14, that symlink dangles, and ANY native
host-tool build that needs Python (meson -> the host `apk` tool) fails with
`.../python3: No such file or directory`. Symptoms cascade: `make
package/base-files/compile` and `make package/install` fail, so base-files never
rebuild and the rootfs stays stale even though `make target/linux/install`
"succeeds" (it only rebuilt the DTB + repackaged the OLD rootfs). Do NOT try to
fix this by rebuilding host tools natively - the host glibc is too new and it also
contaminates `staging_dir/host` with binaries the ubuntu:22.04 container can't run
(`GLIBC_2.38 not found`). Just build in Docker; `docker-build.sh` above now
repoints the symlink and removes any natively-built `apk`/kconfig binaries so the
container rebuilds them. (This is the same class of issue as the kconfig `conf`
GLIBC mismatch already documented.)

### GOTCHA: editing target base-files needs a rootfs reassembly, not just images

`make target/linux/install` rebuilds the DTB + repackages images but does NOT
reinstall the `base-files` package into the rootfs, and OpenWrt rebuilds packages
by version, not by `target/linux/.../base-files/` file mtimes. So after editing
e.g. `base-files/etc/board.d/02_network`, a plain `make target/linux/install`
ships the OLD scripts. A full `make world` (what `docker-build.sh` runs)
reassembles the rootfs and picks them up. Verify with:
`grep linksys,mbe70 build_dir/target-*/root-*/etc/board.d/02_network`.

### GOTCHA: changing .config (e.g. adding packages) needs defconfig on the HOST

The container builds work only because `.config` is normally already
consistent so `make` never re-runs the kconfig `conf` tool. `conf` in this
tree was compiled on the HOST (Manjaro, glibc 2.38) and **fails inside the
ubuntu:22.04 container** with `scripts/config/conf: ... GLIBC_2.38 not found`.
So when you change `.config` (adding LuCI, packages, kernel opts):

1. Edit `.config` (append `CONFIG_PACKAGE_xxx=y`) then run
   **`make defconfig` on the HOST** (works there; it only scans metadata +
   runs conf, not the host-tools that fail on Manjaro). Ignore the
   `libwayland does not exist` sdl3 WARNING - it is harmless, do NOT delete
   the sdl3 feed symlink (that just cascades more warnings and needs a
   `rm -rf tmp/` to recover).
2. Then build in the container. The `docker-build.sh` removes the stale
   host-built kconfig binaries first (`rm -f scripts/config/conf
   scripts/config/mconf scripts/config/*.o`) so `make` rebuilds them against
   the container glibc, then runs `make -j16 IGNORE_ERRORS=1` (NO defconfig
   in the container).

LuCI: enabled 2026-07-15 via `CONFIG_PACKAGE_luci=y` (metapackage ->
luci-light + luci-app-package-manager -> uhttpd, luci-base, rpcd,
luci-mod-{status,network,system}, firewall app, bootstrap theme). The base
build had the luci *feed* on (`CONFIG_FEED_luci=y`) but ZERO luci/uhttpd
packages selected, so there was no web server at all.

### The run command

```bash
docker rm mbe7000-rebuild2 2>/dev/null
docker run --name mbe7000-rebuild2 \
  -v /home/daniel/openwrt:/openwrt \
  -v /path/to/docker-build.sh:/docker-build.sh \
  mbe7000-build-img:latest bash /docker-build.sh > /path/to/build.log 2>&1
```

Run it in the background (a DTS-only change rebuilds just the dtb + FIT +
image, a few minutes; a kernel-source/patch change is longer). The built
toolchain persists in `staging_dir/toolchain-aarch64_cortex-a53_gcc-*`
across runs, so only the very first build ever pays the full toolchain cost.

### Incremental (fast) iteration - see memory `mbe7000-build-iteration-workflow`

For kernel driver tweaks, edit the file in
`build_dir/target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq95xx/linux-6.18.38/...`
directly and rebuild (make reuses the prepared tree); fold the change into a
proper `target/linux/qualcommbe/patches-6.18/NNNN-*.patch` and do one clean
full build to verify at the end. DTS lives at
`target/linux/qualcommbe/dts/ipq9574-mbe7000.dts` and is compiled into
`build_dir/.../linux-qualcommbe_ipq95xx/image-ipq9574-mbe7000.dtb` by the
image step - editing it there and running make is enough (no kernel rebuild).

Pre-flight a DTS edit WITHOUT a full build using the kernel's own dtc:
```bash
K=build_dir/target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq95xx/linux-6.18.38
cp target/linux/qualcommbe/dts/ipq9574-mbe7000.dts $K/arch/arm64/boot/dts/qcom/precheck.dts
( cd $K && cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I arch/arm64/boot/dts/qcom -I include -I scripts/dtc/include-prefixes \
    arch/arm64/boot/dts/qcom/precheck.dts | scripts/dtc/dtc -I dts -O dtb -o /tmp/pc.dtb - )
# warnings about i2c@/spi@ duplicate unit-address are pre-existing in ipq9574.dtsi, ignore.
rm $K/arch/arm64/boot/dts/qcom/precheck.dts
```

A successful full build produces, in `bin/targets/qualcommbe/ipq95xx/`:
- `bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-initramfs-uImage.itb`
- `bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-squashfs-factory.bin`
- `bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-linksys_mbe7000-squashfs-sysupgrade.bin`

## Dual-boot boot counter reset (auto_recovery) — 2026-07-15 [VERIFIED WORKING]

STATUS: verified on hardware. After flashing, U-Boot shows boot_count staying
at 0 across the first boot and subsequent reboots (no A/B failover). The
init.d/bootcount S99 reset works as intended.


U-Boot on this board has `auto_recovery=yes`: it increments a **boot counter**
each boot and, after `boot_part_ready` (=3) failed boots, fails the unit over
to the other A/B partition. Userspace must clear the counter after a good boot
or the unit ping-pongs partitions every 3 reboots.

**Where the counter lives (verified live on both our OpenWrt and vendor fw):**
- It is **NOT** a U-Boot text env var. `fw_printenv boot_count` -> "not
  defined". So `fw_setenv boot_count 0` is a NO-OP here (this is the trap;
  the Netgear wax620 pattern does not apply).
- The text env (`u_env`, `/dev/mmcblk0p21`, `0x0 0x40000`) only holds
  `boot_part`, `auto_recovery`, `boot_part_ready`, `bootcmd=bootipq`, etc.
  Vendor `/etc/fw_env.config` = `/dev/mmcblk0p21 0x0 0x40000`. We now SHIP this
  (2026-07-15): added a `linksys,mbe7000` case to the existing
  `package/boot/uboot-tools/uboot-envtools/files/qualcommbe_ipq95xx`
  (`ubootenv_add_mmc "u_env" "" "0x0" "0x40000"` -> generates that exact
  /etc/fw_env.config on first boot). Before this, `fw_printenv` failed with
  "Cannot parse config file '/etc/fw_env.config'". NOTE the effective file is
  `qualcommbe_ipq95xx` (BOARD_SUBTARGET), which the Makefile prefers over a
  plain `qualcommbe` file. [VERIFIED WORKING on hardware 2026-07-15 -
  fw_printenv reads the u_env text vars.]
- The **counter is a binary record in the `s_env` partition**
  (`/dev/mmcblk0p22`, GPT label `s_env`, `find_mmc_part s_env` resolves it),
  in the Linksys bootcounter format (little-endian):
  `struct { u32 magic=0x20110811; u32 count; u32 checksum=magic+count; }`
  (same `BOOTCOUNT_MAGIC` as OpenWrt `package/system/mtd/src/linksys_bootcount.c`).

**How the vendor resets it (authoritative):** `/etc/init.d/CBT_system_ready`
(START=99, after `sleep 20` + system-ready) runs the proprietary
**`recovery_emmc -c`**. (An older approach in `/etc/init.d/done`, now commented
out, just `dd if=/dev/zero of=$(find_mmc_part s_env)`.) The `recovery_emmc`
binary strings show `/dev/mmcblk0p%d`, `BootCount:%d, NextRecord:%d`,
`Updating BootCount MMC ...` — same record scheme. After `-c` runs, s_env is:
`11 08 11 20  00 00 00 00  11 08 11 20` (magic, count=0, checksum=magic).

**Our implementation (eMMC, so `mtd resetbc` cannot be used — it needs MTD):**
`target/linux/qualcommbe/ipq95xx/base-files/etc/init.d/bootcount` (START=99,
auto-enabled at build -> `/etc/rc.d/S99bootcount`). For `linksys,mbe7000` it
locates `s_env` via `find_mmc_part` (fallback: scan `/sys/class/block/*/uevent`
for `PARTNAME=s_env`), zeroes the first 4K, then writes the count=0 record
`printf '\021\010\021\040\000\000\000\000\021\010\021\040'` — byte-identical
to what `recovery_emmc -c` leaves. Reset point = END of boot (START=99),
matching both the vendor (CBT_system_ready S99) and OpenWrt convention
(qualcommax/ipq807x `bootcount`). No extra packages needed (dd/printf/logger/
find_mmc_part/board_name are all in base).

**Vendor SSH (QSDK 19.07, RSA only):**
`ssh -oHostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.1.1`,
password `9fBt6y73p@`. No sshpass on host -> use `SSH_ASKPASS`+`setsid -w`.

## Wi-Fi (ath12k / QCN9274) bring-up — IN PROGRESS 2026-07-15

Radios: 2x PCIe QCN9274 (pci17cb,1109; marketing "QCN6274"; QSDK calls it
"qcn9224"; ath12k drives as **qcn9274 hw2.0**) + a SoC internal 2.4G radio.
Only the **pcie2** endpoint (0002:01:00.0) enumerates so far; pcie1's endpoint
does not appear (separate issue, TODO). Driver/firmware/wpad all present;
blocker is the **board data file (BDF)**.

**The Xiaomi BE7000 PR (#20604, same IPQ95xx family) does NOT solve wifi - it
ships both radios `status="disabled"`.** No ipq-wifi/board-2.bin package there;
its nvmem-layout is only for the Aquantia PHY fw (`aqr_fw`). So this is an
unsolved frontier and we are pioneering it.

Vendor uses QSDK **bdwlan.bNN** BDFs (not mainline board-2.bin):
`qcn9224/bdwlan.b1006` (board_id 0x1006) = PCIe radios; `IPQ9574/bdwlan.b20` =
internal radio. Extracted from the vendor slot (mmcblk0p29, mounted RO) - saved
in scratchpad `bdf/`.

Progress (all via live SSH + cold-reboot tests; ath12k CANNOT warm-reload -
rmmod/modprobe -> "duplicate filename mhi0_IPCR" + QMI -11, needs cold boot):
1. Card reports **qmi-board-id=255 (0xff)** (OTP unprovisioned). Stock
   board-2.bin has no 0xff entry -> "failed to fetch board data ... -12".
2. Built board-2.bin wrapping vendor `bdwlan.b1006` as name
   `bus=pci,qmi-chip-id=0,qmi-board-id=255` using ath11k-bdencoder
   (github qca/qca-swiss-army-knife). -> lookup succeeded but "found invalid
   board magic".
3. **Magic fix:** ath12k wants `QCA-ATH12K-BOARD` (hw.h ATH12K_BOARD_MAGIC),
   bdencoder writes `QCA-ATH11K-BOARD`. Patched encoder -> `ath12k-bdencoder`
   in scratchpad (sed 11K->12K). Same length, clean.
4. **regdb is fatal** (qmi.c ath12k_qmi_event_load_bdf: regdb load err -> return).
   Added vendor `qcn9224/AH/regdb.bin` into the SAME board-2.bin as a regdb IE
   named by the board name. Current staged board-2.bin md5
   61b541678b1c4fe0ef3c8b6f74b4d4ba (magic OK + board + regdb).
   NOTE (2026-07-17): the "AH" in the path is just the regdb build/variant, NOT a
   region restriction — this regdb is a FULL ~206-country world DB (contains GB/US/
   DE/HK). It is not the cause of the 5 GHz DFS failure; see the re-diagnosed
   "5 GHz DFS / regulatory" section below.
Staged at /lib/firmware/ath12k/QCN9274/hw2.0/board-2.bin on the running unit
(overlay persists; original saved as board-2.bin.orig). NEXT: cold-reboot test.

**_23 boot (board-2.bin md5 61b54167):** board magic + regdb errors GONE.
ath12k now boots firmware and reaches WMI. New chain:
`qmi failed to load CAL data file:cal-pci-0002:01:00.0.bin` (NON-fatal, it
continued) -> `qmi dma allocation failed (29360128 B=28MB type 1)` ->
`memory type 10 not supported` -> WMI CONTROL connect -71 -> `failed to receive
wmi unified ready event:-110` -> `failed to start core:-110`.

**Root cause: no CMA.** `CONFIG_CMA` was unset (dmesg: `0K cma-reserved`).
The QCN9274 fw needs a ~28MB contiguous DMA chunk (dma_alloc_coherent,
qmi.c:2560); without CMA it fails, defers, and the deferred path can't handle
the segment ("memory type 10 not supported", qmi.c:2649) -> fw never inits ->
WMI -110. With CMA the 28MB allocates on the first pass and the deferred/type-10
path never runs, so CMA should fix the whole chain.
FIX (2026-07-15): added to config-6.18: CONFIG_CMA=y, CONFIG_CMA_SIZE_MBYTES=128,
CONFIG_CMA_SIZE_SEL_MBYTES=y, CONFIG_CMA_ALIGNMENT=8, CONFIG_CMA_AREAS=7,
CONFIG_DMA_CMA=y. Board has 1GB RAM; CMA is reusable so 128MB is safe. Full
kernel rebuild required (core mm option) - can't test live.
BUILD GOTCHA: turning on CONFIG_CMA exposes a kconfig CHOICE (CMA_SIZE_SEL_*)
and auto-selected symbols; the kernel's syncconfig under OpenWrt errors on an
incompletely-specified choice (`choice[1-4?]` / `(NEW)`) instead of defaulting,
and `yes '' | make` does NOT reach syncconfig under -j parallel. Fix: specify
the COMPLETE set in config-6.18 (get it from `make -C <kerneldir> olddefconfig`
then grep): CONFIG_CMA=y, CMA_ALIGNMENT=8, CMA_AREAS=8, CMA_SIZE_MBYTES=128,
CMA_SIZE_SEL_MBYTES=y + the other three SEL_* as "is not set", CMA_DEBUGFS/
CMA_SYSFS "is not set", CONFIG_DMA_CMA=y, DMA_NUMA_CMA "is not set",
CONFIG_CONTIG_ALLOC=y, CONFIG_MEMORY_ISOLATION=y. Built OK: image sha256
b7bfb30b3a673634467f69377ba81e7120e08de046bd3cd8e698d9fb82732037 (2026-07-15).

**Radio layout (tri-band BE11000, 3 radios):** 2.4G = IPQ9574 SoC-integrated
radio (wifi@c0000000, uses IPQ9574/bdwlan.b20) via ath12k AHB/platform + Q6
remoteproc + reserved-memory (NOT PCIe/CMA) - not wired up yet, later task.
5G + 6G = the two PCIe QCN9274 cards (CMA path, being solved now). Only one
PCIe endpoint (pcie2/0002:01:00.0) enumerates so far; pcie1 endpoint missing.

VENDOR DRIVER (vendor_boot.log): the vanilla fw uses NEITHER ath11k nor ath12k
- it's Qualcomm's proprietary **cnss2 + QSDK wlan driver** ("Loading cnss2",
"QCN9224_PCI2", MLO_MGR). It fully brings wifi up (start_ap ath00, Wi-Fi 7 MLO).
Same QCN9274 firmware branch as us (WLAN.WBE.1.6) - so ath12k drives identical
silicon/fw; mainline ath12k is the correct clean target (no vendor shortcut).
MEMORY MODEL: vendor uses reserved-memory **shared-dma-pool** regions
(dma_pool1@1/dma_pool2@2, 9 MiB each), NOT CMA (`0K cma-reserved`). Our CMA=128MB
is the standard mainline-ath12k-PCIe path (dma_alloc_coherent from default CMA);
if CMA fails, fallback = per-radio shared-dma-pool assigned via `memory-region`
on each pcie wifi node. Note ath12k asks 28MB vs vendor's 9MB pools.
CALDATA: vendor loads /lib/firmware/IPQ9574/caldata.bin (per-device, from 0:ART
= mmcblk0p20); cnss logs "No board_id in device tree" (=> board_id 0xff, matches
us). For ath12k this is cal-pci-0002:01:00.0.bin (currently non-fatal warning) -
extract from 0:ART after CMA gets a phy registered.

TEST NOTE: board-2.bin currently lives only in the running unit's OVERLAY
(/lib/firmware/... via cat), so flash the CMA image with a CONFIG-KEEPING
sysupgrade (not -n) or re-push board-2.bin over SSH after flashing. Once wifi
works, package board-2.bin as `ipq-wifi-linksys_mbe7000`. Anticipated remaining
hurdles: per-device caldata (cal-pci-*.bin from 0:ART, currently non-fatal);
pcie1 endpoint; the internal 2.4G radio. Tooling: scratchpad ath12k-bdencoder,
bdf/ (qcn9224-bdwlan.b1006, regdb.bin, board-2.bin).

## ▶ RESUME HERE (start of 2026-07-17 session)

CLEAN-FLASH TEST **PASSED** (2026-07-17): user flashed the permanent build to slot 2
from vendor and booted OpenWrt - **5 GHz Wi-Fi comes up on its own, no SSH push**.
Confirms board-2.bin is correctly baked into /rom and the ipq-wifi shared-package
chain works end to end. Device is now on **OpenWrt (slot 2)**.
DONE (prior session): 5 GHz wifi working + made permanent (ipq-wifi shared pkg, =y);
fw_env.config; bootcount reset; QCA8075 LAN; removed WAN debug.
6 GHz: SOLVED 2026-07-17 - DT-gated dual-MAC force (DTS `qcom,ath12k-force-dualmac`
+ mac80211 patch 705). Verified on HW: 5 GHz + 6 GHz (up to 320 MHz EHT/Wi-Fi 7)
both AP-ENABLED. See the "6 GHz - SOLVED" sub-section. Perm build sysupgrade
sha256 b849ece8c79f52fe8dfbbc0098a214be21cb770cae6e9914a0f2bbadf7f1f448 (09:27).
6 GHz PERM BUILD FLASHED + VERIFIED ON CLEAN FLASH 2026-07-17: DT-gated dualmac works
with NO diagnostic/hack - dmesg has no "forcing dualmac", DT prop present live, mac0+mac1
up, no MAC1 -71, phy0 Band2(5G)+Band4(6G), LAN 1G / WAN 2.5G. Build r35286+14-0cce5275b6.
MLO: WORKS 2026-07-17 (single-chip 5+6 GHz, ap-mld0 AP-ENABLED, stable, no crash) -
UCI-only config (list device radio0+radio1 + option mlo 1). See "MLO - WORKS" section.
NOTE: not baking MLO/6G into default config - left to user choice.
"Too many open files" on 6 GHz bring-up: INVESTIGATED 2026-07-17 = harmless misleading
errno (netdev name-collision, not fd exhaustion); 6 GHz works through it. Real 6G-down
cause was invalid default 6g channel '2' -> use a valid PSC channel. See the
"TOO MANY OPEN FILES" note. NOT a bug to fix locally.
### 2.4 GHz VENDOR GROUND TRUTH (live vendor firmware, 2026-07-17) [CORRECTED]
CORRECTION: the 2.4 GHz radio is NOT Wi-Fi 7/ath12k (earlier mislabel). It is a
Wi-Fi 6 PINE-class radio => ath11k territory. Evidence from vendor (QSDK OpenWrt 5.4.213):
- phy0 = /sys/devices/platform/soc/c000000.wifi, AHB/platform (NOT PCIe), on-die,
  boots on the SoC internal Q6: remoteproc0 cd00000.remoteproc (qcom-q6v5-wcss-pil),
  fw IPQ9574/q6_fw.mdt.
- WI-FI GENERATION = 6 (11ax), 2.4 GHz ONLY: phy0 Band1 = 2412-2462 (ch1-11), modes
  11b/g/n/ac/ax (NO 11be); HE caps present but EHT PHY caps ALL-ZERO. wlan log: "Num
  Radios = 1", 11ax=1, lo_2ghz=2312 hi_2ghz=2732 lo_5ghz=0.
- FIRMWARE BRANCH = WLAN.HK.2.9.r4 (Hawkeye) w/ QCAHKSWPL tag; VerInfo lists WLAN_PINE/
  PINE2/PINE3 => "Pine" = QCN50xx-family Wi-Fi 6 radio (exact QCNxxxx part not derivable
  from fw; class=Pine/Hawkeye). chip_family 0x4 (vs QCN9224 PCIe = WLAN.WBE, family 0xb).
- SoC reports "CPU: IPQ9554" (DT model says IPQ9574; same binned die - irrelevant).
- Vendor driver = downstream QSDK cnss2 + qca_ol/umac (handles ALL radios; not ath11k/
  ath12k). Firmware ALL extractable from vendor /lib/firmware/IPQ9574/: q6_fw.mdt+b00..b18,
  m3_fw.mdt+b00..b02, bdwlan.b10/.b20/.bin (BDF), caldata.bin, regdb.bin + regional dirs.
- Reserved-mem: m3_dump@4d600000, q6_caldb_region@4d800000, q6_etr_dump, mlo_global_mem_0.
- Mainline ipq9574.dtsi has NEITHER wifi node NOR cd00000 WCSS-Q6 remoteproc (only rpm
  remoteproc + wcss-phyb thermal). ath11k AHB of_match = ipq8074/ipq6018/ipq5018 (NO ipq95xx).
=> CORRECTED PORT SCOPE (ath11k, NOT ath12k; more tractable): (1) add IPQ95xx internal
Pine radio to ath11k + AHB of_match, TEMPLATED OFF IPQ8074 (same Hawkeye/Q6 pattern) -
the main work but a known shape, not reverse-engineering; (2) DTS wifi@c000000 + cd00000
q6v5-wcss remoteproc + reserved-mem + clocks; (3) package extracted IPQ9574/ firmware;
(4) kconfig: enable kmod-ath11k-ahb (coexists with ath12k) + ATH11K_AHB. VERDICT: a real
but more tractable ath11k port; still no upstream ipq95xx ath11k. Feasibility = medium
(was wrongly "big ath12k reverse-engineering").

2.4 GHz FEASIBILITY - SCOPED 2026-07-17: ath11k (Wi-Fi6 Pine) port, medium effort.

### 2.4 GHz ath11k SPIKE - 2026-07-17: VERDICT = GO (feasible backport, medium)
- ath11k AHB model MATCHES vendor: ath11k_core_get_rproc() reads DT `qcom,rproc` phandle
  -> rproc_boot() the external Q6 (qcom-q6v5-wcss). Vendor DT is exactly this (c000000.wifi
  + cd00000.remoteproc). So DTS is a known pattern (mirror ipq8074.dtsi wifi+q6).
- kmod-ath11k-ahb IS built in our mac80211 pkg (ath.mk: ATH11K_AHB, ath11k_ahb.ko) - enable it.
- ath11k SoC hw_params live in core.c (IPQ8074/6018/QCA6390/QCN9074/WCN6855); each SoC needs
  hw_ops+regs+ce_config+svc_to_ce+dir. THE unknown was the IPQ95xx reg maps.
- RESOLVED: a REFERENCE ath11k IPQ9574 patch EXISTS (kernel mailing list + OpenWrt community;
  Xiaomi BE7000 PR #20604, Spectrum SBE1V1K thread / andrewjlamarche, TP-Link BE800 #20373).
  Tested on IPQ9554 (our bin): AHB radio comes up + broadcasts SSID. KNOWN BUG: missing
  max_tx_ring -> kernel panic on 2.4G client connect (fix known/discussed on forum).
- Firmware extractable from vendor /lib/firmware/IPQ9574/ (q6_fw/m3 for remoteproc; bdwlan
  -> board-2.bin like we did for QCN9274; caldata.bin; regdb.bin).
### 2.4 GHz IMPLEMENTATION - recipe + progress (2026-07-17)
The internal radio is a QCN5024-class Wi-Fi 6 radio (mrnuke's patch confirms:
"IPQ9574 SoC coupled with Wi-Fi 6 chipsets like QCN5024 over AHB"). Two upstream
series to backport:

(A) ath11k IPQ9574 - mrnuke (Alexandru Gagniuc), linux-wireless v2 2-patch series:
  - patchwork 20260109044457.3074510-3 (2/2 driver), -2 (1/2 bindings).
  - DONE: package/kernel/mac80211/patches/ath11k/600-ath11k-support-ipq9574.patch
    (mrnuke 2/2 driver: ahb.c of_match+probe, core.c hw_params, core.h enum, hw.c
    ipq9574_ops, hw.h extern; reuses ipq8074 regs/ce, ipq6018 svc_to_ce; mac->PHY-B;
    bdf_addr 0x4B700000; max_radios 1). ADDED the max_tx_ring fix (mrnuke omitted
    .max_tx_ring -> 0 -> panic on 2.4G client connect; set = DP_TCL_NUM_RING_MAX).
    Verified applies clean to backports-6.18.26. (bindings 1/2 = Documentation only,
    optional.)

(B) Q6 WCSS SECURE PIL remoteproc - patchwork series 1041678 v10 (13 Jan 2026), 6 patches.
  Our kernel 6.18.38 has NEITHER the secure PIL driver NOR the ipq9574 q6 nodes
  (qcom_q6v5_wcss.c only does ipq8074/qcs404). NEED to backport 3 of the 6:
    1/6 firmware: qcom_scm ipq5332 (adds SCM calls) -> drivers/firmware/qcom/qcom_scm.{c,h}
    3/6 remoteproc: hexagon WCSS SECURE PIL -> NEW drivers/remoteproc/qcom_q6v5_wcss_sec.c
        (+ Kconfig/Makefile, include/linux/remoteproc.h)
    6/6 arm64: dts: ipq9574 q6 nodes -> ipq9574.dtsi (remoteproc@cd00000 + memory)
  SKIP 2/6 (bindings doc), 4/6 (ipq5018 dts), 5/6 (ipq5332 dts). RISK: series targets
  ~6.13; SCM + remoteproc.h core API may have drifted by 6.18 -> adaptation likely.
  Fetched to scratchpad/ipq9574-remoteproc-series.mbox (needs proper per-message split).

### 2.4 GHz IMPLEMENTATION - see dedicated doc
Full recipe, patch inventory, firmware/DTB extraction methods, the complete wifi@c000000
node (53 interrupts + addresses + board_id 0x20), memory map, remaining steps, and risks
are in **`MBE7000_ATH11K_24G_BACKPORT.md`** (repo root). WIP/uncommitted. Summary: it's an
ath11k (Wi-Fi 6 Pine/QCN5024) port = backport of mrnuke's ath11k IPQ9574 series (+max_tx_ring
fix) + the secure-PIL Q6 remoteproc series (patchwork 1041678). Patches already in tree
(600-ath11k-support-ipq9574 in mac80211; 0366/0367/0368 in patches-6.18) and apply clean to
6.18. Remaining: board DTS wifi node + reserved-mem, kconfig, firmware packaging, build/flash.
The MBE7000's 2.4 GHz is the IPQ9574 ON-DIE radio (wifi@c000000, qcom,cnss-qca9574, via
Q6). Mainline has ZERO support for it: ath12k AHB of_match = ONLY qcom,ipq5332-wifi
(+IPQ5424); ath11k AHB = ipq8074/6018/5018; NO ipq9574 hw_rev in ath12k hw.c; mainline
ipq9574.dtsi has NO wifi node (only wcss-phyb thermal). WHY: the RDP433 reference design
(what mainline IPQ9574 ath12k was built against) uses 3x EXTERNAL QCN9274 on PCIe for all
bands - nobody upstream needed the on-die radio. No in-flight patch series found. Our lone
QCN9274 is committed to 5+6 GHz and its RF frontend can't do 2.4 (separate integrated RF
path), so no shortcut. Enabling = add a NEW ath12k IPQ9574 integrated-radio hw_rev (HAL,
reg maps, CE cfg, ring masks, hw_params) + ath12k_ahb kmod + Q6 remoteproc (userpd) + DTS
wifi node + reserved-mem + m3/BDF fw - realistically ported from vendor QSDK ath12k. Multi-
week, uncertain. RECOMMENDATION: defer; ship as a 5+6 GHz Wi-Fi 7 router. Revisit if
upstream adds IPQ9574 on-die support or if a QSDK backport path proves clean.
NEXT: (1) the ENFILE "too many open files" blip on 6 GHz iface bring-up; (2) decide
default shipping wireless config (single APs vs MLO); (3) 2.4G integrated radio
(separate, larger AHB/Q6 effort - ath12k_ahb isn't even built in our mac80211 pkg,
PCI-only).
CLEANUP PENDING: strip dormant qca8084 driver patches (0301-0312, 0362, 0363);
remove wifi1@pcie1 from DTS (harmless failed probe). Fold any remaining build_dir
edits into patches + full clean-build verify.

## Wi-Fi RESULT + radio architecture — 2026-07-16 [5GHz WORKING]

**5 GHz radio WORKS on hardware** (phone associated, WPA2 EHT80 AP, good perf).
The combo that cracked it: CMA(128MB) + our board-2.bin(61b54167, board-id 255
+ regdb, ATH12K magic). Residual dmesg (`memory type 10`, `WMI MAC1 -71`,
`cal-pci-*.bin -12`) are all NON-fatal - phy0 registers (5 GHz, EHT80/Wi-Fi 7).

**Made permanent (in the SHARED ipq-wifi package - the standard way):**
- `package/firmware/ipq-wifi/files/board-linksys_mbe7000.QCN9274` = our board-2.bin.
- Added `linksys_mbe7000` to ALLWIFIBOARDS + `generate-ipq-wifi-package` call.
- Added a `Build/Prepare` hook to ipq-wifi/Makefile that copies local
  `./files/board-*` into PKG_BUILD_DIR (the upstream git-src prepare doesn't),
  so the install-overlay wildcard finds it.
- image/ipq95xx.mk DEVICE_PACKAGES: `ipq-wifi-linksys_mbe7000`.
- .config: removed the STALE `ipq-wifi-8devices_kiwi=y` (kiwi device isn't even
  selected - it was baking kiwi's board data into the shared base rootfs), and
  set **`CONFIG_PACKAGE_ipq-wifi-linksys_mbe7000=y`**.

KEY GOTCHA that cost several rebuilds: `install-overlay` DOES flatten into the
rootfs, but only for **`=y`** packages. As `=m` it is built but never applied.
Confirmed: with our pkg `=y`, the image squashfs board-2.bin = OUR 61b54167 (was
the generic da60c3cd / kiwi's e8a1bc39). Regenerate the board file with scratchpad
ath12k-bdencoder if the BDF changes. (Upstreaming: also send the board file to
github.com/openwrt/firmware_qca-wireless.)

**Radio architecture (from vendor_boot.log - definitive):** this unit brings up
only TWO radios: (1) `cd00000.remoteproc` = IPQ9574 **integrated 2.4 GHz** (Q6/
WCSS, chip_family 0x4, "2G=13 5G=0 6G=0") - separate AHB/remoteproc task, not
done; (2) **one QCN9274 on pcie2** (0x20000000, chip_family 0xb, "QCN9224_PCI2")
= our working 5 GHz. phy0 is 5 GHz-only (no 6 GHz frequencies).

**6 GHz = 2nd MAC of the SAME QCN9274, needs DUAL-MAC firmware (NOT a pcie fix).**
Live vendor check (2026-07-16) settled it: the vendor brings up 4 phys - phy0
(2.4G, integrated c000000.wifi), phy2 (5G) and phy3 (6G, 320MHz Wi-Fi 7) which
**both readlink to the SAME PCI device 0003:01:00.0 on pcie2**, plus mld-phy0
(MLO 5G+6G). So the ONE QCN9274 runs 5G AND 6G concurrently as two MACs. pcie1
STILL fails to link in the vendor (`Phy link never came up`) yet 6G works - so
pcie1 is genuinely unused; do NOT chase it (our DTS wifi1@pcie1 probe just fails
harmlessly - can remove later).
The vendor achieves dual-radio by booting a special firmware:
`remoteproc: Booting fw image qcn9224/amss_dualmac.bin (7557120 bytes)` - it ships
both `amss.bin` (single-MAC) and `amss_dualmac.bin`. Our ath12k loads the
single-MAC firmware-2.bin, so only 1 radio (5G) comes up and the 2nd fails
(`WMI MAC1 connect request failed -71`). Vendor qcn9224 fw dir also has:
caldata_{1..4}.bin (184320 B each, per-chain), m3.bin, fw_ini_cfg.bin,
rxgainlutSKY_6G.bin, regdb.bin, bdwlan.b1006.
**6 GHz path — RE-SCOPED 2026-07-17: it's a FIRMWARE problem, NOT a driver port.**
Verified against our actual driver source (mac80211 backports-6.18.26, the ath12k
we ship). The full single-chip QCN9274 dual-MAC + MLO stack is ALREADY PRESENT:
  - `mhi.c ath12k_mhi_register()`: reads the chip's OTP board_id from HW register
    `QCN9274_QFPROM_RAW_RFA_PDET_ROW13_LSB`; if bit `OTP_VALID_DUALMAC_BOARD_ID_MASK`
    (0x1000) is set it selects the dual-MAC image FROM `ab->fw.amss_dualmac_data`,
    i.e. an `ATH12K_FW_IE_AMSS_DUALMAC_IMAGE` (IE id 4) packed inside firmware-N.bin.
    If that IE is absent it hard-fails: `-ENOENT "dualmac firmware IE not present"`.
    -> dual-MAC-ness is in the CHIP OTP (HW; vendor runs it dual-mac so bit is set);
       the SW gate is whether firmware-2.bin carries the AMSS_DUALMAC IE.
  - `core.c ath12k_core_hw_group_set_mlo_capable()`: for our single device
    (num_devices==1, QCN9274 fw_features_valid) sets
    `mlo_capable = ath12k_fw_feature_supported(ab, ATH12K_FW_FEATURE_MLO)` — i.e.
    MLO is enabled IFF firmware-2.bin's `ATH12K_FW_IE_FEATURES` advertises
    FW_FEATURE_MLO. Driver defers to the fw flag on purpose.
  - Both upstream MLO series are IN our tree: `ath12k_mac_op_can_activate_links`
    (Dec-2024 "part 9/9", introduces FW_FEATURE_MLO) and `ath12k_get_num_partner_link`
    (Feb-2025 single split-phy PCI MLO setup/ready/teardown, drops the num_devices==1
    guard). Refs: lists.infradead.org/pipermail/ath12k/2024-December/004675.html,
    .../2025-February/005742.html.
The 2024 "dualmac fw crashes on same-chip MLO" caveat = the FIRMWARE of that era;
vendor QSDK ships newer fw that sets FW_FEATURE_MLO (why vendor MLO works).

### LIVE PROBE 2026-07-17 — ROOT CAUSE FOUND: OTP dualmac gate, not firmware
Probed the running board (OpenWrt slot 2, 5 GHz up). Findings:
  - Installed stock linux-firmware `QCN9274/hw2.0/firmware-2.bin` (build WLAN.WBE.1.6-
    01243, 2025-12-09) ALREADY CONTAINS everything. Parsed its IE table:
    TIMESTAMP, M3_IMAGE(421880), AMSS_IMAGE(7761920), **AMSS_DUALMAC_IMAGE(7852032)**,
    **FEATURES len=1 with bits {0:MULTI_QRTR_ID, 1:MLO} BOTH SET**. So fw is NOT the
    blocker; neither is the driver (full dual-MAC+MLO stack confirmed in backports-6.18.26).
  - Yet only ONE MAC boots: `ls /sys/class/ieee80211` = phy0 only; debugfs has mac0
    only; `iw phy0 info` shows Band 2 (5 GHz) only, NO 6 GHz. dmesg (every cold boot):
    `HTC Service WMI MAC1 connect request failed -71` / `failed to connect to WMI
    CONTROL service -71` / `Invalid module id 2`. qcn9274 hw2.0 hw_params has
    max_radios=2, single_pdev_only=false, so the driver TRIES MAC1 but the firmware
    only exposed 1 MAC => the SINGLE-mac amss.bin was downloaded, not amss_dualmac.
  - WHY single-mac: `mhi.c ath12k_mhi_register()` only picks amss_dualmac if the chip's
    OTP board_id (HW reg QCN9274_QFPROM_RAW_RFA_PDET_ROW13_LSB = 0x1E20338, mask
    0xFFFF) has bit OTP_VALID_DUALMAC_BOARD_ID_MASK (0x1000). This board's OTP evidently
    does NOT set that bit -> driver loads single-mac. The vendor QSDK cnss driver selects
    amss_dualmac by its own board/DT config, NOT this OTP bit, so vendor runs dual-mac on
    the SAME silicon while mainline defaults to single. (mhi_register runs only at PCI
    probe, pci.c:1677 - NOT on recovery - so simulate_fw_crash won't re-select; a reboot
    or PCI remove+rescan is needed to re-read OTP. NOT YET confirmed the OTP value with
    debug - debug IS compiled in (debug_mask param + simulate_fw_crash exist); BOOT|QMI
    = 0x60, but need it set at PROBE time. Two forced crashes rebooted the device; it
    auto-recovered fine, 5G back, still slot 2.)

### 6 GHz — SOLVED 2026-07-17 (DT-gated dual-MAC force) [VERIFIED ON HW]
A TEST build (unconditional `dualmac = true` + an always-on ath12k_info of the OTP
board_id) proved it live: dmesg printed `OTP board_id=0x0 dualmac_bit=0` (so mainline
would NEVER pick dual-MAC on its own - the OTP gate is genuinely the blocker), the
`WMI MAC1 -71` error vanished, debugfs gained `mac1`, and `iw phy0` gained a 6 GHz
Band 4 (60 chans, 320 MHz / EHT). Brought up test APs: phy0.0-ap0 (5 GHz ch36) AND
phy0.1-ap0 (6 GHz ch5, then ch37 @ **320 MHz EHT** = full Wi-Fi 7) both AP-ENABLED.
6 GHz needs a reg country (hostapd errors on country '00'); set `country` on the radio.
Note: mainline presents ONE wiphy (phy0) spanning 5+6 GHz backed by 2 MACs
(mac0/mac1); OpenWrt auto-generates radio0(5g)+radio1(6g), both on the same phy path.

PERMANENT FIX (shipped): DTS property `qcom,ath12k-force-dualmac;` on the wifi node
(`wifi2: pcie@0` under &pcie2) + mac80211 patch
`patches/ath12k/705-ath12k-force-dualmac-from-dt.patch`: in `ath12k_mhi_register`,
`if (of_property_read_bool(ab->dev->of_node, "qcom,ath12k-force-dualmac")) dualmac = true;`
(after the OTP block; NULL-safe so other QCN9274 cards unaffected; needs
`#include <linux/of.h>`). No firmware/board-2.bin change (stock firmware-2.bin already
has the AMSS_DUALMAC IE + FW_FEATURE_MLO). Verified: DTB carries the prop, rebuilt
mhi.c has the DT gate, diagnostic removed.

"TOO MANY OPEN FILES" - INVESTIGATED 2026-07-17, it is HARMLESS (not fd exhaustion):
`hostapd: Failed to create interface phy0.1-ap0: -23 (Too many open files in system)`
is a MISLEADING errno. Traced to kernel net/core/dev.c dev_prep_valid_name(): when a
netdev name is already in use it returns `-dup_errno` and dev_alloc_name() passes ENFILE
(=-23) as that code. So -23 here means "netdev name phy0.1-ap0 already in use", NOT open
files. It's a create-before-teardown name collision during hostapd's multi-radio
"Restart interface" retry on the 6 GHz radio. NON-FATAL: measured peak file-nr 304/87074
(hostapd had 4 fds), and 6 GHz reaches AP-ENABLED anyway (3/3 bring-ups with a valid
channel). Root fix would be in hostapd/netifd multi-radio-wiphy iface restart ordering
(upstream, fast-moving) - not worth patching locally; it's cosmetic log noise.
SEPARATE real gotcha: the AUTO-GENERATED default 6g radio uses `channel '2'`, which is
NOT a valid 6 GHz channel -> hostapd drives phy0.1-ap0 to AP-DISABLED. Fix = set a valid
6 GHz channel (PSC e.g. 37/53/...); then 6 GHz is reliably AP-ENABLED. (Also OpenWrt
default-config roughness, not our port.)

### MLO — WORKS 2026-07-17 (single-chip QCN9274, stock fw) [VERIFIED ON HW]
Single-chip 5+6 GHz MLO comes up and is STABLE - the 2024 "same-chip dualmac MLO
crashes" caveat does NOT apply to this firmware (WLAN.WBE.1.6-01243). No ath12k
assert/crash. `ap-mld0: AP-ENABLED`, one MLD with 2 links: link0 5 GHz ch36 (80 MHz),
link1 6 GHz ch37 (320 MHz EHT). MLO is NOT a LuCI option (no UI in any release yet) -
it is UCI-only. hostapd is v2.12-devel with MLD/MLO built in; netifd has the plumbing
(`parse_bool(config.mlo)`, `mld_start`/`mld_set`, `ap-mld<N>` ifaces).
LEGACY COMPAT CONFIRMED: with ONE SSID/key across both links + option mlo 1, a non-MLO
Wi-Fi 6E client (iPhone 15 Pro) associated on the 6 GHz affiliated link at 160 MHz
HE-MCS10 NSS2 (~2.16 Gbps, -43 dBm, freq 6135/ch37). So the proper MLO setup (single
SSID) serves BOTH Wi-Fi 7 (multi-link) and legacy single-link clients incl. 6E-on-6GHz.
(Earlier note that a 6E client can't use the MLD 6 GHz link was WRONG - it can; which
link a legacy client picks is the client's choice.) Standalone per-band APs are only
needed if you want to pin a client to a specific band.
Config model (this build uses the multi-radio-wiphy layout: radio0=5g & radio1=6g share
one phy `path`, differ by `option radio 0/1`). An MLO AP is ONE wifi-iface spanning
both radios:
  config wifi-iface 'mlo0'
      list device 'radio0'     # 5 GHz link
      list device 'radio1'     # 6 GHz link
      option mlo '1'
      option mode 'ap'
      option ssid '...'; option encryption 'sae'; option key '...'; option network 'lan'
(and disable the standalone default_radio0/1 APs so their links are free). Live test
config backed up on device at /etc/config/wireless.pre-mlo.

**Caldata = non-issue for the PCIe radio:** `0:ART` (mmcblk0p20) is all 0xff
(empty); the QCN9274 self-calibrates from board-2.bin + its own OTP (why 5 GHz
already works). ART/caldata only matters for the integrated 2.4 GHz radio later.

## A/B partition switching (BOOTCONFIG) — 2026-07-15

To switch which slot boots WITHOUT power-cycling: `fw_setenv boot_part` does
NOT work - U-Boot re-derives boot_part from the QCA **BOOTCONFIG** partition
each boot ("Sync BOOTCONFIG to boot_part" in the log) and overwrites it. The
authoritative selector is the **primaryboot flag** in `0:BOOTCONFIG`
(/dev/mmcblk0p3) and its mirror `0:BOOTCONFIG1` (p4).

BOOTCONFIG format: header `magic=0xa3a2a1a0, ver=41, numparts=8` (12 bytes),
then 8 entries of `{char name[16]; u32 primaryboot}` (20 bytes each).
primaryboot=0 -> boot base copy (slot 1); =1 -> boot the `_1` copy (slot 2).
The bootloader partitions (DEVCFG/APDP/RPM/CDT/APPSBL) are pinned to slot 1
(primaryboot=0, shared); only the **OS trio HLOS/rootfs/WIFIFW** flips per slot.
Flag byte offsets: HLOS=0x80(128), rootfs=0x94(148), WIFIFW=0xa8(168).

Slot map: slot 1 = 0:HLOS/rootfs/0:WIFIFW (p28/p29/p26) = VENDOR (QSDK 19.07);
slot 2 = the `_1` copies (p30/p31/p27) = OpenWrt.

Switch to VENDOR (slot 1):
```sh
for P in 3 4; do for OFF in 128 148 168; do
  printf '\x00' | dd of=/dev/mmcblk0p$P bs=1 seek=$OFF count=1 conv=notrunc 2>/dev/null
done; done; sync
```
Switch to OPENWRT (slot 2): same with `printf '\x01'`. Verify with
`dd if=/dev/mmcblk0pP bs=1 skip=OFF count=1 | hexdump`. (Flashing OpenWrt from
the vendor OTA to the inactive slot also flips BOOTCONFIG to slot 2 by itself.)

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

## 5 GHz DFS / regulatory (ath12k) — RE-DIAGNOSED 2026-07-17 [NOT FIXED, parked]
Symptom: with a country set, 5 GHz "auto channel" picks a DFS channel (e.g. ch144/freq
5720) and the AP won't start:
  ath12k_pci ...: vdev start resp error status 4 (invalid regdomain)
  ath12k_pci ...: failed to start vdev 0 addr ...:0a on freq 5720: -22
`iw reg get` shows `phy#1 (self-managed) country US` no matter what country you set;
setting GB/DE/HK/US makes NO difference (verified live: US also fails identically).

### CORRECTION — the old "APAC-locked / stub regdb" theory is WRONG (disproven 2026-07-17)
The previous version of this note blamed a "stub/APAC-only regdb with no GB/EU". That is
FALSE. Facts, all verified this session:
- Our shipped board-2.bin's embedded regdb (ATH12K_BD_IE_REGDB) is a **valid full world DB**:
  25656 B, ~206 country codes, and it **DOES contain GB, US, DE, HK** (checked by parsing
  the IE and searching for the alpha2 codes). It is ~identical to the QSDK
  WLAN.WBE.1.0-03208 regdb.bin (only 445/25656 bytes differ).
- linux-firmware's own QCN9274 board-2.bin carries a *different* regdb (25656 B, differs
  from ours in 1732/25656 bytes) — but same size, same structure, same country table
  layout. The variants differ only in **rule VALUES**, never in **wire format**.
- The per-region vendor files `qcn9224/{AH,AU,HK,SG}/regdb.bin` were a RED HERRING: they are
  not what feeds ath12k's board-2.bin regdb IE, and "no GB in them" told us nothing.

### What is actually wrong (real root cause)
The failure is a **WMI regulatory EVENT parse failure**, not missing regdb DATA. At boot:
  ath12k_pci ...: failed to parse tlv -22            (ath12k_wmi_tlv_parse -> -EINVAL)
  ath12k_pci ...: failed to extract regulatory info from received event   (WARN wmi.c:6806,
                  in ath12k_pull_reg_chan_list_ext_update_ev)
The chip's firmware SENDS a REG_CHAN_LIST_CC_EXT event whose TLV layout mainline ath12k
6.18 cannot decode -> reg_info is dropped -> zero rules ever installed -> the self-managed
phy stays on its built-in US fallback -> any *set* country times out
("Timeout while waiting for regulatory update") -> DFS vdev start is rejected with
"invalid regdomain". Non-DFS channels don't need a firmware regdomain, so they start fine.
Because it is an event **structure** mismatch, swapping the regdb (from linux-fw / QSDK /
vendor HK) CANNOT fix it — every regdb variant is structurally identical; only values change.

### Why: it tracks to our FORCED DUAL-MAC config, not the firmware provenance
- `firmware-2.bin` on the device is byte-identical (md5 42e29e40...) to **upstream
  linux-firmware `WLAN.WBE.1.6-01243`** — i.e. the mainline-blessed firmware, NOT a vendor
  blob. Upstream firmware + mainline ath12k are supposed to be a matched pair.
- The one non-standard thing we do is force the single QCN6274 into **dual-MAC** (5+6 GHz on
  one chip) via `qcom,ath12k-force-dualmac` + the ath12k patch. In dual-MAC the firmware
  emits **per-phy** reg events; the leading hypothesis is that this forced mode is what
  produces the reg-event layout mainline's parser rejects.
- Corroboration (OpenWrt PR #20373, TP-Link BE800, working ath12k Wi-Fi): it uses the SAME
  mainline ath12k + same WLAN.WBE firmware family and regulatory JUST WORKS — because it runs
  every radio **single-MAC** (dedicated chip per band) and does zero special reg handling.
  Nobody upstream forces single-chip dual-MAC, so nobody has solved its reg-event parse.
  (PR #20778 Archer BE550 = same radios as us but Wi-Fi non-functional; no reg content.)

### Next diagnostic (isolation test, when revisited)
Temporarily DROP `qcom,ath12k-force-dualmac` (single-MAC, 5 GHz only), rebuild, reboot:
- if the `parse tlv -22` / reg failure disappears and DFS/auto works -> CONFIRMED it's the
  dual-MAC hack; real fix = a mainline ath12k patch to parse the dual-MAC reg event (or accept
  the trade-off: 6 GHz **xor** DFS/upper-5 GHz).
- if it still fails single-MAC -> it's a plain mainline-ath12k-vs-WBE1.6 reg-event gap.

### Cleaner board-data mechanism (maintainability, does NOT fix DFS)
PR #20373 reads `qcom,board_id` from DT via patch `300-wifi-ath12k-board_id-from-device-tree`
instead of hand-building a board-2.bin keyed to the default board-id 255 (our approach).
Worth adopting when we upstream, but it is orthogonal to the regulatory bug.

### IMMEDIATE WORKAROUND (no rebuild, region-independent, verified)
Pin 5 GHz to a non-DFS channel <=80 MHz (ch 36/40/44/48, htmode EHT80): comes up without
CAC regardless of the reg-event bug. Verified live: ch36/EHT80 -> AP up, txpower a sane
25 dBm (vs the bogus 63 dBm seen on the failing DFS path). Best default for a generic image.
Cost: loses upper-5 GHz (ch100-144) + DFS.
