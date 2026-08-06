# MBE7000 — SSH/shell flashing plan & verified facts

Living notes for installing OpenWrt onto a **retail Linksys MBE7000** that we have
a **root SSH shell** on (stock firmware). Everything here is verified live on the
device unless marked *(assumption)* or *(from prior docs)*. Corrections are called
out inline. Companion to `MBE7000_RETAIL_FLASHING.md` (webui/GPG teardown) and
`MBE7000_trajectory.md` (the earlier brick).

> ## ⛔ FINAL VERDICT (2026-08-06): RETAIL SLOT-INSTALL IS BLOCKED BY FUSED SECURE BOOT
>
> We executed this plan end-to-end and it **works mechanically but the custom
> kernel does not boot.** `mbe7000-flash.sh --commit` cleanly wrote+verified the
> ELF/MBN-wrapped OpenWrt to inactive slot B and flipped (bootcmd untouched);
> reboot → **auto_recovery reverted to stock slot A** (non-bricking, as designed).
>
> Root cause: the retail unit has **OEM secure boot fused ON** —
> `/sys/devices/system/qfprom/qfprom0/authenticate` reads **`1`**. The retail
> `bootipq`+TrustZone RSA-authenticate the kernel MBN's SHA-384/RSA-2048/cert-chain
> hash segment against the OEM root-key hash burned in QFPROM (one-time-programmable
> silicon eFuses — physical, irreversible). Our wrapper shipped a zeroed hash
> segment + zeroed segment-type `p_flags`, so authentication fails. A bootable
> custom kernel needs **Linksys/Belkin's signing key** (unavailable); modifying
> `bootipq` doesn't help (it's authenticated by the prior stage against the same
> fuse, and is the worst brick risk — no A/B fallback for the bootloader).
>
> **The MBE70 (developer SKU) differs only by fuse state** (secure boot off →
> boots bare unsigned FIT); its vendor-LuCI install path is unaffected and valid.
>
> Everything below documents the (correct) mechanics and the *superseded* pre-test
> belief that "wrapped is essentially guaranteed / signature is not the issue" —
> that belief (esp. §4b) is now known WRONG for a fused retail unit. Full teardown
> of the failure + fuse evidence: `MBE7000_RETAIL_FLASHING.md` correction banner.
> The flasher and its safety design are proven good — reusable for any **non-fused**
> A/B QCA unit; check `authenticate` first.

> **Golden rule (learned from the brick):** the U-Boot text env — especially
> `bootcmd` — is **global to both A/B slots**. auto_recovery only fails over when a
> slot *starts booting but doesn't come up*; it canNOT save you from a bad
> `bootcmd`, because the other slot runs the *same* bootcmd. The prior unit was
> bricked by `fw_setenv bootcmd bootpart1` (a non-command). **Our flow must never
> touch `bootcmd` or any global env that changes *how* a slot boots — only *which*
> slot boots.**

---

## 0. Access (this unit)

```
ssh -p 2222 -i /home/daniel/mbe7000_ssh/mbe7000_ssh_key \
    -o UserKnownHostsFile=/home/daniel/mbe7000_ssh/mbe7000_known_hosts root@192.168.1.1
```
- Host (our PC): `192.168.1.254` on `enp9s0`. This is also the `serverip` in the
  device U-Boot env (handy if we ever need TFTP recovery).
- Device: stock firmware `1.0.10.215314`, kernel `5.4.213`, IPQ9574, BusyBox
  v1.25.1, `id=root`. Full read/write eMMC access. `product.type=production`.

---

## 1. eMMC layout (verified live from /proc/partitions + PARTNAME)

