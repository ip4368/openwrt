#!/bin/sh
# Tests tw-wifi-qr: live AP values, WIFI: URI escaping, nopass networks,
# and graceful failure without qrencode.
# Run: sh travelwizard/tests/test-wifi-qr.sh
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../feed/travelwizard/files/usr/sbin/tw-wifi-qr"

PASS=0
ok() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stub uci: mgmt AP (tricky chars) + open vault AP + stored fallbacks.
cat >"$TMP/uci-get" <<'EOF'
wireless.mgmt_radio0.mode=ap
wireless.mgmt_radio0.network=lan
wireless.mgmt_radio0.ssid=A;B:C,D\E"F
wireless.mgmt_radio0.key=p@ss,w:th
wireless.mgmt_radio0.encryption=sae-mixed
wireless.vault_radio0.mode=ap
wireless.vault_radio0.network=vault
wireless.vault_radio0.ssid=OpenVault
wireless.vault_radio0.key=
wireless.vault_radio0.encryption=none
travelwizard.main.mgmt_ssid=Fallback
travelwizard.main.mgmt_key=fallback-key
EOF
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ]; then
	echo "wireless.mgmt_radio0=wifi-iface"
	echo "wireless.vault_radio0=wifi-iface"
	exit 0
fi
[ "$1" = "-q" ] && [ "$2" = "get" ] || exit 1
grep -F "$3=" "$UCI_GET" | head -n 1 | sed 's/^[^=]*=//'
EOF
cat >"$TMP/bin/qrencode" <<'EOF'
#!/bin/sh
printf 'qrencode %s\n' "$*" >>"$QR_LOG"
echo '<svg>STUB</svg>'
EOF
chmod +x "$TMP/bin/uci" "$TMP/bin/qrencode"
cat >"$TMP/jshn.sh" <<'EOF'
json_init() { : >"$JSON_LOG"; }
json_add_string() { echo "string $1=$2" >>"$JSON_LOG"; }
json_dump() { cat "$JSON_LOG"; }
EOF
export UCI_GET="$TMP/uci-get" QR_LOG="$TMP/qr.log" JSON_LOG="$TMP/json.log"
export TW_JSHN="$TMP/jshn.sh"
PATH="$TMP/bin:/usr/bin:/bin"; export PATH

: >"$QR_LOG"
OUT=$(sh "$SCRIPT" mgmt) || fail "mgmt exited nonzero"
printf '%s\n' "$OUT" | grep -q 'string net=mgmt' || fail "net missing: [$OUT]"
ok
printf '%s\n' "$OUT" | grep -q 'string svg=<svg>STUB</svg>' || fail "svg missing: [$OUT]"
ok
grep -qF 'qrencode -t SVG -m 1 -o - WIFI:T:WPA;S:A\;B\:C\,D\\E\"F;P:p@ss\,w\:th;;' \
	"$QR_LOG" || fail "bad mgmt URI: [$(cat "$QR_LOG")]"
ok

: >"$QR_LOG"
OUT=$(sh "$SCRIPT" vault) || fail "vault exited nonzero"
grep -qF 'qrencode -t SVG -m 1 -o - WIFI:T:nopass;S:OpenVault;;' \
	"$QR_LOG" || fail "bad vault URI: [$(cat "$QR_LOG")]"
ok

OUT=$(sh "$SCRIPT" bogus) && fail "bogus net should fail"
[ "$OUT" = '{"error":"bad network"}' ] || fail "bogus json: [$OUT]"
ok
OUT=$(sh "$SCRIPT") && fail "missing net should fail"
[ "$OUT" = '{"error":"bad network"}' ] || fail "missing json: [$OUT]"
ok

# qrencode absent: clean error, still valid JSON.
mkdir -p "$TMP/emptybin"
cp "$TMP/bin/uci" "$TMP/emptybin/"
PATH="$TMP/emptybin:/usr/bin:/bin"
OUT=$(PATH="$PATH" sh "$SCRIPT" mgmt) && fail "should fail without qrencode"
[ "$OUT" = '{"error":"qrencode not installed"}' ] || fail "no-qr json: [$OUT]"
ok

echo "PASS: wifi qr ($PASS assertions)"
