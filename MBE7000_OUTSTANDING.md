# MBE7000 — Outstanding Items / TODO

Status snapshot (2026-07-17). Working: all three radios (2.4 GHz QCN5024/ath11k,
5+6 GHz QCN9274/ath12k) + single-chip MLO, LAN (QCA8075) + WAN (QCA8081),
per-device factory MACs on every interface, dual-boot boot-counter reset,
fw_printenv/setenv, and a verified from-scratch clean build producing a bootable
factory image. See `MBE7000_PORTING_NOTES.md` for the full port history and
`MBE7000_ATH11K_24G_BACKPORT.md` for the 2.4 GHz recipe.

Legend: **P1** functional defect · **P3** cosmetic/log noise · **U** upstream/maintainability
· **?** unconfirmed.

---

## P1 — Functional

### 1. 5 GHz DFS + regulatory (the one real bug)
- **Symptom:** country set on the ath12k radios is ignored (phy stays self-managed
  `US`); DFS channels won't start (`vdev start … invalid regdomain`); 5 GHz capped
  at 80 MHz (160 MHz needs DFS); 6 GHz `auto` lands on US-only channels.
- **Root cause:** WMI reg-event parse failure — firmware sends a
  `REG_CHAN_LIST_CC_EXT` event whose TLV layout mainline ath12k 6.18 can't decode
  (`failed to parse tlv -22` → `wmi.c:6806`). Leading hypothesis: our **forced
  dual-MAC** config (`qcom,ath12k-force-dualmac`) makes the firmware emit that
  event. Corroborated by OpenWrt PR #20373 (BE800): same driver + WLAN.WBE
  firmware, regulatory works because it's all single-MAC. NOTE: this is NOT a
  regdb problem — our board-2.bin regdb already contains GB/US/DE/HK (see the
  re-diagnosis section in `MBE7000_PORTING_NOTES.md`).
- **Workaround (in use, live uci):** pin non-DFS / PSC / region-legal channels —
  5 GHz ch36/EHT80, 6 GHz ch37 (PSC) up to 160 MHz (6 GHz has no DFS).
- **Real fix:** an ath12k patch to parse the dual-MAC reg event, OR accept the
  trade-off (6 GHz XOR DFS/upper-5 GHz). Isolation test to confirm cause: drop
  `qcom,ath12k-force-dualmac`, rebuild, see if reg/DFS works in single-MAC.

### 2. Channel defaults not baked
- A fresh flash defaults radios to `channel=auto`, which lands on DFS / US-only
  channels and fails to come up cleanly. The working pins are live-uci only.
- **Next step:** ship `uci-defaults` (or board.d wifi defaults) with 5 GHz on a
  non-DFS channel and 6 GHz on a low PSC channel, so a generic image comes up
  correctly with no manual uci.

---

## P3 — Cosmetic / log noise (non-fatal)

3. `wmi.c:6806` WARNING + stack trace — the reg-event parse failure from item 1;
   fires at boot and on any country change / `wifi reload`. Harmless but noisy.
4. `ath12k … failed to flush transmit queue, data pkts pending N` and
   `ath12k … dp_tx: failed to find the peer with peer_id N` — benign ath12k
   data-path races during peer/vdev teardown (a frame is still queued for a
   client that just disconnected). Cosmetic log noise on client churn; not a
   crash or service loss, not fixed by a rebuild.
5. Boot-time `htt event 48 not handled`, `memory type 10 not supported`,
   `cal-pci …-12`, `WMI MAC1 -71` — all previously confirmed non-fatal.
   (ath11k / 2.4 GHz path shows zero errors.)
6. `SQUASHFS error: … xz decompression failed, data probably corrupt` on /rom —
   NOT a code bug and NOT failing eMMC (no block-layer/mmc I/O errors logged).
   Diagnosed 2026-07-17 as corruption in the *currently flashed* rootfs image,
   an artifact of the earlier incremental/hot-swap build_dir workflow. The
   freshly clean-built squashfs decompresses 100% cleanly (unsquashfs: 965 files,
   no decompression errors), so a clean flash of a from-scratch image is the fix.
   Escalate to flash-write/eMMC only if it recurs after a clean flash.

---

## U — Upstreamability / maintainability (not broken, matters before a PR)

7. `qcom,ath12k-force-dualmac` is a downstream DT prop + driver patch
   (`705-ath12k-force-dualmac-from-dt.patch`), not in upstream ath12k.
8. ath11k IPQ9574 (`600-ath11k-support-ipq9574.patch`) + secure-PIL Q6
   (`0366`–`0368`) are backports of not-yet-merged upstream series — expect churn
   as they land.
9. `board-2.bin` uses a hand-forged `qmi-board-id=255`; PR #20373 (BE800) reads
   `qcom,board_id` from DT via a small patch — the cleaner convention to adopt.
