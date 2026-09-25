#!/bin/sh
# A connected radio briefly refuses scans (wpa_supplicant holds it: EBUSY),
# so a single attempt per radio drops the whole band from the UI. tw_scan_one
# must retry; tw-wan-scan must flag unrecoverable gaps with partial=true.
# Run: sh travelwizard/tests/test-scan-retry.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"

PASS=0
ok() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# --- unit: tw_scan_one retries a flaky radio -------------------------------
cat >"$TMP/bin/flaky" <<'EOF'
#!/bin/sh
# $2 is the iface; fails $FAIL_N times, then prints one cell.
c=$(cat "$CNT" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" >"$CNT"
[ "$c" -le "${FAIL_N:-0}" ] && exit 0
printf 'Cell 01 - Address: AA:BB:CC:DD:EE:FF\n          ESSID: "Won"\n'
EOF
chmod +x "$TMP/bin/flaky"
export TW_SCAN_SLEEP=0 CNT="$TMP/cnt"

FAIL_N=2; export FAIL_N
rm -f "$CNT"
OUT=$(TW_SCAN_RETRIES=3 tw_scan_one phy1-ap0 "$TMP/bin/flaky") \
	|| fail "flaky radio should recover"
case "$OUT" in *Won*) ok ;; *) fail "expected cell output, got: [$OUT]" ;; esac
[ "$(cat "$CNT")" = "3" ] || fail "expected 3 attempts, got $(cat "$CNT")"
ok

FAIL_N=9; export FAIL_N
rm -f "$CNT"
TW_SCAN_RETRIES=3 tw_scan_one phy1-ap0 "$TMP/bin/flaky" >/dev/null 2>&1 \
	&& fail "dead radio should fail"
ok
[ "$(cat "$CNT")" = "3" ] || fail "expected 3 attempts, got $(cat "$CNT")"
ok

# --- e2e: tw-wan-scan merges + reports partial ------------------------------
SYS="$TMP/sys"
FIX="$TMP/fixtures"
mkdir -p "$SYS"/phy0-ap0 "$SYS"/phy1-ap0 "$FIX"
ln -s ../../ieee80211/phy0 "$SYS/phy0-ap0/phy80211"
ln -s ../../ieee80211/phy1 "$SYS/phy1-ap0/phy80211"
# NOTE: fixtures live outside $SYS: discovery scans that dir, so stray
# files in it would be probed as interfaces.
cat >"$FIX/cell2g" <<'EOF'
Cell 01 - Address: AA:BB:CC:DD:EE:01
          ESSID: "Cafe2G"
          Mode: Master  Channel: 6
          Signal: -70 dBm
          Encryption: none
Cell 02 - Address: AA:BB:CC:DD:EE:02
          ESSID: "Hotel2G"
          Mode: Master  Channel: 1
          Signal: -60 dBm
          Encryption: WPA2 PSK
EOF
cat >"$FIX/cell5g" <<'EOF'
Cell 01 - Address: AA:BB:CC:DD:EE:03
          ESSID: "Hotel5G"
          Mode: Master  Channel: 48
          Signal: -52 dBm
          Encryption: WPA2 PSK