| Part | PARTNAME | Size | Role |
|------|----------|------|------|
| p3   | `0:BOOTCONFIG`  | 256 KiB | dual-boot select (copy 0) |
| p4   | `0:BOOTCONFIG1` | 256 KiB | dual-boot select (copy 1) |
| p21  | `u_env` | 256 KiB | U-Boot **text** env (boot_part / auto_recovery / boot_part_ready / bootcmd) |
| —    | `s_env` | — | binary **boot counter** (Linksys format) |
| p28  | `0:HLOS`   | 8 MiB  | **slot A kernel** (FIT) |
| p29  | `rootfs`   | 500 MiB| **slot A rootfs** (→ `root=mmcblk0p29`) |
| p30  | `0:HLOS_1` | 8 MiB  | **slot B kernel** (FIT) |
| p31  | `rootfs_1` | 500 MiB| **slot B rootfs** (→ `root=mmcblk0p31`) |

Resolve names→devices generically with the vendor helper `find_mmc_part <PARTNAME>`
(scans `/sys/block/mmcblk*/*/uevent` for `PARTNAME=`). Do **not** hardcode p28–p31.

---

## 2. Which slot is active / which to write (verified)

**This unit is running slot A** and the inactive target is **slot B (p30/p31)** —
this is the **opposite** of the previously-bricked unit (which ran slot B). *The
script must detect this per-device; never hardcode.*

Consistent signals, all agreeing "active = A / copy 0":
- `fw_printenv boot_part` → `1`  (1 = A, 2 = B)
- `syscfg get fwup_boot_part` → `1`
- `/proc/boot_info/bootconfig0/0:HLOS/primaryboot` → `0` (0 = A, 1 = B)
- BOOTCONFIG partition raw byte @ offset 128 → `0`