10. The dev-notes `.md` files (`MBE7000_PORTING_NOTES.md`,
   `MBE7000_ATH11K_24G_BACKPORT.md`, this file) should be dropped from an upstream
   PR.
11. 2.4 GHz runs ath11k FW memory mode 0 → ~128 MB CMA reservation (heavy but
    fine; unused CMA is reclaimable, so low real cost).

---

## ? — Unconfirmed

12. 5/6 GHz per-unit calibration: ath12k relies on `board-2.bin` BDF, not per-unit
    ART caldata (`cal-pci …` load fails, non-fatal). RF cal may be generic, not
    per-unit. Confirm whether per-unit cal exists / matters for this board.
13. Whether the stock secure-boot U-Boot accepts our `factory.bin` directly — only
    flashed via the vendor webui so far.

---

## LED — FIXED 2026-07-17 (pending on-hardware confirmation after flash)

14. Front-panel RGBW status LED. **Root cause found:** the tree had `CONFIG_PWM`/
    `CONFIG_PWM_IPQ` but **not `CONFIG_LEDS_PWM`**, so the `leds-pwm` driver never
    built and the `pwm-leds` DTS node produced zero `/sys/class/leds` devices.
    **Mapping + polarity CONFIRMED on hardware** by driving each PWM channel of
    pwmchip0 directly: ch0/gpio44=red, ch1/gpio45=green, ch2/gpio46=blue,
    ch3/gpio47=white; polarity normal (100% duty = full brightness).
- **Fix applied:** `CONFIG_LEDS_PWM=y`; DTS confirmed; blue `default-state="on"`.
- **Behaviour scheme (vendor-faithful, decoded from the MBE70WRT firmware image
  cbt_led.sh / cbt_check_internet.sh / CBT_system_ready):**
  blue = booted/ready · **white = internet reachable** · red = no internet
  (vendor polls connectivity ~60 s and flips white<->red). Implemented as
  `usr/bin/mbe7000-led` (set one solid colour) + `usr/sbin/mbe7000-ledd`
  (connectivity poll) + `etc/init.d/mbe7000-ledd` (procd, board-guarded).
  Vendor also has red-dimming during a factory-reset hold and supports
  yellow/purple/cyan mixes + a "pulse" breathing trigger (not replicated).
- **Remaining:** rebuild + flash to confirm the four `/sys/class/leds/*:status`
  nodes appear, blue lights on boot, and it flips to white (internet) / red.

---

## sysupgrade / dual-boot flashing — FIXED 2026-07-17 (pending on-hardware test)

15. `sysupgrade` never took effect ("the partition didn't change after flashing"),
    and forcing the written slot gave U-Boot "Config not available". **Root cause:**
    `platform.sh` wrote a *fixed* slot (`0:HLOS`/`rootfs` = slot A, p28/p29) while
    the device runs from slot B (p30/p31), and **never set BOOTCONFIG** — so the
    new image landed on the non-booting slot and the boot pointer never moved.
    (The images themselves are fine: the sysupgrade tar *does* contain the kernel —
    `sysupgrade-tar` defaults `kernel=$(IMAGE_KERNEL)` — and the hlos FIT has
    `config@1`, which is what the vendor U-Boot wants.)
- **Boot mechanism (decoded from the U-Boot env):** `bootipq` runs `bootpart1`
  (slot A: `mmc read $prikern`=p28, root p29) or `bootpart2` (slot B:
  `$altkern`=p30, root p31), each `bootm ...#config@1`. Slot selected by the
  BOOTCONFIG primaryboot flags (offset 128 HLOS / 148 rootfs; 0=A, 1=B) in
  0:BOOTCONFIG (p3) + 0:BOOTCONFIG1 (p4). Reference: the vendor `flash.scr`
  (imxtract hlos/rootfs → raw `mmc write`) and OpenWrt `ipq40xx` `sony.sh`.
- **Fix:** rewrote `platform.sh` to be A/B-aware — detect the active slot from
  BOOTCONFIG, write kernel+rootfs to the **inactive** slot (via `emmc_do_upgrade`,
  which also carries config through `emmc_copy_config`), then flip BOOTCONFIG to
  the new slot. Writing the inactive slot means the running system stays intact as
  a fallback, so a bad flash can't brick (return to the old slot via
  auto_recovery or a manual BOOTCONFIG edit). Aborts if the active slot can't be
  read (never overwrites the running slot on a bad guess).
- **Note on image choice:** flash the **sysupgrade.bin** via `sysupgrade` (the
  A/B path). The **factory.bin** is the combined QSDK-FIT container for the
  *vendor webui* flow — do NOT `sysupgrade` the factory.bin (it goes down the
  `emmc_upgrade_fit` path and writes the container, not a bootable kernel).