EOF
cat >"$TMP/bin/iwinfo" <<'EOF'
#!/bin/sh
if [ "$2" = "info" ]; then echo 'ESSID: "stub"'; exit 0; fi
# scan: 2.4 GHz always answers; 5 GHz fails $FAIL_N times first.
[ "$1" = "phy0-ap0" ] && { cat "$FIX/cell2g"; exit 0; }
c=$(cat "$CNT" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" >"$CNT"
[ "$c" -le "${FAIL_N:-0}" ] && exit 0
cat "$FIX/cell5g"
EOF
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP/bin/"*
# Stub jshn.sh: log the calls (not real JSON) for assertions.
cat >"$TMP/jshn.sh" <<'EOF'
json_init() { : >"$JSON_LOG"; }
json_add_string() { echo "string $1=$2" >>"$JSON_LOG"; }
json_add_boolean() { echo "boolean $1=$2" >>"$JSON_LOG"; }
json_add_int() { echo "int $1=$2" >>"$JSON_LOG"; }
json_add_array() { echo "array $1" >>"$JSON_LOG"; }
json_add_object() { echo "object" >>"$JSON_LOG"; }
json_close_object() { :; }
json_close_array() { :; }
json_dump() { cat "$JSON_LOG"; }
EOF
export SYS FIX JSON_LOG="$TMP/json.log"
export TW_SCAN_SYSFS="$SYS" TW_JSHN="$TMP/jshn.sh"
export TW_COMMON="$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"
export TW_SCAN_RETRIES=3
PATH="$TMP/bin:$PATH"; export PATH

FAIL_N=2; export FAIL_N
rm -f "$CNT"
OUT=$(sh "$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-scan") \
	|| fail "scan script failed"
[ "$(printf '%s\n' "$OUT" | grep 'string ssid=' | grep -vc 'string ssid=$')" = "3" ] \
	|| fail "expected 3 merged SSIDs, got: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q 'string ssid=Hotel5G' || fail "5G net missing: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q 'boolean partial=0' || fail "partial should be 0: [$OUT]"
ok

FAIL_N=9; export FAIL_N
rm -f "$CNT"
OUT=$(sh "$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-scan") \
	|| fail "scan script failed"
[ "$(printf '%s\n' "$OUT" | grep 'string ssid=' | grep -vc 'string ssid=$')" = "2" ] \
	|| fail "expected 2 SSIDs, got: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q 'boolean partial=1' || fail "partial should be 1: [$OUT]"
ok

# --- iw dump converter -----------------------------------------------------
# Real `iw scan dump` shape (tab-indented): mixed PSK+SAE, open, hidden EAP,
# SAE-only across 2.4/5 GHz.
printf '%s\n' \
'BSS aa:bb:cc:dd:ee:01(on phy1-ap0)' \
'	freq: 5240.0' \
'	capability: ESS (0x1111)' \
'	signal: -52.00 dBm' \
'	SSID: Hotel5G' \
'	RSN:' \
'		 * Authentication suites: PSK SAE' \
'BSS aa:bb:cc:dd:ee:02(on phy0-ap0)' \
'	freq: 2412.0' \
'	capability: ESS (0x0001)' \
'	signal: -70.00 dBm' \
'	SSID: Cafe2G' \
'BSS aa:bb:cc:dd:ee:03(on phy1-ap0)' \
'	freq: 5180.0' \
'	capability: ESS (0x1011)' \
'	signal: -80.00 dBm' \
'	RSN:' \
'		 * Authentication suites: 802.1X' \
'BSS aa:bb:cc:dd:ee:04(on phy1-ap0)' \
'	freq: 5745.0' \
'	capability: ESS (0x1011)' \
'	signal: -60.00 dBm' \
'	SSID: HomeSAE' \
'	RSN:' \
'		 * Authentication suites: SAE' >"$TMP/dump.txt"
CELLS=$(tw_scan_dump_conv <"$TMP/dump.txt")
[ "$(printf '%s\n' "$CELLS" | grep -c '^Cell')" = "4" ] \
	|| fail "expected 4 cells, got: [$CELLS]"
ok
printf '%s\n' "$CELLS" | grep -q 'ESSID: "Hotel5G"' || fail "Hotel5G missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Channel: 48' || fail "chan 48 missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Encryption: WPA2 PSK+SAE' || fail "mixed enc missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Signal: -52 dBm' || fail "signal -52 missing"
ok
printf '%s\n' "$CELLS" | grep -q 'ESSID: "Cafe2G"' || fail "Cafe2G missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Channel: 1$' || fail "chan 1 missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Encryption: none' || fail "open enc missing"
ok
printf '%s\n' "$CELLS" | grep -q 'ESSID: "(hidden) aa:bb:cc:dd:ee:03"' \
	|| fail "hidden convention missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Encryption: WPA2-EAP' || fail "eap enc missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Channel: 149' || fail "chan 149 missing"
ok
printf '%s\n' "$CELLS" | grep -q 'Encryption: SAE' || fail "sae enc missing"
ok
[ -z "$(tw_scan_dump_conv </dev/null)" ] || fail "empty dump gave output"
ok

# non-ASCII names: iw prints UTF-8 bytes, a backslash and edge spaces as
# \xHH; they must come back as the raw bytes iwinfo would show
printf '%s\n' \
'BSS aa:bb:cc:dd:ee:05(on phy0-ap0)' \
'	freq: 2437.0' \
'	capability: ESS (0x0001)' \
'	signal: -61.00 dBm' \
'	SSID: Caf\xc3\xa9 \xe6\x97\x85\xe9\xa4\xa8\x20' \
'BSS aa:bb:cc:dd:ee:06(on phy0-ap0)' \
'	freq: 2437.0' \
'	capability: ESS (0x0001)' \
'	signal: -62.00 dBm' \
'	SSID: back\x5cslash 100%' >"$TMP/dump-utf8.txt"
CELLS=$(tw_scan_dump_conv <"$TMP/dump-utf8.txt")
WANT=$(printf 'ESSID: "Caf\303\251 \346\227\205\351\244\250 "')
printf '%s\n' "$CELLS" | grep -qF "$WANT" || fail "utf-8 name not decoded: [$CELLS]"
ok
printf '%s\n' "$CELLS" | grep -qF 'ESSID: "back\slash 100%"' \
	|| fail "backslash/percent name mangled: [$CELLS]"
ok

# --- tw_scan_one falls back to dump, then fails clean ----------------------
cat >"$TMP/bin/iw" <<'EOF'
#!/bin/sh
[ "$2" = "scan" ] && [ "$3" = "dump" ] && cat "$DUMP_FIX"
EOF
chmod +x "$TMP/bin/iw"
export DUMP_FIX="$TMP/dump.txt"
FAIL_N=9; export FAIL_N
rm -f "$CNT"
OUT=$(TW_SCAN_RETRIES=2 tw_scan_one phy1-ap0 "$TMP/bin/flaky" "$TMP/bin/iw") \
	|| fail "dump fallback should recover"
printf '%s\n' "$OUT" | grep -q '^Cell' || fail "no cells from dump: [$OUT]"
ok
# the cache is consulted before paying for a second trigger
[ "$(cat "$CNT")" = "1" ] || fail "expected 1 trigger attempt, got $(cat "$CNT")"
ok
rm -f "$CNT"
OUT=$(TW_SCAN_RETRIES=2 tw_scan_one phy1-ap0 "$TMP/bin/flaky" "$TMP/bin/false-iw" 2>/dev/null) \
	&& fail "dead radio + dead dump should fail"
[ -z "$OUT" ] || fail "expected no output, got: [$OUT]"
ok

# --- e2e: dead trigger + live dump still yields the band, not partial ------
FAIL_N=9; export FAIL_N
rm -f "$CNT"
OUT=$(sh "$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-scan") \
	|| fail "scan script failed"
printf '%s\n' "$OUT" | grep -q 'string ssid=Hotel5G' || fail "5G via dump missing: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q 'string band=5g' || fail "dump band wrong: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q 'boolean partial=0' || fail "partial should be 0: [$OUT]"
ok

# --- e2e: names with the old field separator and quotes survive the merge --
cat >"$FIX/cell2g" <<'EOF'
Cell 01 - Address: AA:BB:CC:DD:EE:07
          ESSID: "Cafe | Guest"
          Mode: Master  Channel: 6
          Signal: -58 dBm
          Encryption: WPA2 PSK
Cell 02 - Address: AA:BB:CC:DD:EE:08
          ESSID: "Joe's "Fast" Net"
          Mode: Master  Channel: 11
          Signal: -66 dBm
          Encryption: none
EOF
FAIL_N=0; export FAIL_N
rm -f "$CNT"
OUT=$(sh "$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-scan") \
	|| fail "scan script failed"
printf '%s\n' "$OUT" | grep -qxF 'string ssid=Cafe | Guest' || fail "pipe name split: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -qxF 'string bssid=AA:BB:CC:DD:EE:07' || fail "pipe name shifted bssid: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -qxF 'string ssid=Joe'"'"'s "Fast" Net' || fail "quoted name cut: [$OUT]"
ok

# --- e2e: radios scan in parallel, so the wait is the slowest radio -------
cat >"$TMP/bin/iwinfo" <<'EOF'
#!/bin/sh
if [ "$2" = "info" ]; then echo 'ESSID: "stub"'; exit 0; fi
sleep 2
[ "$1" = "phy0-ap0" ] && { cat "$FIX/cell2g"; exit 0; }
cat "$FIX/cell5g"
EOF
chmod +x "$TMP/bin/iwinfo"
T0=$(date +%s)
OUT=$(sh "$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-scan") || fail "scan script failed"
T1=$(date +%s)
[ $((T1 - T0)) -lt 4 ] || fail "radios scanned one after another ($((T1 - T0))s)"
ok
printf '%s\n' "$OUT" | grep -q 'string ssid=Hotel5G' || fail "5G missing in parallel scan: [$OUT]"
ok

echo "PASS: scan retry ($PASS assertions)"
