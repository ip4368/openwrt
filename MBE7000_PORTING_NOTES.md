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
  `kmod-ath12k ath12k-firmware-qcn9274`).
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
string mainline ath12k requests for these radios - and that is only
readable from the device itself (`dmesg`: "failed to fetch board data for
bus=pci,qmi-board-id=..."). So a correct `ipq-wifi-linksys_mbe7000` package
cannot be built blind; the raw BDFs are preserved in
`/home/daniel/mbe7000_wrt_extract/` for that conversion once hardware is
available. There is also an optimistic path: since this is a stock
AP-AL02-C4 reference design, the reference `board-2.bin` already shipped in
`ath12k-firmware-qcn9274` may contain a matching board-id and Just Work -
to be checked on hardware.

## Known gaps / things NOT verified against real hardware

- **WAN PHY chip identity.** `phy4` in the DTS uses a generic
  `"ethernet-phy-ieee802.3-c45"` compatible as a placeholder (same pattern
  `qcom_rdp433` uses for its own discrete PHYs) at mdio address `0x1c`.
  The actual chip (likely an Aquantia/Marvell AQR-class multi-gig PHY,
  going by the `qcom_rdp433` precedent) is unconfirmed - if it needs
  firmware via `nvmem-cells` (like `rdp433`'s `aqr_fw`), that's not wired
  up here at all. **Check the boot log once serial console works** - the
  phy driver probe should identify the chip.
- **LEDs**: none defined. If they're not actually driven by the K32W061,
  they may need discovering via GPIO sysfs poking or vendor firmware
  boot log/gpio dump.
- **pcie3** (3rd external radio slot): left disabled, matching the vendor
  firmware's own choice on the 1.0.10 build. Unknown whether later
  firmware (up to 1.0.14, the latest GPL release seen) enables it, i.e.
  whether the board actually has a 3rd radio chip populated.
- **eMMC partition names** for sysupgrade (`platform.sh`,
  `CI_KERNPART="0:HLOS"` / `CI_ROOTPART="rootfs"`) are copied from
  `8devices,kiwi-dvk` verbatim, not confirmed against Linksys's actual GPT
  partition table. Don't trust `sysupgrade`/factory flashing until this is
  checked (e.g. `cat /proc/partitions` + partition names once initramfs
  boots).
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
