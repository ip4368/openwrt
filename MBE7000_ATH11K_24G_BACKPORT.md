# MBE7000 2.4 GHz (ath11k / IPQ95xx on-die radio) — Backport Working Doc

Self-contained working notes for enabling the **2.4 GHz radio** on the Linksys
MBE7000 (Velop Pro 7). This is a big, multi-part backport; keep this doc as the
single source of truth for it. High-level status also mirrored in
`MBE7000_PORTING_NOTES.md` (which points here).

Status: **WIP, uncommitted.** Kernel + driver patches are in the tree and apply
clean to our kernel 6.18.38 / mac80211 backports-6.18.26. Not yet built/booted.

---

## 1. What the 2.4 GHz radio actually is (verified from vendor firmware)

- It is the **SoC on-die radio** at `c000000.wifi` (AHB, **not** PCIe), compatible
  `qcom,cnss-qca9574` + `qcom,ipq9574-wifi`. Boots on the SoC internal **Q6/QDSP6**
  remoteproc `cd00000.remoteproc`.
- It is a **Wi-Fi 6 (802.11ax) Pine-class radio** — mrnuke's patch describes it as
  "IPQ9574 coupled with Wi-Fi 6 chipsets like **QCN5024** over AHB". Firmware branch
  `WLAN.HK.2.9` (Hawkeye), VerInfo lists `WLAN_PINE`. phy0 Band 1 = 2412-2462 (ch1-11),
  11b/g/n/ac/ax, HE caps, EHT PHY caps = 0 (so NOT Wi-Fi 7).  chip_family 0x4.
- => mainline driver family is **ath11k**, NOT ath12k. (The QCN9274 PCIe radio doing
  5+6 GHz is ath12k/`WLAN.WBE`, chip_family 0xb — already working, unrelated.)
- SoC reports `CPU: IPQ9554` (DT model says IPQ9574; same binned die — irrelevant).
- Vendor stack = downstream QSDK `cnss2` + `qca_ol`/`umac` (no ath11k/ath12k). So no
  ath11k reference in the vendor image — the reference is the upstream patches below.

---

## 2. The two upstream series we backport (no reverse-engineering)

### A) ath11k IPQ9574 driver — mrnuke (Alexandru Gagniuc), linux-wireless v2, 2 patches
- 2/2 driver: patchwork `20260109044457.3074510-3-mr.nuke.me@gmail.com`
- 1/2 bindings (Documentation only, optional): `...-2-...`
- Adds `ATH11K_HW_IPQ9574`: ahb.c of_match+probe, core.c hw_params, core.h enum,
  hw.c `ipq9574_ops`, hw.h extern. Reuses `ipq8074_regs`/`ipq8074` CE + `ipq6018`
  svc_to_ce; custom `mac_from_pdev_id` -> returns 2 (PHY B / mac3). `max_radios=1`,
  `bdf_addr=0x4B700000`, `fixed_bdf_addr`/`fixed_mem_region=true`, coldboot cal off.
- **max_tx_ring BUG**: mrnuke's entry omits `.max_tx_ring` (a direct `ath11k_hw_params`
  field in our tree) -> defaults 0 -> **kernel panic on 2.4G client connect** (reported
  on OpenWrt forum for IPQ9554 boards). FIX: `.max_tx_ring = DP_TCL_NUM_RING_MAX,`.

### B) Q6 WCSS **secure PIL** remoteproc — patchwork **series 1041678** v10 (13 Jan 2026), 6 patches
Our kernel 6.18.38 has NEITHER the secure-PIL driver NOR ipq9574 q6 nodes
(`qcom_q6v5_wcss.c` only does ipq8074/qcs404). We need 3 of the 6:
- 1/6 `firmware: qcom_scm: ipq5332 ...` -> `drivers/firmware/qcom/qcom_scm.{c,h}`
- 3/6 `remoteproc: qcom: hexagon WCSS secure PIL` -> **new** `drivers/remoteproc/
  qcom_q6v5_wcss_sec.c` + Kconfig/Makefile + `include/linux/remoteproc.h`
