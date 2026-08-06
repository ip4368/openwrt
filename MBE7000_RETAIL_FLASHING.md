# MBE7000 (retail SKU) — secure boot & firmware-flashing teardown

Investigation of how the **retail Linksys MBE7000** (not the developer MBE70WRT)
verifies firmware, whether an unsigned OpenWrt image can be installed, and why
the first attempts were rejected. Companion to `MBE7000_PORTING_NOTES.md`.

Hardware in hand: a genuine **retail MBE7000** (Belkin/Linksys "oak", firmware
`1.0.14.216607`, U-Boot **CBT 7.0.25 [IPQ9574].[SPF12.1].[CS1]**). The stock
factory `.img` fails the webui updater's "image check". Serial console has **TX
only** (RX believed unexposed). No SSH/telnet on the retail firmware.

Artifacts examined:
- `~/Downloads/FW_MBE7000_1.0.14.216607_prod.signed.img` — retail signed image.
- `~/MBE7000_debug/MBE7000_boot.log` — retail TX boot log incl. a flash attempt.
- Retail rootfs extracted from the signed `.img` (squashfs at file offset 0x800000).

---

## ⚠️ CORRECTION (2026-08-06) — RETAIL BOOT **DOES** ENFORCE SECURE BOOT; THIS ROUTE IS A DEAD END

**The original TL;DR #1 below ("Boot has NO signature enforcement") is WRONG for
the retail unit.** It was inferred from the MBE70 (developer SKU) and the TX-only
boot log, before we had a root shell on a retail unit *and* actually tried to boot
a custom kernel. Both are now done, and the verdict is reversed:

- **Empirical test:** built an ELF/MBN-wrapped OpenWrt kernel, dd'd it to the
  inactive A/B slot (slot B, p30/p31) from the retail root shell via
  `mbe7000-flash.sh --commit` (clean write + sha256 verify + BOOTCONFIG flip,
  `bootcmd` untouched), rebooted → **it did NOT boot; U-Boot `auto_recovery`
  reverted to the intact stock slot A.** (Safety net worked — no brick.)
- **Read-only post-mortem** (slot A stock kernel vs our slot B kernel): the ELF32
  skeleton is byte-identical *except* (a) our Qualcomm segment-type `p_flags` were
  zero (stock PH0=`0x07000000` elf/phdr seg, PH1=`0x02000000` hash seg, PH2=`0x6`),
  and (b) **our hash segment (PH1 @0x1000, 0x14b8) was all zeros** while the stock
  one is a full signed Qualcomm MBN hash segment: 40-byte MBN v6 header → code_size
  `0x90` = 3× 48-byte **SHA-384** hashes, sig_size `0x100` = **RSA-2048**,
  cert_chain `0x10e0` = **X.509 chain**. So retail `bootipq`+TrustZone do real MBN
  authentication.
- **The fuse is blown:** `/sys/devices/system/qfprom/qfprom0/authenticate` (QCA
  qfprom driver, world-readable) reads **`1`** = OEM secure boot enabled in QFPROM.
  QFPROM is one-time-programmable eFuses inside the SoC — physical, irreversible,
  can't be cleared in software.

**Consequence:** a custom (OpenWrt) kernel cannot be authenticated without
**Linksys/Belkin's RSA signing key**, which chains to the OEM root-key hash fused
in silicon. Writing a modified `bootipq` doesn't help either: the APPSBL is itself
authenticated by the prior boot stage against the same fuse, so an unsigned/
modified bootloader won't load (and it's the highest brick risk — no A/B fallback
for the bootloader chain; EDL on a fused unit typically needs a signed firehose).

**Why the MBE70 differs (same near-identical `bootipq`, 847-byte diff):** it's the
**fuse state, not the code** — the developer MBE70 has secure boot *off*, so its
chain skips authentication and boots a bare unsigned FIT. Retail MBE7000 has it
*on*. The MBE70 target (vendor-LuCI install, bare FIT) remains fully valid.

**Only theoretical openings left:** the actual signing key (unavailable), or an
exploitable *logic* bug in the SBL→APPSBL→kernel authentication path (deep vuln
research); hardware fault-injection/glitching is lab-grade and out of scope.

