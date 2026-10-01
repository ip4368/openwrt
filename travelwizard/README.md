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

side switch ──> physical LAN jack joins Setup/direct or Vault/protected bridge
```

| SSID | Network | Zone | Path |
|---|---|---|---|
| `Travel-Setup` (+ wired LAN in direct position) | `lan` 192.168.40.1/24¹ | lan | direct to wan/wwan |
| `Travel-Vault` (+ wired LAN in protected position) | `vault` 10.20.30.1/24¹ | vault → vpn only | WireGuard / OpenVPN / sing-box TUN, else nothing |

¹ Defaults, editable in the wizard; `tw-subnet-fix` also re-addresses on
upstream overlap (see below). The wizard itself is always at
`http://secure.router` from the setup network —
`tw-subnet-fix` keeps that name on the current LAN address across moves
(no path needed: the wizard is the default LuCI landing page after login).
A "Need this page again later?" strip at the top of the wizard repeats the
setup SSID and address, with a Copy button.

Both SSIDs are broadcast on **both radios** (2.4 + 5 GHz) so 2.4-only clients
still get VPN. The upstream client (`wwan`) shares the first radio, which
follows the hotel channel; the other radio stays on its configured channel.

VPN modes (`travelwizard.main.vpn_mode`): `off | wireguard | openvpn | singbox`.
The `vpn` firewall zone statically matches all tunnel interfaces (`tw_wg`,
`tun_tw`, `tun0`); `tw-vpn-apply` only starts/stops tunnels and points the
`pbr` policy `vault-via-vpn` (vault subnet → tunnel) at the active one.
`tw-vpn-apply` also owns each tunnel's address in netifd (`vpntun` static),
so a network reload re-asserts it instead of flushing it and stalling the
vault. ICMP (ping) is dropped inside sing-box tunnels — some proxy
protocols can't carry it, and tunneling it only produced log spam;
TCP/UDP/DNS are unaffected.

## What's in the feed

- `feed/travelwizard/` — backend, no LuCI dependency, all script:
  - `files/etc/config/travelwizard` — wizard UCI (SSIDs, subnets, mode, WG/OVPN/proxy settings)
  - `files/usr/sbin/tw-wan-scan` — nearby Wi-Fi as JSON + current/saved upstream
  - `files/usr/sbin/tw-wan-join '<ssid>' '[key]'` — join upstream, then subnet-fix + portal lift; replies as soon as the link is up (the UI runs the captive check separately)
  - `files/usr/sbin/tw-subnet-fix` — overlap detect; re-addresses LAN/vault to a free /24 (and moves the pbr policy with it)
  - `files/usr/sbin/tw-captive-check` — `generate_204`-style probes → `online | captive | offline` + login URL; handles inline pages, absolute/relative redirects and HTTP 511
  - `files/usr/sbin/tw-sub-import '<url|link|->'` — subscription/single link → `/etc/sing-box/config.json`
    (vmess/vless/trojan/ss/naive/hysteria2/tuic/anytls, incl. base64 subs and reality/ws options; capped at 32 nodes;
    naive links are skipped when the installed sing-box build lacks the naive outbound).
    Also writes `.tags` (endpoint names) and `.map` (endpoint → source link) sidecars.
    Failed fetch attempts are logged to syslog (`logread | grep tw-sub-import`)
    with the curl exit code and HTTP status. A TLS failure on a fresh-boot
    clock waits for NTP (kicks ntpd, up to 90s) instead of failing, since
    the router has no RTC and every cert reads "not yet valid" until sync.
  - `files/usr/sbin/tw-probe '<profile>' '<endpoint>'` — full end-to-end latency
    test of one endpoint: a throwaway sing-box (loopback SOCKS, no TUN) fetches
    a probe URL through just that endpoint and reports ok/latency_ms (cold:
    first request incl. tunnel setup) plus warm_latency_ms (median of three
    more fetches, each a new connection with the tunnel already up)
  - `files/usr/sbin/tw-vpn-apply` — apply UCI mode: tunnels + pbr policy + vault DHCP DNS + service restarts
  - `files/usr/sbin/tw-vpn-health` — tunnel state + direct-vs-vault egress IPs + leak verdict
  - `files/usr/sbin/tw-wifi-apply` — rename/rekey both SSIDs on all radios
  - `files/usr/sbin/tw-upstream` — report/set preferred upstream (wifi/ethernet/auto) via route metrics
  - `files/usr/sbin/tw-lan-switch` — report/move the physical LAN jack between the direct and protected bridges
  - `files/usr/sbin/tw-time` — report the clock, set it from the browser, or restart internet-time synchronization
  - `files/usr/lib/travelwizard/common.sh` — upstream detect, IPv4 math, kill-switch audit, vault DNS/pbr helpers
  - `files/etc/uci-defaults/90-travelwizard` — first-boot network/wireless/firewall/dhcp layout
  - `files/etc/hotplug.d/iface/30-tw-subnet` — re-run subnet fix when upstream (re)connects
  - `files/etc/rc.button/BTN_0` + `files/etc/init.d/tw-lan-switch` — apply both side-switch positions and replay its physical state at boot
