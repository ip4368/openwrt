# TravelWizard — single-purpose travel-router firmware (GL-MT3000)

A custom OpenWrt image that turns the GL.iNet GL-MT3000 into a one-job device:
join any hotel/home Wi-Fi (or ethernet), then broadcast a private hotspot whose
traffic always goes through your VPN/proxy — or nowhere at all.

End users only ever see the **Setup Wizard**. Full LuCI stays available behind
an "Advanced" link.

This directory is self-contained: it is the only thing added to the OpenWrt
tree (registered as a `src-link` feed in the git-ignored `feeds.conf`), so it
can later move to its own repository unchanged.

```
travelwizard/
  README.md            this file
  mt3000.diffconfig    image config for the full-buildroot path
  build.sh             Docker build: SDK packages + ImageBuilder image (REL=...)
  feed/                OpenWrt feed: travelwizard, luci-app-travelwizard
  tests/               plain-sh regression tests (run: sh tests/test-*.sh)
  build/               local-only output (git-excluded): ipk/, image/
```

## Network design

```
hotel Wi-Fi ──(sta: wwan)──┐                      ┌── Travel-Setup (mgmt, direct)
                           ├─ GL-MT3000 ──wifi───┤
ethernet WAN ──(wan)───────┘                      └── Travel-Vault (proxied, kill-switched)
                                                          │
                                              pbr: vault subnet ──> tunnel only
                                              firewall: NO vault->wan forwarding
                                              (wan zone forward pinned to REJECT)
```

| SSID | Network | Zone | Path |
|---|---|---|---|
| `Travel-Setup` (+ wired LAN) | `lan` 192.168.40.1/24¹ | lan | direct to wan/wwan |
| `Travel-Vault` | `vault` 10.20.30.1/24¹ | vault → vpn only | WireGuard / OpenVPN / sing-box TUN, else nothing |

¹ Defaults, editable in the wizard; `tw-subnet-fix` also re-addresses on
upstream overlap (see below).

Both SSIDs are broadcast on **both radios** (2.4 + 5 GHz) so 2.4-only clients
still get VPN. The upstream client (`wwan`) shares the first radio, which
follows the hotel channel; the other radio stays on its configured channel.

VPN modes (`travelwizard.main.vpn_mode`): `off | wireguard | openvpn | singbox`.
The `vpn` firewall zone statically matches all tunnel interfaces (`tw_wg`,
`tun_tw`, `tun0`); `tw-vpn-apply` only starts/stops tunnels and points the
`pbr` policy `vault-via-vpn` (vault subnet → tunnel) at the active one.

## What's in the feed

- `feed/travelwizard/` — backend, no LuCI dependency, all script:
  - `files/etc/config/travelwizard` — wizard UCI (SSIDs, subnets, mode, WG/OVPN/proxy settings)
  - `files/usr/sbin/tw-wan-scan` — nearby Wi-Fi as JSON + current/saved upstream
  - `files/usr/sbin/tw-wan-join '<ssid>' '[key]'` — join upstream, then subnet-fix + captive check
  - `files/usr/sbin/tw-subnet-fix` — overlap detect; re-addresses LAN/vault to a free /24 (and moves the pbr policy with it)
  - `files/usr/sbin/tw-captive-check` — `generate_204`-style probes → `online | captive | offline` + login URL
  - `files/usr/sbin/tw-sub-import '<url|link|->'` — subscription/single link → `/etc/sing-box/config.json`
    (vmess/vless/trojan/ss, incl. base64 subs and reality/ws options; capped at 32 nodes)
  - `files/usr/sbin/tw-vpn-apply` — apply UCI mode: tunnels + pbr policy + vault DHCP DNS + service restarts
  - `files/usr/sbin/tw-vpn-health` — tunnel state + direct-vs-vault egress IPs + leak verdict
  - `files/usr/sbin/tw-wifi-apply` — rename/rekey both SSIDs on all radios
  - `files/usr/sbin/tw-upstream` — report/set preferred upstream (wifi/ethernet/auto) via route metrics
  - `files/usr/lib/travelwizard/common.sh` — upstream detect, IPv4 math, kill-switch audit, vault DNS/pbr helpers
  - `files/etc/uci-defaults/90-travelwizard` — first-boot network/wireless/firewall/dhcp layout
  - `files/etc/hotplug.d/iface/30-tw-subnet` — re-run subnet fix when upstream (re)connects
- `feed/luci-app-travelwizard/` — LuCI app: first menu entry, JSON API +
  4-step mobile-first wizard (`wizard.htm`, no JS build step), "Advanced" link
  back to full LuCI.

## The wizard flow

1. **Upstream** — pick Wi-Fi vs cable (route metrics; cable preferred by
   default), with live link status for both. **Scan & join** — `tw-wan-scan`
   lists networks by signal with band tags (deduped, secured flagged); shows
   connected + last-used network. `tw-wan-join` places the client on the
   matching radio band, picks the WPA mode from scan data, then runs the
   subnet fix (auto re-address + notice in UI) and the captive check.
2. **Internet / captive** — `tw-captive-check` probes
   `connectivitycheck.gstatic.com/generate_204` (+ Apple/MSFT fallbacks). If a
   portal hijacks it, the wizard shows **Open login page** (the redirect
   target) + **Check again**.
