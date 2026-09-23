#!/bin/sh
# Regression test: scan-interface discovery must work with any kernel Wi-Fi
# naming (phyX-apY on modern OpenWrt, wlanX on older builds). The wizard
# once showed empty scan results because discovery hardcoded /sys/class/net/wlan*.
# No framework: plain sh + fixtures. Run: sh travelwizard/tests/test-scan-discovery.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"

PASS=0
ok() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SYS="$TMP/sys"
mkdir -p "$SYS"/phy0-ap0 "$SYS"/phy0-ap1 "$SYS"/phy1-ap0 "$SYS"/wlan0 "$SYS"/eth0 "$SYS"/lo "$SYS"/fake0
# phy80211 topology: phy0-ap0+phy0-ap1 share radio phy0, rest are separate.
ln -s ../../ieee80211/phy0 "$SYS/phy0-ap0/phy80211"
ln -s ../../ieee80211/phy0 "$SYS/phy0-ap1/phy80211"
ln -s ../../ieee80211/phy1 "$SYS/phy1-ap0/phy80211"
ln -s ../../ieee80211/phy2 "$SYS/wlan0/phy80211"
# Stub iwinfo: Wi-Fi ifaces print wireless output; fake0 mimics the real
# iwinfo quirk of exiting 0 with a usage blurb for non-Wi-Fi ifaces.
cat >"$TMP/iwinfo" <<'EOF'
#!/bin/sh
case "$1" in
	phy0-ap0|phy0-ap1|phy1-ap0|wlan0) echo "ESSID: \"stub\""; exit 0 ;;
	fake0) echo "Usage:"; exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$TMP/iwinfo"

OUT=$(tw_scan_ifs "$SYS" "$TMP/iwinfo")
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 3 ] || fail "expected 3 ifaces, got: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q '^phy1-ap0$' || fail "phy1-ap0 missing: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q '^wlan0$' || fail "wlan0 missing: [$OUT]"
ok
[ "$(printf '%s\n' "$OUT" | grep -c '^phy0-ap')" -eq 1 ] \
	|| fail "expected exactly one phy0 iface: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -qE '^(eth0|lo)$' && fail "non-WiFi leaked in: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q '^fake0$' && fail "exit-0 usage-blurb iface leaked in: [$OUT]"
ok

# Empty / Wi-Fi-less trees yield nothing (and never a literal glob).
SYS_EMPTY="$TMP/empty"; mkdir -p "$SYS_EMPTY"
[ -z "$(tw_scan_ifs "$SYS_EMPTY" "$TMP/iwinfo")" ] || fail "empty dir gave output"
ok
SYS_NOWIFI="$TMP/nowifi"; mkdir -p "$SYS_NOWIFI"/eth0 "$SYS_NOWIFI"/lo
[ -z "$(tw_scan_ifs "$SYS_NOWIFI" "$TMP/iwinfo")" ] || fail "non-WiFi dir gave output"
ok

echo "PASS: scan discovery ($PASS assertions)"
