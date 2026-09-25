#!/bin/sh
# Tests tw_saved_upsert: add/update keyed by SSID (values with spaces
# round-trip), empty SSID rejected, 16-entry cap with oldest-first prune;
# tw_saved_record_wwan: remembers the live wwan uplink.
# Run: sh travelwizard/tests/test-saved-wifi.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
STUB_UCI="$TMP/uci-state"; export STUB_UCI
: >"$STUB_UCI"
echo 0 >"$TMP/add-counter"
echo 1000 >"$TMP/now"
STUB_NOW="$TMP/now"; export STUB_NOW
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
# stateful stub over $STUB_UCI (key=value lines, values unquoted)
ST="$STUB_UCI"
case "$1" in
	show) grep "^$2\." "$ST" 2>/dev/null; exit 0 ;;
	-q)
		case "$2" in
			get) grep -F "$3=" "$ST" | head -n 1 | sed 's/^[^=]*=//'; exit 0 ;;
			delete) grep -v "^$3[.=]" "$ST" >"$ST.tmp"; mv "$ST.tmp" "$ST"; exit 0 ;;
		esac
		exit 1 ;;
	set)
		k=${2%%=*}; v=${2#*=}
		grep -v -F "$k=" "$ST" >"$ST.tmp" 2>/dev/null; mv "$ST.tmp" "$ST"
		printf '%s=%s\n' "$k" "$v" >>"$ST"
		exit 0 ;;
	add)
		n=$(cat "$STUB_UCI.counter"); echo $((n + 1)) >"$STUB_UCI.counter"
		printf 'travelwizard.cfg%s=%s\n' "$n" "$3" >>"$ST"
		echo "cfg$n"; exit 0 ;;
	commit) exit 0 ;;
esac
exit 1
EOF
cat >"$TMP/bin/date" <<'EOF'
#!/bin/sh
# fake clock: prints $STUB_NOW, then ticks one second
n=$(cat "$STUB_NOW"); echo "$n"; echo $((n + 1)) >"$STUB_NOW"
EOF
chmod +x "$TMP/bin/uci" "$TMP/bin/date"
cp "$TMP/add-counter" "$STUB_UCI.counter"
PATH="$TMP/bin:$PATH"; export PATH

count_saved() { uci show travelwizard | grep -c '=savednet'; }
ssid_of() { uci -q get "travelwizard.$1.ssid"; }

# 1. new entry stores every field and stays silent
out=$(tw_saved_upsert "Hotel_WiFi" "s3cret key" "5g" "WPA2-PSK" "aa:bb:cc:dd:ee:01")
check new-silent "$out" ""
SEC=$(uci show travelwizard | sed -n 's/^travelwizard\.\([^.]*\)=savednet/\1/p' | head -n 1)
check new-ssid "$(uci -q get "travelwizard.$SEC.ssid")" "Hotel_WiFi"
check new-key "$(uci -q get "travelwizard.$SEC.key")" "s3cret key"
check new-band "$(uci -q get "travelwizard.$SEC.band")" "5g"
check new-enc "$(uci -q get "travelwizard.$SEC.enc")" "WPA2-PSK"
check new-bssid "$(uci -q get "travelwizard.$SEC.bssid")" "aa:bb:cc:dd:ee:01"
check new-ts "$(uci -q get "travelwizard.$SEC.last_used")" "1000"

# 2. same SSID updates in place (new key, newer timestamp, no duplicate)
tw_saved_upsert "Hotel_WiFi" "rotated" "2g" "WPA2-PSK" ""
check update-count "$(count_saved)" "1"
check update-key "$(uci -q get "travelwizard.$SEC.key")" "rotated"
check update-ts "$(uci -q get "travelwizard.$SEC.last_used")" "1001"

# 3. SSIDs with spaces round-trip
tw_saved_upsert "My Hotel Guest" "" "2g" "none" ""
check space-count "$(count_saved)" "2"

# 4. empty SSID is rejected
tw_saved_upsert "" "x" "" "" "" && got=yes || got=no
check empty-rejected "$got" "no"
check empty-count "$(count_saved)" "2"

# 5. entries without a timestamp prune first when the cap hits
OLDCFG=$(uci add travelwizard savednet)
uci set "travelwizard.$OLDCFG.ssid=Ancient"
i=0
while [ "$i" -lt 14 ]; do
	tw_saved_upsert "net-$i" "k$i" "" "" ""
	i=$((i + 1))
done
check cap-count "$(count_saved)" "16"
check cap-pruned-oldest "$(ssid_of "$OLDCFG" 2>/dev/null)" ""
check cap-kept-first "$(uci show travelwizard | grep -c 'ssid=Hotel_WiFi$')" "1"

# 6. past the cap, the oldest timestamped entry goes next
tw_saved_upsert "net-new" "k" "" "" ""
check cap2-count "$(count_saved)" "16"
check cap2-pruned "$(uci show travelwizard | grep -c 'ssid=Hotel_WiFi$')" "0"
check cap2-kept "$(uci show travelwizard | grep -c 'ssid=net-new$')" "1"

# 7. the live wwan uplink is recorded with its radio's band and uci encryption
: >"$STUB_UCI"
uci set wireless.wwan.ssid=Cafe
uci set wireless.wwan.key=latte123
uci set wireless.wwan.encryption=psk2
uci set wireless.wwan.device=radio1
uci set wireless.radio1.band=5g
tw_saved_record_wwan && got=yes || got=no
check wwan-new "$got" "yes"
SEC=$(uci show travelwizard | sed -n 's/^travelwizard\.\([^.]*\)=savednet/\1/p' | head -n 1)
check wwan-ssid "$(ssid_of "$SEC")" "Cafe"
check wwan-key "$(uci -q get "travelwizard.$SEC.key")" "latte123"
check wwan-band "$(uci -q get "travelwizard.$SEC.band")" "5g"
check wwan-enc "$(uci -q get "travelwizard.$SEC.enc")" "psk2"

# 8. an entry already there only gets the current key and a fresh timestamp
uci set "travelwizard.$SEC.band=2g"
uci set wireless.wwan.key=espresso
TS=$(uci -q get "travelwizard.$SEC.last_used")
tw_saved_record_wwan
check wwan-upd-count "$(count_saved)" "1"
check wwan-upd-key "$(uci -q get "travelwizard.$SEC.key")" "espresso"
check wwan-upd-band "$(uci -q get "travelwizard.$SEC.band")" "2g"
[ "$(uci -q get "travelwizard.$SEC.last_used")" -gt "$TS" ] && got=yes || got=no
check wwan-upd-ts "$got" "yes"

# 9. no wwan network configured: nothing to record
uci -q delete wireless.wwan
tw_saved_record_wwan && got=yes || got=no
check wwan-none "$got" "no"
check wwan-none-count "$(count_saved)" "1"

echo "PASS: saved wifi ($PASS assertions)"
