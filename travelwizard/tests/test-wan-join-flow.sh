#!/bin/sh
# Regression: after association/save, join clears the setup portal and
# returns immediately without running the slow captive probe inline.
# Run: sh travelwizard/tests/test-wan-join-flow.sh
HERE=$(cd "$(dirname "$0")" && pwd)
JOIN="$HERE/../feed/travelwizard/files/usr/sbin/tw-wan-join"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/jshn.sh" <<'EOF'
:
EOF
cat >"$TMP/common.sh" <<'EOF'
tw_uci_encryption() { echo psk2; }
tw_saved_upsert() { echo "saved $*" >>"$CALLS"; }
EOF
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
echo "uci $*" >>"$CALLS"
if [ "$1" = "show" ] && [ "$2" = "wireless" ]; then
	echo 'wireless.radio0=wifi-device'
	exit 0
fi
if [ "$1" = "-q" ] && [ "$2" = "get" ] \
	&& [ "$3" = "wireless.radio0.band" ]; then
	echo 5g
fi
exit 0
EOF
cat >"$TMP/bin/wifi" <<'EOF'
#!/bin/sh
echo "wifi $*" >>"$CALLS"
EOF
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
echo '{"up":true}'
EOF
cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
cat >/dev/null
echo true
EOF
cat >"$TMP/bin/lock" <<'EOF'
#!/bin/sh
echo "lock $*" >>"$CALLS"
EOF
cat >"$TMP/bin/subnet-fix" <<'EOF'
#!/bin/sh
echo subnet >>"$CALLS"
echo '{"changed":false}'
EOF
cat >"$TMP/bin/portal" <<'EOF'
#!/bin/sh
echo "portal $*" >>"$CALLS"
EOF
chmod +x "$TMP/bin/"*

OUT=$(PATH="$TMP/bin:$PATH" TW_JSHN="$TMP/jshn.sh" \
	TW_COMMON="$TMP/common.sh" TW_SUBNET_FIX="$TMP/bin/subnet-fix" \
	TW_PORTAL="$TMP/bin/portal" sh "$JOIN" Hotel secret 5g 'WPA2 PSK' '')
check linked "$(printf '%s' "$OUT" | grep -o '"linked":[a-z]*')" '"linked":true'
check ssid "$(printf '%s' "$OUT" | grep -o '"ssid":"[^"]*"')" '"ssid":"Hotel"'
check async-captive "$(printf '%s' "$OUT" | grep -o '"internet":[^}]*')" '"internet":null'
check saved "$(grep -c '^saved Hotel secret 5g WPA2 PSK' "$CALLS")" 1
check portal-cleared "$(grep -c '^portal auto$' "$CALLS")" 2
SAVED_LINE=$(grep -n -m1 '^saved ' "$CALLS" | cut -d: -f1)
PORTAL_LINE=$(grep -n -m1 '^portal auto$' "$CALLS" | cut -d: -f1)
[ "$SAVED_LINE" -lt "$PORTAL_LINE" ] || {
	echo "FAIL: portal was cleared before credentials were saved"; exit 1;
}
PASS=$((PASS + 1))

echo "PASS: wan join flow ($PASS assertions)"
