#!/bin/sh
# Router clock status/set/sync tests with no host clock changes.
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../feed/travelwizard/files/usr/sbin/tw-time"

PASS=0
fail() { echo "FAIL: $1"; exit 1; }
has() {
	case "$2" in *"$3"*) PASS=$((PASS + 1)) ;; *) fail "$1: [$2] lacks [$3]" ;; esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '1782738400\n' >"$TMP/epoch"
: >"$TMP/calls"

cat >"$TMP/jshn.sh" <<'EOF'
JSON=""
json_init() { JSON=""; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
json_pair() {
	local key=$1 value=$2
	JSON="$JSON${JSON:+,}\"$key\":$value"
}
json_add_string() {
	local value
	value=$(json_escape "$2"); json_pair "$1" "\"$value\""
}
json_add_int() { json_pair "$1" "$2"; }
json_add_boolean() { [ "$2" = 1 ] && json_pair "$1" true || json_pair "$1" false; }
json_dump() { printf '{%s}\n' "$JSON"; }
EOF

cat >"$TMP/bin/date" <<'EOF'
#!/bin/sh
case "$1" in
	+%s) cat "$TIME_STATE" ;;
	-u) echo '2026-06-29T13:06:40Z' ;;
	-s)
		value=${2#@}
		case "$value" in ''|*[!0-9]*) exit 1 ;; esac
		printf '%s\n' "$value" >"$TIME_STATE"
		echo "date set $value" >>"$TIME_CALLS"
		;;
	*) exit 1 ;;
esac
EOF
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = -q ] && shift
[ "$1" = get ] || exit 1
case "$2" in
	system.@system\[0\].zonename) echo UTC ;;
	system.ntp.enabled) echo 1 ;;
	*) exit 1 ;;
esac
EOF
cat >"$TMP/bin/sysntpd" <<'EOF'
#!/bin/sh
echo "ntp $*" >>"$TIME_CALLS"
exit "${NTP_FAIL:-0}"
EOF
chmod +x "$TMP/bin/"*

export TIME_STATE="$TMP/epoch" TIME_CALLS="$TMP/calls"
export TW_JSHN="$TMP/jshn.sh" TW_DATE="$TMP/bin/date" TW_UCI="$TMP/bin/uci"
export TW_NTP_INIT="$TMP/bin/sysntpd" TW_TIME_MARKER="$TMP/time-marker"

out=$(sh "$SCRIPT" status) || fail "status"
has "status epoch" "$out" '"epoch":1782738400'
has "status timezone" "$out" '"timezone":"UTC"'
has "NTP enabled" "$out" '"ntp_enabled":true'

out=$(sh "$SCRIPT" set 1800000000) || fail "set"
has "set epoch" "$out" '"epoch":1800000000'
has "date invoked" "$(cat "$TMP/calls")" 'date set 1800000000'
has "NTP restarted after set" "$(cat "$TMP/calls")" 'ntp restart'
[ -e "$TMP/time-marker" ] || fail "persistent time marker missing"
PASS=$((PASS + 1))

if out=$(sh "$SCRIPT" set nonsense); then fail "invalid time accepted"; fi
has "invalid time error" "$out" 'invalid device time'
if out=$(sh "$SCRIPT" set 123); then fail "out-of-range time accepted"; fi
has "range error" "$out" 'outside the supported range'

: >"$TMP/calls"
out=$(sh "$SCRIPT" sync) || fail "sync"
has "sync response" "$out" '"sync_started":true'
has "sync restarted NTP" "$(cat "$TMP/calls")" 'ntp restart'

echo "PASS: time ($PASS assertions)"