- 6/6 `arm64: dts: ipq9574: bring up q6` -> `ipq9574.dtsi`
Skip 2/6 (bindings doc), 4/6 (ipq5018 dts), 5/6 (ipq5332 dts).
NOTE: upstream uses the **secure** PIL compatible `qcom,ipq9574-wcss-sec-pil`; the
vendor DT uses downstream `qcom,ipq9574-wcss-pil`. Use the upstream 0367+0368 pair.

---

## 3. Patch inventory (in the tree now)

- `package/kernel/mac80211/patches/ath11k/600-ath11k-support-ipq9574.patch`
  (mrnuke 2/2 driver + max_tx_ring fix). Applies clean to backports-6.18.26.
- `target/linux/qualcommbe/patches-6.18/0366-firmware-qcom_scm-ipq5332-secure-pil-support.patch`
- `.../0367-remoteproc-qcom-hexagon-wcss-secure-pil.patch`
- `.../0368-arm64-dts-ipq9574-bring-up-q6.patch`
  (0366/0367/0368 apply clean to kernel 6.18.38; the dtsi hunk needs only line offsets.)
Regenerated any time from: mrnuke patchwork mbox + `patchwork.kernel.org/series/1041678/mbox/`
split with `git mailsplit`.

---

## 4. Firmware — extract WITHOUT booting vendor

Mount the vendor rootfs read-only from OpenWrt and pull the firmware tarball:
```sh
# on OpenWrt (slot 2):
mount -o ro /dev/mmcblk0p29 /mnt/vroot        # 0:rootfs (vendor)
# firmware lives in a tgz, extracted at boot by a vendor init script:
#   /mnt/vroot/lib/firmware/IPQ9574/spf12.2_CSU2_WIFI_FW.tgz  ->  WIFI_FW/
```
Contents (WIFI_FW/): `q6_fw.mdt` + `q6_fw.b00..b18`, `m3_fw.mdt` + `m3_fw.b00..b02`,
`bdwlan.bin`/`.b10`/`.b20`, `caldata.bin`, `regdb.bin`, `VerInfo.txt`, ini files.

Packaging targets (per 0368 DT `firmware-name`): `ath11k/IPQ9574/hw1.0/`:
- **board-2.bin**: build from `bdwlan.bin` with `ath11k-bdencoder` (ATH11K magic —
  i.e. the UNPATCHED encoder; we patched a copy to ATH12K magic for QCN9274, do NOT
  reuse that one). Board keyed to `board_id=0x20` (from the vendor wifi node).
- **q6_fw / m3_fw**: DT wants `q6_fw.mbn` (combined) but vendor ships `.mdt`+`.bNN`
  (split). RESOLVE: either concatenate per the mdt into a `.mbn`, or make the secure-PIL
  loader use `qcom_mdt_load` on the `.mdt`. TBD during build.
- **caldata.bin**, **regdb.bin**: copy as-is.

---

## 5. Vendor DTB — extract WITHOUT booting vendor

```sh
# on OpenWrt: HLOS FIT is on p28, board DTB is the 2nd d00dfeed inside the FIT
dd if=/dev/mmcblk0p28 bs=1M count=4 > /tmp/hlos.itb   # magic d00dfeed@0
# on host: 2nd d00dfeed ~offset 3503388, ~83660 bytes -> decompile w/ kernel scripts/dtc/dtc
```
Model: "Qualcomm Technologies, Inc. IPQ9574/AP-AL02-C4".

---

## 6. The `wifi@c000000` node (the piece NOT provided by any patch)

0368 adds the Q6 remoteproc + `q6_region` + smp2p, but **not** the wifi node. Build a
mainline ath11k-style node under `&soc` (`soc: soc@0`) in the board DTS. Key values from
the vendor DTB:

```
compatible = "qcom,ipq9574-wifi";
reg = <0x0c000000 0x1000000>;
qcom,rproc = <&q6v5_wcss>;
board_id = <0x20>;             /* selects board-2.bin entry */
/* bdf-addr base 0x4b700000; caldb 0x4d800000 size 0x500000 */
memory-region = <...>;         /* UNCERTAIN - see risks */
status = "okay";
```

**53 interrupts**, all `<GIC_SPI N IRQ_TYPE_EDGE_RISING>` (vendor raw `<0x00 N 0x01>`).
SPI numbers (hex), in order:
```
140 13f 13e 13c 13b 13a 137 136 19b 19a 28 27 12e 12d 25 24 128 127 126 125 124 123
122 121 120 ef ec eb ea e9 e8 e7 e6 e5 e4 e0 df cb b7 b4 b3 b2 b1 b0 a3 a2 a0 19e 9f
9e 9d 9c
```
interrupt-names (same order):
```
misc-pulse1 misc-latch sw-exception ce0 ce1 ce2 ce3 ce4 ce5 ce6 ce7 ce8 ce9 ce10 ce11
host2wbm-desc-feed host2reo-re-injection host2reo-command host2rxdma-monitor-ring3
host2rxdma-monitor-ring2 host2rxdma-monitor-ring1 reo2ost-exception wbm2host-rx-release
reo2host-status reo2host-destination-ring4 reo2host-destination-ring3
reo2host-destination-ring2 reo2host-destination-ring1 rxdma2host-monitor-destination-mac3
rxdma2host-monitor-destination-mac2 rxdma2host-monitor-destination-mac1
ppdu-end-interrupts-mac3 ppdu-end-interrupts-mac2 ppdu-end-interrupts-mac1
rxdma2host-monitor-status-ring-mac3 rxdma2host-monitor-status-ring-mac2
rxdma2host-monitor-status-ring-mac1 host2rxdma-host-buf-ring-mac3
host2rxdma-host-buf-ring-mac2 host2rxdma-host-buf-ring-mac1 rxdma2host-destination-ring-mac3
rxdma2host-destination-ring-mac2 rxdma2host-destination-ring-mac1 host2tcl-input-ring4
host2tcl-input-ring3 host2tcl-input-ring2 host2tcl-input-ring1 wbm2host-tx-completions-ring4
wbm2host-tx-completions-ring3 wbm2host-tx-completions-ring2 wbm2host-tx-completions-ring1
tcl2host-status-ring
```

Memory map: `q6_region` 0x4ab00000/0x2b00000 (from 0368); `m3_dump`@0x4d600000;
`caldb`@0x4d800000/0x500000.

**memory-region wiring (RESOLVED via ath11k binding + driver):** the ath11k AHB driver
(`ath11k_ahb_setup_msa_resources`) reads exactly **2** reserved regions from the wifi
node via `of_reserved_mem_region_to_resource(node, 0/1)`:
`memory-region = <&wlan_fw_mem>, <&wlan_ce_mem>;` (idx0 = MSA/firmware, idx1 = CE).
Binding: Documentation/devicetree/bindings/net/wireless/qcom,ath11k.yaml.