Everything below this banner predates the correction; §2 in particular is wrong,
and the "paths forward" in §7 do not overcome the fuse. Kept for the format
teardown (§1, §3, §4), which is still accurate and useful.

---

## TL;DR

1. ~~**Boot has NO signature enforcement.** The retail U-Boot boots a FIT with
   **crc32 + sha1 only** ... So *anything we can get onto a boot slot will boot*,
   signed or not.~~ **← WRONG, see the CORRECTION banner above.** This was inferred
   from the TX-only boot log (which shows the crc32/sha1 of the *inner FIT* — the
   outer MBN RSA authentication happens in TrustZone and doesn't print on this
   console) and from the MBE70. The retail fuse (`authenticate=1`) **does** enforce
   the MBN signature; an unsigned custom kernel is rejected and reverted.

2. **The flash-time check is NOT cryptographic by default** — `verify_linksys_header`
   only checks a plaintext `.LINKSYS.` magic + a POSIX `cksum` (CRC-32). Trivially
   forgeable, and we built a byte-correct footer for it (see below).

3. **BUT the retail webui path is GPG-gated.** The manual-upload flow reaches
   `fwcc verify_signature`, and on this unit it bails at the
   `elif fwup_gpg_mode == 1 → exit` branch **before** `verify_linksys_header` is
   ever consulted. We don't hold Linksys's GPG key, so **no footer/CRC trick can
   pass the stock webui while `fwup_gpg_mode=1`.**