**Generic target detection (vendor's own method, from `/usr/sbin/update`):**
1. active bootconfig = `get_bootconfig_name_flashboot` = the one with the **higher
   `age`** (`age0 >= age1 ? bootconfig0 : bootconfig1`). Both are `3` here → bc0.
2. target kernel part = `cat /proc/boot_info/<bc>/0:HLOS/upgradepartition` → `0:HLOS_1`
3. target rootfs part = `cat /proc/boot_info/<bc>/rootfs/upgradepartition` → `rootfs_1`

`primaryboot`/`upgradepartition` proc nodes show mode `r--r--r--` but the kernel
implements a write handler (the vendor scripts `echo N >` them), so root can write.

---

## 3. How a slot is selected & how the flip is committed (verified)

- U-Boot `bootcmd=bootipq` reads the **primaryboot** flags in BOOTCONFIG to pick the
  slot, then boots a **raw FIT** from that slot's kernel partition
  (`bootm ...#config@1`). primaryboot offsets: **128 = HLOS**, **148 = rootfs**
  (168 = WIFIFW, left untouched). `0`=A, `1`=B.
- The **vendor commit path** is `/usr/sbin/switch_boot_image` (+ `update_lib`):
  it sets `primaryboot` on both bootconfigs, then persists them with
  `do_flash_bootconfig` (dd of `/proc/boot_info/<bc>/getbinary_bootconfig` → the
  BOOTCONFIG partition), **and** `fw_setenv boot_part <other>` +
  `fw_setenv boot_part_ready 3`, then reboots. It flips to *the other* slot from
  `fwup_boot_part` — i.e. exactly the slot we will have written. We reuse this
  logic **minus the reboot**.
- OpenWrt's in-tree flip (`platform.sh` / `mbe7000-bootslot`) instead pokes the raw
  primaryboot bytes @128/@148 in both BOOTCONFIG partitions. Proven for
  OpenWrt→OpenWrt. We set **both** env + BOOTCONFIG for the one-time vendor→OpenWrt
  flip (belt-and-suspenders; covers whichever sync direction U-Boot uses).

---

## 4. Boot counter / auto_recovery — the safety net (verified)

- The dual-boot counter is **NOT** a text env var. `fw_printenv boot_count` →
  "not defined". It is a **binary record in the `s_env` partition** (Linksys format,
  little-endian): `{u32 magic=0x20110811; u32 count; u32 checksum=magic+count}`.
- U-Boot increments it each boot; if it crosses the threshold (OS started but never
  reset it), auto_recovery **fails over to the other slot**. Stock clears it at end
  of boot via `recovery_emmc -c`.
- **OpenWrt already handles persistence:** the in-tree init script
  `target/linux/qualcommbe/ipq95xx/base-files/etc/init.d/bootcount` writes a single
  count=0 record to `s_env` on every successful boot (byte-for-byte the same as
  `recovery_emmc -c`). So once OpenWrt boots it stays; if OpenWrt *fails to boot*
  the counter is never reset → U-Boot reverts to the intact stock slot.
- This is why the operation is **non-bricking**: we only ever write the **inactive**
  slot, leave `bootcmd=bootipq` untouched, and the stock slot remains a working
  fallback that auto_recovery restores if OpenWrt doesn't come up.

---

## 4a. DECISION (2026-08-05): split into two targets (MBE70 + MBE7000)

The two SKUs run **different `bootipq` builds** (verified) with different kernel
container expectations, so unifying into one image is not worth it. Per user
decision, split like MX4200 v1/v2 into two independent targets with distinct
compatibles:

| Target | compatible | kernel | install path | status |
|--------|-----------|--------|--------------|--------|
| `linksys_mbe70`   | `linksys,mbe70`   | **bare FIT** | vendor OpenWrt-fork **LuCI**, flashing **factory.bin** | **verified working** |

> ⚠ MBE70 `IMAGE/factory.bin` MUST be **`qsdk-ipq-factory-nor`** (a QSDK
> multi-image FIT with sections named `hlos`+`rootfs`). The vendor fork's
> `/lib/upgrade/platform.sh` `flash_section` only flashes recognised sections
> (`hlos`->kernel slot, `rootfs`->rootfs slot); a plain kernel FIT's `kernel-1`/
> `fdt-1` sections are "ignored" and the upgrade aborts ("Cant' find kernel-1
> after switching to ramfs"). This was the flashable format at commit 2c58a84; a
> stray uncommitted change to the flat `append-kernel|…|footer` image broke it,
> which is what the `MBE70_flash_new_mbe70.log` abort showed.

| `linksys_mbe7000` | `linksys,mbe7000` | **ELF/MBN-wrapped** (`Build/mbn-wrap`) | `dd` factory.bin to inactive slot from retail stock shell (`mbe7000-flash.sh`) | wrapped is the best bet (retail stock ships wrapped); confirm on the retail unit |

Files: new `dts/ipq9574-mbe70.dts` (thin include of the shared `ipq9574-mbe7000.dts`,
overriding model/compatible); two `Device/` blocks in `ipq95xx.mk`; base-files +
`uboot-envtools/files/qualcommbe_ipq95xx` updated to match `linksys,mbe70|linksys,mbe7000`.
Build both via multi-profile or one at a time (they're a single-choice in .config).

Note on the earlier "container-format" MBE70 flash log
(`~/openwrt_debug/MBE70_flash_container_format.log`): it did **not** actually test
the wrapped kernel — the vendor 19.07 LuCI sysupgrade only wrote BOOTCONFIG (p3/p4)
and errored on the rootfs_data/overlay step (`loop0` "Device size zero"); it never
wrote kernel/rootfs to slot B and rebooted straight back into vendor 5.4.213 on
slot A. So "wrapped fails to boot" is unproven — but the split is the chosen path
regardless.

## 4b. Kernel container format (`bootipq` bare-FIT vs ELF/MBN) — background

**This is the one genuinely unresolved risk and must be settled before `--commit`.**

Verified live on THIS retail MBE7000: the stock kernel partition (p28 `0:HLOS`,
and p30) does **not** start with a FIT. It is a **Qualcomm MBN/ELF two-stage
image**:
```
offset 0x0000  7f 45 4c 46 ...   ELF header + 3 program headers
offset 0x3000  d0 0d fe ed ...   the actual FIT (config@1), loaded to 0x44000000
```
`bootipq` on this unit is **phdr-driven** — the retail boot log shows
`Parsing phdr load addr 0x44000000 offset 0x3000 ...` then `Loading kernel from
FIT`. Our `factory.bin` is a **bare FIT at offset 0** (build recipe:
`KERNEL = kernel-bin | ... | fit gzip`, loadaddr 0x41000000). If retail `bootipq`
*requires* the ELF/MBN wrapper to locate the FIT, writing our bare FIT will fail
to boot — consistent with the earlier bricked unit's first attempt (bare FIT →
U-Boot prompt).

### EMPIRICAL RESULTS (MBE70 online 2026-08-05)
- MBE70 runs our OpenWrt (SNAPSHOT, kernel 6.18, aarch64), board `linksys,mbe7000`
  (same board_name/model as MBE7000 — one image serves both), `bootcmd=bootipq`,
  `boot_part=2` (slot B active).
- **MBE70's active kernel slot (p30) is a BARE FIT** (`d00dfeed`@0) and it boots
  via `bootipq` → MBE70's `bootipq` boots bare FITs.
- **The two U-Boots DIFFER but are 99.9% identical:** `0:APPSBL` (p18, 786432 B)
  MBE7000 `03a4684a…` vs MBE70 `3f28e410…`; only **847 bytes differ** (offsets
  4361–463383) and **every bootipq/phdr/FIT/secure-boot string is identical** (same
  CBT 7.0.25 code). The diffs read as per-SKU config/default-env, not different boot
  logic — but enough that container acceptance must be settled empirically.
- **Wrapped image BUILT + verified:** `scratchpad/mbe7000-factory-mbn.bin`
  (ELF@0, FIT@0x3000 load 0x44000000, hsqs@8 MiB, footer cksum 26C637AA) —
  structurally identical to the stock MBE7000 kernel. Built from existing artifacts
  (no rebuild) via `scratchpad/mbn-wrap.py`.

**Key inference:** MBE7000 stock ITSELF boots a wrapped kernel via this same
`bootipq`, so **MBE7000 + wrapped is essentially guaranteed**. The open test is the
reverse — does **MBE70's** `bootipq` also accept the wrapped format? If yes → ship
ONE wrapped image for both SKUs (unified). If no → MBE70 needs bare (per-SKU split).
Caveat: our wrapped ph1 hash segment is zeroed; if a `bootipq` validates the MBN
hash table it could reject it — the empirical boot test covers this.

What we actually know (corrected 2026-08-05):
- **MBE70 runs OpenWrt under `bootcmd=bootipq`** — confirmed by
  `MBE70_uboot_env_dump.txt` (live OpenWrt MBE70). So **`bootipq` on MBE70 boots
  the OpenWrt kernel**. (Earlier guess that MBE70 uses a changed `run bootpartN`
  bootcmd was WRONG — env is `bootipq`, identical to MBE7000 except `ethaddr`.)
- Therefore, IF MBE70's OpenWrt kernel partition holds our **bare FIT**, then
  `bootipq` (MBE70's build) boots bare FITs. The retail MBE7000 stock kernel is
  ELF/MBN-wrapped, so the ONLY open question is whether **MBE7000's `bootipq`
  binary == MBE70's** (same U-Boot → same acceptance of a bare FIT).
- Signature enforcement is NOT the issue — the retail boot log boots the FIT with
  crc32+sha1 only, no RSA; secure-boot fuses don't gate boot.

MBE7000 U-Boot (`0:APPSBL`, p18) saved for comparison:
`scratchpad/mbe7000_appsbl.bin` sha256 `03a4684ab377057189263ee655c9a5c15df3c287d699ae06c6284905f8f41a4c`.

**Decisive test (needs the MBE70 on hand — user offered):**
1. **`sha256sum` MBE70's `0:APPSBL` (p18) vs the MBE7000 hash above.** Same → same
   `bootipq` → our bare FIT boots on MBE7000 exactly as on MBE70. This is the
   single most decisive check.
2. First 4 bytes of MBE70's *active* kernel partition — expect bare FIT
   (`d00dfeed`) since MBE70 boots our build via `bootipq`. Confirms bootipq eats
   bare FITs.
3. (already known) `fw_printenv bootcmd` on MBE70 = `bootipq`.

**Design principle (user): keep MBE7000 and MBE70 UNIFIED.** If the retail
`bootipq` turns out to need a different container/bootcmd, apply the *same* change
to MBE70 in the target — don't fork the two SKUs.

**If retail `bootipq` needs the wrapper**, options (in order of safety):
- **(A, safest, unifying) Build an ELF/MBN-wrapped kernel for BOTH SKUs** so
  `bootcmd=bootipq` is kept untouched → A/B + auto_recovery stay intact, and both
  variants stay identical. MBE70 already tolerates a bare FIT, and the ELF/MBN
  wrapper is the QCA-standard superset that its `bootipq` also accepts, so one
  wrapped image works on both. Preferred because it does NOT touch global env.

  Exact structure to reproduce (verified via `readelf` on stock p28):
  ```
  ELF32 LE, Type=EXEC, e_machine=3 (EM_386, QC dummy), e_phentsize=32, e_phnum=3
    ph0 NULL off 0x0000 filesz 0x0094               MBN metadata header
    ph1 NULL off 0x1000 filesz 0x14b8 memsz 0x14b8  hash/sig (NOT boot-enforced)
    ph2 LOAD off 0x3000 vaddr=paddr 0x44000000  filesz=memsz=<FIT>  RW align 0x1000
  ```
  `bootipq` loads the PT_LOAD (ph2) to 0x44000000 then `bootm`s it. Ready-made
  wrapper staged at `scratchpad/mbn-wrap.py` (`mbn-wrap.py <in.fit> <out.mbn>`);
  our kernel FIT is `factory.bin[0 : 0x5bf750]` (6,027,088 B; FIT totalsize field).
  For a build-side version, add a `Build/` step for BOTH `linksys_mbe7000` and the
  MBE70 device. Boot enforces only crc32+sha1 on the FIT (no RSA), so ph1 hashes
  can be zero; revisit only if a bootipq is found to validate the MBN hash table.
- **(B, riskier) Change `bootcmd` to `run bootpart2`** (direct `mmc read`+`bootm`,
  boots a bare FIT). ⚠ `run bootpartN` is **not** A/B-aware (hardcodes
  prikern/altkern) → it **defeats auto_recovery** (failed boot loops, no
  fallback), and it would have to change on MBE70 too. Same class of global-env
  change that bricked the earlier unit; only with working serial-RX recovery.

Until this is resolved, the script writes/verifies the slot but the **boot
outcome is unproven**; keep the stock slot intact and do not rely on a clean
first boot.

## 4c. Build-system change: kernel ELF/MBN wrap (2026-08-05)

Added so the produced images boot on the retail MBE7000's phdr-driven `bootipq`
without touching global env, and stay unified with MBE70:
- `target/linux/qualcommbe/image/mbn-wrap.py` — wraps a bare FIT into the 3-phdr
  ELF/MBN (FIT@0x3000, LOAD 0x44000000), matching stock `0:HLOS` exactly.
- `ipq95xx.mk`: new `Build/mbn-wrap` macro; `Device/linksys_mbe7000` overrides
  `KERNEL = … | fit gzip … | mbn-wrap`. So the kernel used by BOTH `sysupgrade.bin`
  (tar `kernel` member) and `factory.bin` (append-kernel) is wrapped.

Why this is safe for OpenWrt→OpenWrt: `sysupgrade.bin` is a **tar** (`sysupgrade-tar`)
with separate `kernel`/`root` members; `emmc_upgrade_tar` writes each to its
partition **by member name** (CONTROL holds only `BOARD=…`, no kernel hash), so it
never parses the kernel container — wrapping does not affect the split.

**MBE70 LuCI test (user runs it):** flash the newly-built wrapped `sysupgrade.bin`
via LuCI → OpenWrt writes the wrapped kernel to the inactive slot, flips, reboots.
- Boots → MBE70's `bootipq` accepts the wrapped format → unified image confirmed;
  proceed to the MBE7000 install with the same image.
- Fails → auto_recovery reverts to the current (bare-FIT) slot; **non-bricking**.
  Then we'd keep MBE70 on bare and wrap only for the retail unit (per-SKU).

## 4d. Potential secure-boot bypass via generic `bootm` (`run bootpartN`) — 2026-08-06 recon

Read-only recon on the restored retail unit (root SSH still up). **Not yet tested.**

**The env already contains a generic-boot path that does NOT use `bootipq`:**
```
bootpart1=setenv bootargs $partbootargs  && mmc read $loadaddr $prikern $kernsize && bootm $loadaddr#$config_name
bootpart2=setenv bootargs $partbootargs2 && mmc read $loadaddr $altkern $kernsize && bootm $loadaddr#$config_name
loadaddr=4D100000  prikern=0x00010a22 (slot A p28)  altkern=0x0010ea22 (slot B p30)
kernsize=0x00004000 (=8 MiB)  config_name=config@1
partbootargs =...root=/dev/mmcblk0p29   partbootargs2=...root=/dev/mmcblk0p31
```
- `bootpart1`=boot slot A, `bootpart2`=boot slot B, via `mmc read`+**generic `bootm`**.
- **This explains the earlier brick:** the bricked unit was set `bootcmd=bootpart1` — but `bootpart1` is an *env var*, not a command. Correct form is **`bootcmd=run bootpart1`**. Bare `bootpart1` → "Unknown command" → dead. One missing `run`.
- These macros need a **BARE FIT** at partition offset 0 (`bootm $loadaddr` wants `d00dfeed`). The stock kernel is ELF/MBN-wrapped (ELF@0, FIT@0x3000) so `run bootpartN` would fail "Bad Magic" on *stock* — i.e. `bootpartN` is the developer/factory bare-FIT path (sibling macros `flashimg`/`flashimg2` TFTP-provision, default `image=MBE70.img`). Retail (fused) ships `bootcmd=bootipq` for the authenticated path instead.

**Hypothesis:** since generic `bootm` (unlike `bootipq`) does not make the QCA authenticate SCM call, `run bootpartN` on a bare-FIT OpenWrt kernel may boot on a fused retail unit — bypassing the kernel-MBN signature check entirely, WITHOUT any signing key. The image needed is our `linksys_mbe70` **bare-FIT** build (no wrapper).

**APPSBL (`0:APPSBL` p18, 786432 B, sha256 `03a4684a…`) static recon — SUGGESTIVE, NOT PROVEN:**
- Full QCA secure-boot subsystem present: `do_secure_authenticate`, `is_sec_boot_enabled`,
  `secure_authenticate` cmd (`board/qca/arm/common/cmd_sec_auth.c`), error strings
  `Kernel image authentication failed` / `Rootfs elf image authentication failed` /
  `Partition info authentication failed` / `secure boot fuse is (not) enabled`.
- Generic `bootm`/`mmc` are compiled in (vendor env uses them; bootm/FIT strings present:
  `Bad Magic Number`, `Wrong Image Format`, `## Booting kernel from Legacy Image`).
- The "Rootfs elf image authentication" concept has no equivalent in upstream `bootm` — it's
  a QCA `bootipq`/secure-path routine, suggesting auth is NOT wired into generic `bootm`.
- Could NOT statically PROVE `bootm` skips auth: the auth/bootm/bootipq message strings live
  in a 32-bit **string-pointer table** (~`0x4a403000–0x4a4036c0`), so refs are table-indexed,
  not direct adrp+add/ldr-literal → static call-graph attribution was inconclusive. A full
  disasm proof is a real RE project; the empirical boot test is the decisive answer.

**Parser fact:** this U-Boot has the **hush shell** (`HUSH_VERSION`/`HUSH_NO_EVAL` in the
binary; vendor env uses `&&` ×4). Hush supports `&&`, `||`, `;`. So `bootcmd=run bootpart2 || bootipq`
is valid *syntax*. **BUT `||` only fires if the left side RETURNS non-zero** — `bootm` that
loads a kernel which then hangs/panics never returns, so `||` gives NO protection against a
*hang* (only against a clean error return like "Bad Magic"/auth-reject). And `run bootpartN`
**bypasses `bootipq`'s auto_recovery** (the boot-counter slot-switch lives in `bootipq`), so a
stuck custom `bootcmd` has NO automatic fallback. → the **eMMC writer (rewrite `u_env` p21)**
is the real safety net for this experiment, not `||`.

**Test plan (only with eMMC-writer backstop on hand):**
```
slot A p28/p29: keep stock signed kernel   (bootipq fallback; primaryboot -> A)
slot B p30/p31: OpenWrt BARE FIT (linksys_mbe70 image)
bootcmd = run bootpart2 || bootipq         (|| catches clean errors only)
```
Boots OpenWrt → bypass real (fused MBE7000 becomes usable, incl. the bricked one once revived).
`bootm` errors → falls to stock A. `bootm` hangs → eMMC writer restores `u_env`.

### Execution plan (agreed 2026-08-06) — waiting on hardware

- **Test bed = the already-disassembled, previously-bricked MBE7000** (also fused, so
  results transfer). **Keep the just-restored pristine retail unit untouched** — do NOT
  experiment on it.
- **No interactive U-Boot console possible:** the RX pin is **not routed** on the board
  (hardware, not a `tio --flow` issue), so the safe "type `run bootpart2` at the prompt,
  power-cycle to undo" path is OUT. Must persist `bootcmd` and use the eMMC writer to recover.
- **TX serial = observability** (boot logs worked on TX before): the test is NOT blind — the
  TX log shows which outcome occurred (`## Loading kernel from FIT` + OpenWrt banner = boot;
  `Bad Magic`/auth-fail line = clean reject; kernel panic = hang mode).
- **eMMC writer = two jobs:** (1) revive the brick by rewriting `u_env` (p21) with a good
  `bootcmd`; (2) recovery net for the test (rewrite `u_env` if a custom `bootcmd` hangs).
- **Steps when hardware arrives:**
  1. Dump the bricked `u_env` (p21) via the writer → send to Claude → get back a corrected
     blob (`bootcmd=bootipq`, **CRC32 recomputed**) to revive the board. (Kernel/rootfs/
     BOOTCONFIG are almost certainly intact; only `bootcmd` was corrupted.)
  2. Write OpenWrt **bare-FIT** `linksys_mbe70` image to slot B (p30 kernel + p31 rootfs);
     keep stock signed kernel on slot A; primaryboot → A.
  3. Set `bootcmd=run bootpart2 || bootipq` (offline via writer), power on, watch TX.
  4. Recover via writer (rewrite `u_env`) if it hangs.
- **Prep Claude can do now:** confirm the exact bare-FIT `linksys_mbe70` image file + layout;
  have the `u_env` CRC-fix ready (U-Boot env = `[CRC32 LE][key=val\0…\0\0]`).

## 5. The image to flash (verified in `bin/targets/.../`)

Use **`...-linksys_mbe7000-squashfs-factory.bin`** for the vendor→OpenWrt install
(NOT sysupgrade.bin) — **valid layout for the dd split; boot-ability pending §4b.**
Layout confirmed by inspection:

```
offset 0x000000  d0 0d fe ed   kernel FIT (config@1, mbe7000 DTB), padded to 8 MiB
offset 0x800000  68 73 71 73   rootfs squashfs ('hsqs')
last 256 bytes   .LINKSYS. ... footer (harmless here; only the webui path reads it)
size 21,954,816 bytes  (kernel FIT ~6 MiB < 8 MiB guard OK)
```

This exactly matches the vendor `Update_eMMC` split, so the write is:
```
dd if=factory.bin of=<inactive 0:HLOS>  bs=4M count=2   # first 8 MiB  → kernel slot
dd if=factory.bin of=<inactive rootfs>  bs=4M skip=2    # remainder    → rootfs slot
```
- kernel slot (8 MiB) gets factory.bin[0 : 8 MiB]  (padded FIT)
- rootfs slot gets factory.bin[8 MiB : EOF] = squashfs + footer (footer trailing
  bytes are ignored by squashfs)

Fully verifiable after write: sha256(kernel-part 8 MiB) == sha256(factory[:8M]);
sha256(rootfs-part first 13,566,208 B) == sha256(factory[8M:]). Magic checks:
`d00dfeed` at kernel part offset 0, `hsqs` at rootfs part offset 0.

---

## 6. Install procedure (what the script does) — DRY-RUN BY DEFAULT

1. **Preflight (read-only):** ssh in; confirm `board`/model; resolve active slot +
   target kernel/rootfs partitions via `/proc/boot_info` (§2); check `bootcmd` is
   still `bootipq` (abort if not); check `/tmp` free space.
2. **Stage + verify:** scp `factory.bin` to `/tmp`; compare sha256 host↔device.
3. **Write inactive slot only:** vendor-style `dd count=2` / `skip=2` to the target
   kernel/rootfs partitions. Never touches the running slot.
4. **Verify write:** read back magics + region sha256 (§5). Abort flip on mismatch.
5. **Flip (no reboot):** run `switch_boot_image` logic with the final `reboot`
   stripped → sets primaryboot on both BOOTCONFIGs + `boot_part`/`boot_part_ready`.
   Also directly set the raw @128/@148 bytes as backup.
6. **Stop.** Print the manual `reboot` command and the one-line **rollback**
   (re-flip to the original slot) for the user to run. Reboot is the user's call.

Writing requires an explicit `--commit`; without it the script only does steps 1–2
(preflight + optional staging) and prints the plan.

---

## 7. Risk assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| OpenWrt kernel doesn't boot on MBE7000 (never confirmed on real HW; only MBE70 has) | Medium | Only inactive slot written; `bootcmd` untouched → auto_recovery reverts to stock. Non-bricking. |
| We touch global env wrongly (the prior brick) | High if it happens | Script **never** writes `bootcmd`; only `boot_part`/`boot_part_ready`, which are the vendor's own flip vars. |
| Wrong slot detected → overwrite running system | High if it happens | Detect via vendor `upgradepartition`; assert target≠active; write only the inactive slot. |
| Bad transfer / partial write | Medium | sha256 staging check + post-write region verify before the flip. |
| Counter reverts OpenWrt after N reboots | Low | In-tree `bootcount` init resets `s_env` on successful boot. |

**Likelihood of a successful, reversible install: high.** Worst realistic case is
"OpenWrt doesn't boot → auto_recovery returns to stock", not a brick — provided we
never touch `bootcmd`.

---

## 8. Rollback / recovery (no serial needed)

Because we keep the stock slot intact and never change `bootcmd`:
- **Before reboot:** re-run the flip targeting the original slot (script prints the
  exact command), or just don't reboot.
- **After a failed OpenWrt boot:** auto_recovery flips back automatically after the
  boot-count threshold. If we still have any shell, `mbe7000-bootslot <orig>` or the
  vendor `switch_boot_image` flips back.
- Serial TX-only remains (RX was the blocker before); TFTP recovery via `serverip
  192.168.1.254` is a last resort but should not be needed.

---

## 9. Open items / to re-verify before `--commit`

- [ ] Confirm the exact U-Boot BOOTCONFIG↔boot_part **sync direction** (log line
      "Sync BOOTCONFIG to boot_part(2 -> 1)" is ambiguous). Handled defensively by
      setting both; note for certainty.
- [x] Confirm OpenWrt actually boots on *this* MBE7000 (first real-HW boot).
      **RESOLVED 2026-08-06: it does NOT boot — fused secure boot rejects the
      unsigned MBN (see FINAL VERDICT banner up top). Non-bricking design held;
      auto_recovery reverted to stock. This route is blocked.**
- [ ] Decide whether to also mirror config (`platform_copy_config`) — N/A for the
      first vendor→OpenWrt install (clean first boot).
