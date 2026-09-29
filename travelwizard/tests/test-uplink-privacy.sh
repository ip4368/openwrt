#!/bin/sh
# Tests configurable upstream privacy and upgrade defaults.
HERE=$(cd "$(dirname "$0")" && pwd)
COMMON="$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"
APPLY="$HERE/../feed/travelwizard/files/usr/sbin/tw-uplink-privacy"
DEFAULTS="$HERE/../feed/travelwizard/files/etc/uci-defaults/91-travelwizard-uplink-privacy"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
STATE="$TMP/uci-state"; export STATE
LOG="$TMP/uci.log"; export LOG
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
case "$1" in
	-q)
		case "$2" in
			get)
				line=$(grep -F "$3=" "$STATE" | head -n 1)
				[ -n "$line" ] || exit 1
				printf '%s\n' "$line" | sed 's/^[^=]*=//'
				;;
			delete)
				grep -v -F "$3=" "$STATE" >"$STATE.tmp" || :
				mv "$STATE.tmp" "$STATE"
				printf 'delete %s\n' "$3" >>"$LOG"
				;;
		esac
		;;
	set)
		key=${2%%=*}; value=${2#*=}
		grep -v -F "$key=" "$STATE" >"$STATE.tmp" || :
		mv "$STATE.tmp" "$STATE"
		printf '%s=%s\n' "$key" "$value" >>"$STATE"
		printf 'set %s\n' "$2" >>"$LOG"
		;;
	show) grep "^$2\." "$STATE" 2>/dev/null ;;
	commit) printf 'commit %s\n' "$2" >>"$LOG" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/uci"
cat >"$TMP/bin/wifi" <<'EOF'
#!/bin/sh
printf 'wifi %s\n' "$*" >>"$LOG"
EOF
cat >"$TMP/bin/ifup" <<'EOF'
#!/bin/sh
printf 'ifup %s\n' "$*" >>"$LOG"
EOF
chmod +x "$TMP/bin/wifi" "$TMP/bin/ifup"
PATH="$TMP/bin:$PATH"; export PATH
value() { grep -F "$1=" "$STATE" | head -n 1 | sed 's/^[^=]*=//'; }

cat >"$STATE" <<'EOF'
travelwizard.main=main
travelwizard.main.per_network_mac=1
travelwizard.main.upstream_hostname=*
travelwizard.main.suppress_client_id=1
network.wan=interface
network.wan.hostname=OpenWrt
network.wwan=interface
network.lan=interface
wireless.wwan=wifi-iface
wireless.wwan.ssid=__unset__
wireless.wwan.device=radio0
travelwizard.legacy=savednet
travelwizard.legacy.ssid=Old network
EOF
: >"$LOG"

OUT=$(TW_COMMON="$COMMON" sh "$APPLY" --no-restart)
check apply-json "$OUT" '{"saved":true,"network_changed":true,"wireless_changed":false}'
check wan-hostname "$(value network.wan.hostname)" "*"
check wan-clientid "$(value network.wan.sendclientid)" "none"
check wwan-hostname "$(value network.wwan.hostname)" "*"
check wwan-clientid "$(value network.wwan.sendclientid)" "none"
check lan-untouched "$(grep -c '^network.lan.hostname=' "$STATE")" "0"

# Custom hostname and default client-ID behavior are both configurable.
uci set travelwizard.main.upstream_hostname=My-Phone
uci set travelwizard.main.suppress_client_id=0
: >"$LOG"
TW_COMMON="$COMMON" sh "$APPLY" --no-restart >/dev/null
check custom-wan "$(value network.wan.hostname)" "My-Phone"
check custom-wwan "$(value network.wwan.hostname)" "My-Phone"
check default-clientid-wan "$(value network.wan.sendclientid)" ""
check default-clientid-wwan "$(value network.wwan.sendclientid)" ""

# Reapplying identical settings performs no UCI writes or commits.
: >"$LOG"
TW_COMMON="$COMMON" sh "$APPLY" --no-restart >/dev/null
check idempotent "$(wc -l <"$LOG" | tr -d ' ')" "0"

# Upgrade defaults add every missing knob and stage safe network defaults.
grep -v '^travelwizard.main.\(per_network_mac\|upstream_hostname\|suppress_client_id\)=' \
	"$STATE" >"$STATE.tmp"
mv "$STATE.tmp" "$STATE"
uci set network.wan.hostname=OpenWrt
: >"$LOG"
TW_COMMON="$COMMON" TW_PRIVACY_APPLY="$APPLY" sh "$DEFAULTS"
check default-mac "$(value travelwizard.main.per_network_mac)" "1"
check default-host-config "$(value travelwizard.main.upstream_hostname)" "*"
check default-client-config "$(value travelwizard.main.suppress_client_id)" "1"
check default-host-applied "$(value network.wan.hostname)" "*"
check default-client-applied "$(value network.wan.sendclientid)" "none"
check legacy-migrated "$(value travelwizard.legacy.private_mac)" "1"
check unset-not-saved "$(grep -c '^travelwizard\..*\.ssid=__unset__$' "$STATE")" "0"

# The MAC switch takes effect on an already configured station and reuses its
# saved identity when turned back on. Its per-SSID setting overrides a global
# default that remains enabled.
uci set wireless.wwan.ssid=Hotel
uci set wireless.wwan.macaddr=02:11:22:33:44:55
uci set travelwizard.legacy.ssid=Hotel
uci set travelwizard.legacy.macaddr=06:11:22:33:44:55
uci set travelwizard.legacy.private_mac=0
: >"$LOG"
TW_COMMON="$COMMON" sh "$APPLY" >/dev/null
check disabled-live-mac "$(value wireless.wwan.macaddr)" ""
check disabled-reload "$(grep -c '^wifi reload radio0$' "$LOG")" "1"

uci set travelwizard.legacy.private_mac=1
: >"$LOG"
TW_COMMON="$COMMON" sh "$APPLY" >/dev/null
check enabled-live-mac "$(value wireless.wwan.macaddr)" "06:11:22:33:44:55"
check enabled-reload "$(grep -c '^wifi reload radio0$' "$LOG")" "1"

echo "PASS: uplink privacy ($PASS assertions)"