4. **Conclusion:** installation must **bypass the webui verify entirely** and
   write directly to an inactive A/B slot (boot itself doesn't check), via either
   serial-RX → U-Boot TFTP, or a root shell on the vendor firmware.

---

## 1. The signed retail image format

`FW_MBE7000_1.0.14.216607_prod.signed.img` (45,741,240 bytes) is a **Qualcomm
authenticated-boot ELF (MBN)**, not a bare FIT:

| Region | Contents |
|--------|----------|
| ELF header, 3 program headers | ph0 meta (0x94), **ph1 hash/sig segment** (off 0x1000, 0x14b8), **ph2 FIT** (off 0x3000, load 0x44000000, 0x51cb4c) |
| ph1 (hash-table segment) | QC MBN v6: per-segment SHA hashes + **RSA signature** + **3-cert X.509 chain** (12 DER SEQUENCEs; `OU=Linksys` in a cert) |
| ph2 payload | a plain FIT (`d00dfeed`), `config@1`, kernel `Linux-5.4.213` + fdt, **crc32+sha1 hashes only, no FIT signature node** |
| 0x51fb4c | a **second** signed ELF (load 0x42000000, ~37 MB) whose payload contains the rootfs squashfs at file offset **0x800000** |
| last 256 bytes | a plaintext **`.LINKSYS.` footer** (see §3) |

The RSA/cert chain is real, but it is the thing the boot chain does **not**
enforce on this unit. The FIT it wraps is verified only by crc32+sha1.

---

## 2. Boot-time verification (U-Boot) — none that blocks us

From the retail boot log:
```
Parsing phdr load addr 0x44000000 offset 0x3000 size 0x51cb4c type 0x1
## Loading kernel from FIT Image at 44000000 ... Using 'config@1' configuration
   Hash algo: crc32 ... Hash algo: sha1 ...
   Verifying Hash Integrity ... crc32+ sha1+ OK
```
No `Authenticating`, no RSA, no cert verify. Same CBT U-Boot lineage as the
MBE70WRT (which also boots plain FITs). **A plain OpenWrt FIT with `config@1`
boots** (already proven on the MBE70WRT). This is the key enabler: the barrier is
purely the userspace *updater*, not the bootloader.

---

## 3. Flash-time verification — the `fwcc` chain

### Entry points (`usr/sbin/fwcc`, a shell script)

`verify_linksys_header` (the CRC path) validates **only two** things:
- last-256-byte trailer, bytes **1–9** == `.LINKSYS.`
- bytes **33–40** == uppercase-hex POSIX **`cksum`** of the body
  (everything before the 256-byte trailer). `IMAGE_LENTGH = filesize - 256`.

The SKU compare right below it is commented out. `hdr_version`, `sku`,
`sign_type`, `signer`, `kernel_ofs`, `rfs_ofs` are read but **not** validated.

Vendor trailer decoded from the real image (last 256 bytes, then zero-padded):
```
.LINKSYS.01000408MBE7000        F6AA74A60       K0000000F0522B4C
 magic    ver len sku            └cksum┘         (cosmetic offsets)
```
**Validated:** `cksum(vendor_body)` == `F6AA74A6` == the trailer's bytes 33–40.
So the algorithm is a plain POSIX cksum and our host `cksum` matches the device's
busybox `cksum` exactly.

### The gates above it (`verify_signature` / `verify_signature_gpg`)

`/etc/product.type` = `production`; **`/etc/fwcaps.sig` is empty** (so
`Signed=""`, never `"signed"`). `fwup_gpg_mode` is **not set anywhere in the
rootfs** (runtime syscfg value). Logic:

```
verify_signature  → (fwcaps.sig exists) → verify_signature_gpg:
   extract_gpg_image → GPG verify fails for an unsigned image → FirmwareImage=""
   if  Region==US && product.type==production && fwcaps.sig=="signed"  → exit 2   # impossible (Signed="")
   elif fwup_gpg_mode == 1                                            → exit 2   # ★ the live gate
   else verify_linksys_header (magic + cksum)                          → pass/fail
```

`usr/sbin/update` (the eMMC flasher) then dd's the image onto the **inactive**
A/B slot:
```
dd if=<img> of=<inactive 0:HLOS>  bs=4M count=2   # first 8 MiB  → kernel slot
dd if=<img> of=<inactive rootfs>  bs=4M skip=2    # remainder    → rootfs slot
```
So the vendor image layout is **[kernel padded to 8 MiB][rootfs squashfs][footer]**.

### How the webui actually invokes it (manual "choose file → Update")

```
www/fwupdate.html  POST /jcgi/  X-JNAP-Action: updatefirmware
  → www/ui/cgi/jcgi.cgi           (Lua) saves upload to /tmp, calls handler
  → firmware-update.lua           os.execute("update <file>")
        non-zero  → returns  ErrorSignatureCheckFailed     ← the "not signed" error
  → usr/sbin/update  → source /usr/sbin/fwcc verify_signature <file>
```
(The OTA path — `fwupd`, `service_autofwup.sh update_firmware_now`,
`fwupd -m 2` — funnels to the *same* `fwcc verify_signature`.)

---

## 4. What we built (correct, but insufficient here)

Changed `IMAGE/factory.bin` for `linksys_mbe7000` in
`target/linux/qualcommbe/image/ipq95xx.mk` from the nested `qsdk-ipq-factory-nor`
FIT to the **flat vendor layout + forged footer**:

```
IMAGE/factory.bin := append-kernel | check-size 8192k | pad-to 8192k | \
                     append-rootfs | pad-to 64k | linksys-mbe7000-footer
```
New `Build/linksys-mbe7000-footer` stamps a 256-byte trailer: `.LINKSYS.` magic
at byte 1, `MBE7000` sku, and the uppercase-hex `cksum` of the body at bytes
33–40.

**Verified end-to-end** on the real build output:
- `magic='.LINKSYS.'`, `hdr_cksum == body_cksum` (`D3564E4A`) → passes
  `verify_linksys_header` verbatim.
- kernel FIT (`d00dfeed`) at offset 0; rootfs (`hsqs`) at exactly 8 MiB — the
  split `usr/sbin/update`'s `count=2 / skip=2` expects.
- Kernel 6.0 MiB < 8 MiB → `check-size` guard passes.

This footer is **provably correct** and is kept — it is required for the eventual
install regardless of route. It is simply never reached while `fwup_gpg_mode=1`.

---

## 5. Why the webui still rejected it

With a correct footer and empty `fwcaps.sig`, the **only** remaining branch that
can `exit 2` (→ `ErrorSignatureCheckFailed`) is `elif fwup_gpg_mode == 1`. So this
retail unit has **`fwup_gpg_mode=1`** (a provisioned/runtime syscfg value, not in
the image), making GPG mandatory on the firmware path. We do not have Linksys's
GPG private key, so the stock webui cannot be made to accept an unsigned image.

The earlier boot-log line `[fw.sh] verify_linksys_header` came from the
**bootloader**-flash attempt, which uses the `fwcc verify_linksys` entry
directly (no GPG gate) — unrelated to the firmware-image path.

**To confirm on-device:** watch `/dev/console` (TX) during a flash — it prints
`[fw.sh] verify_signature …` and exits with no `verify_linksys_header` line; or
`syscfg get fwup_gpg_mode` → `1` if any shell is available.

---

## 6. OpenWrt → OpenWrt is unaffected by any of this

Two separate build outputs / code paths:

| Path | Image | Consumer | Sees footer? |
|------|-------|----------|--------------|
| Vendor → OpenWrt (one-time) | `factory.bin` | stock `update`/`fwcc` | yes (required) |
| OpenWrt → OpenWrt (forever) | `sysupgrade.bin` | our A/B `platform.sh` → `emmc_do_upgrade` | no |

`REQUIRE_IMAGE_METADATA=1` makes a plain `sysupgrade factory.bin` **refuse**
(no OpenWrt metadata). A forced `sysupgrade -F factory.bin` would go down the
`emmc_upgrade_fit` branch (factory.bin starts with FIT magic), write the kernel
slot only, and fail to boot → U-Boot `auto_recovery` reverts. **Non-bricking,**
but pointless — always use `sysupgrade.bin` for OpenWrt→OpenWrt. The footer is
inert on that path.

---

## 7. Paths forward (install without the webui)

Boot enforces no signature, so any image on an inactive A/B slot boots. Get bytes
onto the slot by:

1. **Serial RX → U-Boot → TFTP (best lead).** RX was assumed unexposed, but the
   MBE70WRT hit the identical "TX works, RX dead" symptom and it was **host-side
   flow control**, fixed with `tio --flow none` (RTS/CTS off) — *not* a missing
   line. Re-test with flow control disabled. If RX wakes: interrupt autoboot →
   `tftpboot` the initramfs `.itb` → boot OpenWrt in RAM → `dd` the factory
   halves to p30/p31 → flip BOOTCONFIG → reboot. Non-bricking (writes the
   inactive slot; auto_recovery falls back).
2. **Root shell on the vendor firmware** → same `dd`-to-slot method that worked on
   the MBE70WRT. Retail image ships no SSH/telnet, so this needs a separate
   vector — harder than option 1.

Both bypass `fwcc`/GPG completely and rely only on the (unenforced) boot path.

### A/B slot map (from the MBE70WRT teardown, same GPT)
```
p28 0:HLOS   8 MiB  (slot A kernel)   p29 rootfs   500 MiB (root=mmcblk0p29)
p30 0:HLOS_1 8 MiB  (slot B kernel)   p31 rootfs_1 500 MiB (root=mmcblk0p31)
```
BOOTCONFIG (p3/p4) primaryboot flags: offset 128 = HLOS, 148 = rootfs; 0=A, 1=B.
Helpers already in-tree: `mbe7000-bootslot`, and the A/B-aware `platform.sh`.

---

## 8. Key file references

- Verifier (shell): `usr/sbin/fwcc` (`verify_linksys_header`, `verify_signature_gpg`)
- eMMC flasher: `usr/sbin/update` (dd count=2 / skip=2 to inactive slot)
- Manual webui: `www/fwupdate.html` → `www/ui/cgi/jcgi.cgi` →
  `usr/local/lib/lua/5.1/firmware-update.lua` (`os.execute("update <file>")`,
  `ErrorSignatureCheckFailed`)
- OTA: `usr/sbin/fwupd` (binary), `etc/init.d/service_autofwup.sh`
- Gate files: `/etc/product.type`=`production`, `/etc/fwcaps.sig`=empty,
  `syscfg fwup_gpg_mode` (runtime; =1 on this unit)
- Our change: `target/linux/qualcommbe/image/ipq95xx.mk`
  (`Build/linksys-mbe7000-footer`, flat `IMAGE/factory.bin`)
