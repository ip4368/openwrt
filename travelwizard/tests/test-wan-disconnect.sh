#!/bin/sh
# Tests tw-wan-disconnect: disables the sta iface, reloads its radio, and
# reports the dropped SSID (empty SSID when never joined).
# Run: sh travelwizard/tests/test-wan-disconnect.sh
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-disconnect"

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
printf 'wireless.wwan.ssid=%s\nwireless.wwan.device=%s\n' \
	"Hotel_WiFi" "radio1" >"$STUB_UCI"
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
ST="$STUB_UCI"
case "$1" in
	-q) case "$2" in
		get) grep -F "$3=" "$ST" | head -n 1 | sed 's/^[^=]*=//'; exit 0 ;;
	esac; exit 1 ;;
	set) k=${2%%=*}; v=${2#*=}
		grep -v -F "$k=" "$ST" >"$ST.tmp" 2>/dev/null; mv "$ST.tmp" "$ST"
		printf '%s=%s\n' "$k" "$v" >>"$ST"; exit 0 ;;
	commit) exit 0 ;;
esac
exit 1
EOF
cat >"$TMP/bin/wifi" <<'EOF'
#!/bin/sh
echo "$@" >>"$STUB_WIFI_CALLS"
EOF
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
exit 1 # link already down: loop must exit immediately, not wait
EOF
chmod +x "$TMP/bin/uci" "$TMP/bin/wifi" "$TMP/bin/ubus"
STUB_WIFI_CALLS="$TMP/wifi-calls"; export STUB_WIFI_CALLS
: >"$STUB_WIFI_CALLS"
PATH="$TMP/bin:$PATH"; export PATH

out=$(sh "$SCRIPT")
check json "$out" '{"left":true,"ssid":"Hotel_WiFi"}'
check disabled "$(grep -c 'wireless.wwan.disabled=1' "$STUB_UCI")" "1"
check reload "$(cat "$STUB_WIFI_CALLS")" "reload radio1"

# never-joined router: still succeeds with an empty SSID, no reload
printf '' >"$STUB_UCI"
: >"$STUB_WIFI_CALLS"
out=$(sh "$SCRIPT")
check empty-json "$out" '{"left":true,"ssid":""}'
check empty-no-reload "$(cat "$STUB_WIFI_CALLS")" ""

echo "PASS: wan disconnect ($PASS assertions)"