3. **VPN profiles** — save as many as you like (pre-trip setup), switch with
   one click; only the active profile drives the vault network. Secrets never
   leave the router (blank field = keep). WireGuard paste-a-`.conf` auto-fill,
   OpenVPN paste-`.ovpn` + optional auth, proxy subscription URL or pasted
   links imported on save (vmess/vless/trojan/ss, with a clear error when the
   server returns something else, e.g. Clash YAML or a login page).
4. **Verify** — `tw-vpn-health`: handshake/process state, direct vs vault
   egress IP, `healthy | down | no-egress | leaking | disabled` verdict.

Plus an unnumbered **Wi-Fi names & passwords** section to rename/rekey both
SSIDs on all radios.

## Build

### Option A — Docker on Mac: SDK + ImageBuilder (fast, no toolchain build)

Our two packages are script-only, so instead of building the whole toolchain,
compile just them with the prebuilt SDK, then assemble the MT3000 image with
the prebuilt ImageBuilder. Both run as `linux/amd64` containers (emulated on
Apple Silicon, but packaging-only work so still quick).

```sh
./travelwizard/build.sh            # or: REL=v25.12.5 ./travelwizard/build.sh
# -> travelwizard/build/image/*-sysupgrade.bin
# -> travelwizard/build/ipk/*.apk
```

Notes:

- The script mounts `feed/` into the SDK at `/builder/package/` and drops the
  resulting `.apk` files into the ImageBuilder's `packages/` dir (re-indexed
  automatically). All other packages are fetched from `downloads.openwrt.org`.
- Release 25.x uses `.apk` packages; base system comes from the release tag,
  not this tree — fine, since our packages only rely on stable interfaces
  (UCI, firewall4 zones, netifd).
- Validate the package set without building (fast, catches typos) with
  `make manifest PROFILE="glinet_gl-mt3000" PACKAGES="<list from build.sh>"`
  inside the ImageBuilder container.
- Verified 2026-09-22 with `v25.12.5`: manifest resolves all names, image
  builds (~24 MB, vs ~9.5 MB stock — almost all of it sing-box), and the
  assembled rootfs contains all `tw-*` helpers, `90-travelwizard`, the LuCI
  controller/view, plus `sing-box`, `openvpn`, `pbr`, `wg`, `curl`, `iwinfo`,
  `jsonfilter`.

### Option B — full buildroot on a Linux host

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
cp travelwizard/mt3000.diffconfig .config
make defconfig
make -j"$(nproc)"
# -> bin/targets/mediatek/filogic/*glinet_gl-mt3000*-sysupgrade.bin
```

This requires the `travelwizard` feed registered (append to `feeds.conf`):

```sh
cp feeds.conf.default feeds.conf   # feeds.conf is git-ignored (local only)
echo "src-link travelwizard $PWD/travelwizard/feed" >> feeds.conf
```

## Flash

Flash from the stock GL.iNet web UI (System → Upgrade, **uncheck** "keep
settings" the first time) or via U-Boot recovery. Default Wi-Fi keys are
`travel-setup-please-change` / `travel-vault-please-change` — change them in
the wizard's Wi-Fi section on first login.

## Deliberate decisions / limits (v1)

- **sing-box, not full v2rayA, in the default image.** The requirement was
  "subscription + single endpoint", which `tw-sub-import` covers at a fraction
  of the flash/RAM cost, with one TUN interface that the kill switch can reason
  about. If you want v2rayA's full UI later, add the `v2raya-openwrt` feed and
  its packages to `build.sh`/`mt3000.diffconfig`; the vault policy route works
  with any TUN device.
- **No side-switch support in v1** — the two SSIDs already give you
  VPN-or-nothing vs direct. The DTS exposes it (`mode`/`BTN_0`), so a later
  `tw-vpn-toggle` + hotplug on `BTN_0` is a small addition.
- **pbr does the policy routing.** Hand-rolled rules/tables for three tunnel
  types is where leaks hide; pbr watches tunnel state and we add one policy.
  If pbr is missing, `tw-vpn-apply` says so instead of pretending.
- **DNS for vault never touches the router.** dnsmasq resolves over the direct
  upstream, so vault clients instead get public resolvers via DHCP option 6
  (`travelwizard.main.vault_dns`, default `1.1.1.1 9.9.9.9`; an active
  WireGuard profile's `dns` wins). Those queries are ordinary forwarded
  traffic: pbr carries them into the tunnel, and the kill switch drops them
  when it is down. The firewall only accepts DHCP from vault to the router.
- **The sing-box selector has no `direct` member**, only imported servers, so
  vault traffic entering `tun0` can't be switched to an unproxied exit.
- **Ethernet WAN** works as upstream automatically (metric preferred over
  Wi-Fi); the wizard's join/captive logic targets whichever upstream is up.

## Verify on device (after flashing)

```sh
tw-wan-scan | jsonfilter -e '@.networks[*].ssid'
tw-wan-join 'Hotel_WiFi' 'secret'   # then check the wizard UI too
tw-captive-check
tw-sub-import 'https://example.com/sub'   # or a single 'vless://…' link
uci set travelwizard.main.vpn_mode='singbox'; uci commit; tw-vpn-apply
tw-vpn-health
```

Then: join `Travel-Vault` from a phone and confirm the egress IP differs from
`Travel-Setup`'s; stop the tunnel (`vpn_mode=off` + apply) and confirm the
vault has no route at all.