**INTERRUPT GOTCHA (found 2026-07-17):** mainline ath11k ahb.c `irq_name[]` = {misc-pulse1,
misc-latch, sw-exception, **watchdog**, ce0..ce11, <DP rings>} and requests each by NAME
via `platform_get_irq_byname` (DT order irrelevant, names must match). The VENDOR node has
53 IRQs and is MISSING "watchdog" (it uses the downstream convention). So the mainline wifi
node needs the vendor's names + a **"watchdog"** entry too - but the vendor doesn't give the
ipq9574 watchdog SPI. => still need a TESTED ipq9574 ath11k wifi node (mrnuke's / community
Spectrum SBE1V1K) for: (a) the watchdog SPI, (b) exact wlan_fw_mem/wlan_ce_mem sizes.
Neither mainline ipq8074.dtsi nor any in-tree dts carries an ath11k integrated wifi node
(it's board-level/downstream only), so this is the last reference to source. FALLBACK:
construct with vendor IRQs (+ guess watchdog / omit and see if fatal) + wlan_fw_mem=q6-area,
wlan_ce_mem=caldb, and iterate on dmesg (`platform_get_irq_byname` / `failed to resolve msa`
errors will pinpoint it).

---

## 7. Remaining work to a testable build

1. **DTS** — DONE (appended to board `ipq9574-mbe7000.dts`, WIP/unverified): `&q6v5_wcss
   { status = "okay"; }`; a `wlan_ce_mem: wlan-ce@4d800000` reserved region
   (0x4d800000/0x500000); and `&soc { wifi: wifi@c000000 { ... } }` with compatible
   `qcom,ipq9574-wifi`, reg `<0xc000000 0x1000000>`, the 53 interrupts (52 vendor + Q6
   watchdog `GIC_SPI 325` inserted at idx 3, all by-name), `qcom,rproc = <&q6v5_wcss>`,
   `memory-region = <&q6_region>, <&wlan_ce_mem>`, status okay.
   ASSUMPTIONS to verify on first boot (dmesg): (a) `memory-region[0]=&q6_region`
   (the 0368 wcss region, = MSA/wlan_fw_mem) and `[1]=&wlan_ce_mem` (=caldb) — driver
   reads 2 regions via of_reserved_mem_region_to_resource(0/1); (b) watchdog SPI 325
   (= Q6 wdog) is the ath11k "watchdog"; (c) reg size 0x1000000 (vendor) vs binding's
   0x2000000. NOTE: can't dtc-precheck until 0366-0368 are applied to the kernel tree
   (they define &q6_region/&q6v5_wcss) - a full build validates it.
2. **kconfig**: enable `kmod-ath11k` + `kmod-ath11k-ahb` (package/kernel/mac80211/ath.mk),
   the 0367 secure-PIL remoteproc symbol, and any new qcom_scm option.
3. **Firmware package**: board-2.bin (section 4) + q6_fw/m3/caldata/regdb into the image
   under `ath11k/IPQ9574/hw1.0/`. Resolve `.mbn` vs `.mdt`.
4. **build -> flash -> bring up 2.4 GHz AP**, iterate on dmesg.

### BUILD 1 - 2026-07-17: SUCCESS (compiles, image built)
All patches applied clean to 6.18. Only ONE compile fixup needed: OpenWrt's
`package/kernel/mac80211/patches/build/150-ath_iommu_paging_domain_revert.patch`
reverts ath10k/ath11k to the old `iommu_domain_alloc(&platform_bus_type)` API (for
OpenWrt's default 6.6 kernel); that API is REMOVED in 6.18. Fixed by dropping the
ath11k hunk from 150 so ath11k keeps 6.18's `iommu_paging_domain_alloc(dev)` (+ IS_ERR
/ PTR_ERR). ath11k-ahb is the first driver to compile this path on 6.18 (ath12k dodged
it - its AHB path isn't built). NOTE the SCM(0366)+secure-PIL(0367)+q6 dts(0368) all
COMPILED clean on 6.18 - the API-drift worry didn't materialize there.
Image: sysupgrade sha256 4212b1f53dd72cff169855ac10a4ccecd9a910b29c46d532f6227d6c651bb604
(19.6 MB). Modules ath11k.ko + ath11k_ahb.ko built; QCOM_Q6V5_WCSS_SEC=y in kernel;
DTB carries qcom,ipq9574-wifi + ipq9574-wcss-sec-pil. NOT YET flashed/booted.
board-2.bin deliberately omitted (build it once dmesg shows the requested board key).

---

## 7a. CLEAN-FLASH RESULT - 2.4 GHz FULLY WORKING, PERMANENT (2026-07-17)
Flashed the factory image clean (no keep-settings). 2.4 GHz comes up with ZERO manual
steps: the 11-ath11k-caldata hotplug extracted cal-ahb-c000000.wifi.bin from 0:ART@0x1000
(128K) on its own; Q6 booted; ath11k loaded board-2.bin (from pkg) + caldata; phy0
(c000000.wifi, QCN5024) registered Band 1 (2.4 GHz). phy1 (QCN6274) = 5G+6G. ALL THREE
radios auto-up from a clean image. Only residual: "htt event 48 not handled" (harmless).
=> 2.4 GHz backport COMPLETE + permanent. Build r35286+16, factory sha256
1c1c30c03a94b7cc37b2b8db7315393221cfcf8de4c87dc086ab46d4b2bd187b. All WIP is now uncommitted
in the tree - ready to commit as a milestone.
POLISH LEFT (optional): htt event 48 warning (harmless QSDK HTT msg mainline ath11k
doesn't handle); bring up a 2.4 GHz AP to confirm operationally (radio+band verified).

### MAC ADDRESSES - factory MACs wired up 2026-07-17 (ethernet + 2.4G; 5/6G TODO)
Out of the box every interface used a bogus MAC: LAN/WAN random (locally-administered),
and the wifi radios the Atheros DEFAULT 00:03:7f:12:XX:XX (duplicated-last-octet =
"no real MAC programmed"). The real factory base MAC is stored as text
"hw_mac_addr=80:69:1A:B2:C1:07" (Linksys OUI) in the **devinfo** eMMC partition
(find_mmc_part devinfo; also has serial_number, cert_region, uuid_key). u_env ethaddr =
base+1 (...08). Scheme wired up (convention, matches vendor for wan): lan=base(+0),
wan=+1, 2.4G=+2, [5G=+3, 6G=+4 reserved].
- Ethernet: base-files/etc/board.d/02_network reads hw_mac_addr from devinfo
  (mbe7000_base_mac helper) and ucidef_set_interface_macaddr lan/wan. Result on clean
  flash: br-lan 80:69:1a:b2:c1:07, wan ...08.
- 2.4G (ath11k): the 11-ath11k-caldata hotplug now also patches the caldata MAC via
  ath11k_patch_mac "$(macaddr_add base 2)" 0 + ath11k_set_macflag. Verified on clean
  flash: phy0 = 80:69:1a:b2:c1:09.
- 5/6G (ath12k): STILL default (00:03:7f:...) - ath12k has NO caldata-patch hook like
  ath11k; its MAC comes from board-2.bin/OTP/QMI. TODO: a DTS local-mac-address/nvmem
  on the QCN9274 wifi node, or a board-2.bin MAC field. Separate (harder) task.

## 7b. RESULT - 2.4 GHz WORKS on HW (2026-07-17)
Full bring-up validated live. Boot sequence (all clean): remoteproc0 q6wcss boots
`ath11k/IPQ9574/hw1.0/q6_fw.mbn` -> "remote processor q6wcss is now up" -> ath11k
c000000.wifi probes (chip_family 0x4, WLAN.HK.2.9/Pine) -> board-2.bin matched
(bus=ahb,qmi-chip-id=0,qmi-board-id=255) -> caldata loaded -> **phy0 registered with
Band 1 (2.4 GHz ch1-14, HT/HE Wi-Fi 6, AP-capable, 30 dBm)**. Only residual: "htt event
48 not handled" (harmless). ALL derived DTS values were correct first try (interrupts,
watchdog SPI 325, memory-region <&q6_region>,<&wlan_ce_mem>).
KEY FIRMWARE FINDINGS:
- board-2.bin: built with ath11k-bdencoder, single board entry named exactly
  "bus=ahb,qmi-chip-id=0,qmi-board-id=255", data = vendor bdwlan.bin (128K). (Requested
  key learned from the first-boot dmesg "failed to fetch board data for ...".)
- CALDATA is REQUIRED (target eeprom_caldata set) and is DEVICE-SPECIFIC: ath11k requests
  `cal-ahb-c000000.wifi.bin`. Source = the **0:ART partition (mmcblk0p20, 128K)** - it
  holds the QCN5024 factory calibration (the QCN6274/ath12k self-calibrates, ART looked
  "empty" for it, but ART DOES have the QCN5024 cal). Extracted via
  `dd if=/dev/mmcblk0p20 ... cal-ahb-c000000.wifi.bin` (put in /lib/firmware/ath11k/ and
  the hw dir; both worked). cal_offset=128K, board_size=256K (mrnuke hw_params).
- Q6 CAN'T be restarted by ath11k module reload (rmmod/modprobe -> "can't start rproc
  q6wcss: -110", like ath12k) - needs a COLD reboot to re-test firmware/DTS changes.
PERMANENCE - DONE 2026-07-17 (rebuild in progress):
- board-2.bin added to package/firmware/ath11k-firmware-ipq9574-mbe7000/files/board-2.bin
  (md5 1efce612..., single entry bus=ahb,qmi-chip-id=0,qmi-board-id=255 = bdwlan.bin).
- Caldata hotplug: target/linux/qualcommbe/ipq95xx/base-files/etc/hotplug.d/firmware/
  11-ath11k-caldata - on FIRMWARE=ath11k/IPQ9574/hw1.0/cal-ahb-c000000.wifi.bin for
  linksys,mbe7000 does `caldata_extract_mmc "0:ART" 0x1000 0x20000`. TRUE offset is
  0x1000 (verified: [0,0x1000) all 0xff, caldata "01 00 04 04..." starts at 0x1000;
  0:ART is 1 MB total, holds multiple radios' cal). FW_LOADER_USER_HELPER(_FALLBACK)=y
  already effective via target/linux/generic/config-6.18, so the fallback hotplug fires.
- No MAC patching added (uses caldata factory MAC) - revisit if MAC is wrong/duplicate.
- kmod-ath11k-ahb / kmod-qrtr-smd target gate widened to also allow qualcommbe
  (package/kernel/mac80211/ath.mk + package/kernel/linux/modules/netsupport.mk).

## 8. Risks / open questions

- **ath11k `memory-region` wiring** for `fixed_mem_region`/`fixed_bdf_addr` — the exact
  reserved regions the driver expects. Cross-check vs a TESTED ipq9574 board dts
  (mrnuke's / Spectrum SBE1V1K) before first flash, else iterate via dmesg. *(next step)*
- **Secure-PIL Q6 boot** — the trickiest runtime bit (TZ/SCM auth of q6_fw). May need the
  `.mbn` vs `.mdt` resolution and correct SCM support from 0366.
- **firmware format** — `.mbn` vs `.mdt+.bNN`.
- Patches apply clean but **compile** against 6.18 APIs is unverified (SCM/remoteproc core
  may have drifted); expect small build fixups.

---

## 9. References
- mrnuke ath11k: patchwork `20260109044457.3074510-3-mr.nuke.me@gmail.com` (2/2), `-2` (1/2)
- remoteproc secure PIL: `https://patchwork.kernel.org/series/1041678/` (v10)
- forum (max_tx_ring bug + IPQ9554 testing): `forum.openwrt.org/t/ipq9574-ath11k-support-patch-missing-max-tx-ring-kernel-panic-on-client-connect/246704`
- Spectrum SBE1V1K (IPQ9574) thread: `forum.openwrt.org/t/spectrum-sbe1v1k-ipq9574-openwrt-support/245244`
- Xiaomi BE7000 PR: `github.com/openwrt/openwrt/pull/20604`