- `feed/luci-app-travelwizard/` — LuCI app: first menu entry, JSON API +
  standalone app-style UI (`wizard.htm`, no JS build step, no LuCI chrome):
  a tile dashboard where each tile opens one settings screen, plus an
  "Advanced" button back to full LuCI.

## The wizard UI

Home is a guided dashboard (mobile-first, responsive on desktop): a status
banner with the single next action ("Connect to Wi-Fi", "Open hotel
sign-in", "Turn on VPN"…), a 3-row setup checklist (Internet → Hotel
sign-in → VPN, each tappable), then tiles for every settings screen. Each
tile shows live status (green/amber/red dot + one-line preview):

- **Internet** — pick Wi-Fi vs cable (route metrics; cable preferred by
  default), with live link status for both, plus **Disconnect Wi-Fi**
  (`tw-wan-disconnect` drops the link and reports the SSID). **Scan &
  join** — `tw-wan-scan` lists networks by signal with band tags (deduped,
  secured flagged); each radio is scanned with retries plus a kernel-cache
  (`iw scan dump`) fallback, since a connected radio briefly refuses fresh
  scans — a band that still fails is flagged `partial` and the UI asks for
  a re-tap. Remembered networks the scan sees are listed first (connected,
  then strongest, with live signal and one-tap Connect); remembered ones
  out of range fold into a collapsible "Not nearby" group, and the Nearby
  list below holds only the rest, with phone-style signal bars.
  `tw-wan-join` places the client on the matching radio band, picks the
  WPA mode from scan data, then runs the subnet fix (auto re-address +
  notice in UI) and replies without waiting for the captive check (which
  could outlast uhttpd's 60 s timeout); the UI shows "checking" and asks
  `/captive` on its own. Joined networks are remembered
  (SSID + key, server-side only) for one-tap reconnect from the Remembered
  networks list, with Forget to drop one. Each remembered network also owns
  a random locally administered station MAC: reconnects reuse it, while
  forgetting and joining again creates a new one. These behaviors are
  configurable in the wizard: each remembered SSID can independently use its
  private or hardware MAC, or generate a fresh private MAC from its expanded
  options. Settings chooses the default for newly remembered networks, DHCPv4
  can omit or send a custom hostname, and its stable client identifier can be
  suppressed or restored to the OpenWrt default.
- **Hotel sign-in** — `tw-captive-check` probes
  `connectivitycheck.gstatic.com/generate_204` (+ Apple/MSFT/Huawei fallbacks). If a
  portal hijacks it, the screen shows numbered steps + **Open hotel sign-in**
  (the redirect target) + **Check again**, and keeps polling so it notices
  by itself once you finish the portal on another tab/device. HTTP 511 and
  relative redirects are treated as captive. A portal answer does not stop
  the fallbacks: if any probe gets genuine internet, the result is online, so
  a network that only filters one probe host is not mistaken for a portal.
  If every probe times out or otherwise fails, the screen explains what to
  try, offers a plain-HTTP **Try sign-in page** fallback, lists each probe's
  failure under Technical detail, and retries automatically.
- **VPN** — profiles: save as many as you like (pre-trip
  setup), switch with one click; only the active profile drives the vault
  network. Secrets never leave the router (blank field = keep). WireGuard
  paste-a-`.conf` auto-fill, OpenVPN paste-`.ovpn` + optional auth, proxy
  subscription URL or pasted links imported on save (vmess/vless/trojan/ss/naive/hysteria2/tuic/anytls,
  fetches retried for flaky hotel wifi, with a clear error when the server
  returns something else, e.g. Clash YAML or a login page). Each proxy
  profile lists its **servers** as a foldable
  group: pick the active one to connect (switching re-applies the live
  tunnel), **Test** any server for a full end-to-end latency probe
  (**Test all** runs the whole list, 3 at a time), and **Refresh** to
  re-fetch the subscription.
- **My Wi-Fi** — rename/rekey both SSIDs on all radios (tile warns while the
  default passwords are still in place), each with a scannable join QR
  (`tw-wifi-qr` + `/wifi_qr`, regenerated on save). This screen also shows
  whether the side switch currently places the wired LAN jack on the direct
  or protected network.
- **Settings** — controls the upstream Wi-Fi address, DHCP hostname and DHCP
  client identifier. It also shows router time beside the browser's time,
  retries NTP after a hotel sign-in, and can copy the browser's epoch to the
  router when captive access blocks NTP. A persistent timestamp prevents the
  next reboot from falling all the way back to the firmware build date.
  The defaults live under `travelwizard.main` in UCI, while each `savednet`
  section has its own `private_mac` option. After manual edits, run
  `tw-uplink-privacy` to apply them immediately (a Wi-Fi join also re-applies
  them automatically).
- **Setup portal** — while the router has no upstream link, `tw-portal`
  (driven by the wwan/wan hotplug hook, a boot init script, and a firewall
  include that survives `fw4` restarts) answers all DNS with the router IP
  (dnsmasq catch-all — without it phones never send the probes that trigger
  the popup), DNATs TCP/80 from the setup network to the router, and serves
  OS probe pages that bounce to the wizard — so a joining phone pops
  "Sign in to Wi-Fi" straight into setup. Deliberately offline-only: with
  a link up (even captive) the portal lifts (rules, DNS and all) so the
  hotel's own login page stays reachable. The probe pages send the popup to
  the wizard with a `#cna` marker; once the router is online, the wizard
  shows the way back (`http://secure.router`) and after an 8 s countdown
  (or **Finish now**) loads Apple's probe URL so iOS re-checks and offers
  Done. **Stay here** cancels the countdown and keeps a Finish banner.
- **Checkup** — `tw-vpn-health` verdict in plain words ("Protection is
  working", "VPN isn't working", "Safety lock is on"…), with IPs, vault DNS
  and the tunnel-routed DNS result folded under Technical details, plus a
  **Fix in VPN settings** button when something is wrong.
  `tw-vpn-apply` also warns when the tunnel is up but no route via it
  exists (pbr policy inactive).

## Build

### Option A — Docker on Mac: cached SDK + offline ImageBuilder

Our two packages are script-only, so instead of building the whole toolchain,
compile just them with the prebuilt SDK, then assemble the MT3000 image with
the prebuilt ImageBuilder. Both run as `linux/amd64` containers (emulated on
Apple Silicon). Their large `/builder` workspaces live in named Docker volumes,
so Docker does not copy and discard several GB on every invocation.

The workflow deliberately separates network access from normal iteration:

```sh
./travelwizard/build.sh prepare    # once, online: resolve/download/lock APKs
./travelwizard/build.sh            # thereafter, completely offline
# To update a release image intentionally:
PULL=1 ./travelwizard/build.sh prepare
# -> travelwizard/build/image/*-sysupgrade.bin
# -> travelwizard/build/ipk/*.apk
```

Notes:

- `prepare` is the only networked phase. It downloads the complete transitive
  APK closure into a local ImageBuilder repository, records every APK SHA-256,
  then proves that the same manifest resolves with Docker networking disabled.
- A normal build runs both the SDK and ImageBuilder with `--network none`. It
  removes stale local APK releases, rebuilds whichever of the two packages
  changed, and replaces only those APKs in the prepared repository.
- ImageBuilder still performs its normal clean rootfs install, all staged
  post-install scripts, service enablement, SquashFS generation, metadata and
  checksums. We intentionally do not patch a previously compressed image.
- After assembly, the script compares every file from both local packages with
  the finalized image root, checks their exact versions in the image manifest,
  and checks that both TravelWizard init services were enabled. The output also
  includes the manifest, SBOM, dependency lock and build provenance.
- The cache key includes the OpenWrt release, profile, ImageBuilder image ID,
  requested package set and both local packages' dependency declarations. A
  relevant change fails closed and asks for another explicit `prepare`.
- Release 25.x uses `.apk` packages; base system comes from the release tag,
  not this tree — fine, since our packages only rely on stable interfaces
  (UCI, firewall4 zones, netifd).
- Verified 2026-09-22 with `v25.12.5`: manifest resolves all names, image
  builds (~24 MB, vs ~9.5 MB stock — almost all of it sing-box), and the
  assembled rootfs contains all `tw-*` helpers, the `90-travelwizard` and
  `91-travelwizard-uplink-privacy` defaults, the LuCI controller/view, plus
  `sing-box`, `openvpn`, `pbr`, `wg`, `curl`, `iwinfo`, `jsonfilter`.

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
- **The side switch selects the wired LAN path.** Its high/`pressed` position
  adds the GL-MT3000 LAN jack (`eth1`) to `br-vault`; its low/`released`
  position returns it to `br-lan`. The helper persists the bridge membership,
  reloads netifd and bounces the physical link so the attached device renews
  DHCP. A late init hook replays the real switch position on every boot.
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
- **Port 53 is hijacked into sing-box DNS-over-TCP through the proxy**,
  so vault DNS keeps working even where UDP is filtered. Direct UDP also
  works through all proxy types (VLESS Vision included, via XUDP when the
  server supports it) — the importer deliberately emits no `"network"`
  limiter on outbounds, which would disable UDP outright.
- **Ethernet WAN** works as upstream automatically (metric preferred over
  Wi-Fi); the wizard's join/captive logic targets whichever upstream is up.

## Verify on device (after flashing)

```sh
tw-wan-scan | jsonfilter -e '@.networks[*].ssid'
tw-wan-join 'Hotel_WiFi' 'secret'   # then check the wizard UI too
tw-captive-check
tw-time status
tw-sub-import 'https://example.com/sub'   # or a single 'vless://…' link
tw-probe 'p1_xxx' 'endpoint name'   # full latency test of one endpoint
tw-lan-switch status                # direct or protected wired LAN
uci set travelwizard.main.vpn_mode='singbox'; uci commit; tw-vpn-apply
tw-vpn-health
```

Then: join `Travel-Vault` from a phone and confirm the egress IP differs from
`Travel-Setup`'s; stop the tunnel (`vpn_mode=off` + apply) and confirm the
vault has no route at all. Flip the side switch in each direction and confirm
`tw-lan-switch status` changes between `direct` and `protected`; a wired client
should renew into the matching subnet and obey the same egress/kill-switch
rules as that network's Wi-Fi clients.
