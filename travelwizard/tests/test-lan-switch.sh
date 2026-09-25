#!/bin/sh
# Tests physical LAN bridge selection and the BTN_0 position mapping with
# stubbed OpenWrt commands. Run: sh travelwizard/tests/test-lan-switch.sh
HERE=$(cd "$(dirname "$0")" && pwd)
SWITCH="$HERE/../feed/travelwizard/files/usr/sbin/tw-lan-switch"
BUTTON="$HERE/../feed/travelwizard/files/etc/rc.button/BTN_0"

PASS=0
fail() { echo "FAIL: $1"; exit 1; }
check_eq() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		fail "$1: got [$2] want [$3]"
	fi
}
check_has() {
	case "$2" in
		*"$3"*) PASS=$((PASS + 1)) ;;
		*) fail "$1: [$2] does not contain [$3]" ;;
	esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
printf 'eth1\n' >"$TMP/state/lan"
: >"$TMP/state/vault"
: >"$TMP/state/calls"

cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
cmd=$1; shift
case "$cmd" in
show)
	[ "$1" = network ] || exit 1
	echo 'network.@device[0]=device'
	echo "network.@device[0].name='br-lan'"
	[ "${MISSING_VAULT:-0}" = 1 ] || {
		echo 'network.@device[1]=device'
		echo "network.@device[1].name='br-vault'"
	}
	;;
get)
	case "$1" in
		travelwizard.main.lan_port) echo eth1 ;;
		network.lan.device) echo br-lan ;;
		network.vault.device) echo br-vault ;;
		network.@device\[0\].name) echo br-lan ;;
		network.@device\[1\].name) [ "${MISSING_VAULT:-0}" = 1 ] || echo br-vault ;;
		network.@device\[0\].ports) cat "$STUB_STATE/lan" ;;
		network.@device\[1\].ports) cat "$STUB_STATE/vault" ;;
		*) exit 1 ;;
	esac
	;;
del_list)
	case "$1" in
		network.@device\[0\].ports=eth1) : >"$STUB_STATE/lan" ;;
		network.@device\[1\].ports=eth1) : >"$STUB_STATE/vault" ;;
		*) exit 1 ;;
	esac
	;;
add_list)
	case "$1" in
		network.@device\[0\].ports=eth1) printf 'eth1\n' >"$STUB_STATE/lan" ;;
		network.@device\[1\].ports=eth1) printf 'eth1\n' >"$STUB_STATE/vault" ;;
		*) exit 1 ;;
	esac
	;;
commit)
	[ "$1" = network ] || exit 1
	echo commit >>"$STUB_STATE/calls"
	;;
*) exit 1 ;;
esac
EOF
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
echo "ubus $*" >>"$STUB_STATE/calls"
exit 0
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >>"$STUB_STATE/calls"
exit 0
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >>"$STUB_STATE/calls"
exit 0
EOF
cat >"$TMP/bin/lock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/record-mode" <<'EOF'
#!/bin/sh
echo "$1" >>"$STUB_STATE/button"
EOF
chmod +x "$TMP/bin/"*
STUB_STATE="$TMP/state"; export STUB_STATE
PATH="$TMP/bin:$PATH"; export PATH

out=$(sh "$SWITCH" status) || fail "direct status failed"
check_has "direct status" "$out" '"mode":"direct"'

out=$(sh "$SWITCH" protected) || fail "protected switch failed"
check_has "protected result" "$out" '"changed":true'
check_eq "LAN membership removed" "$(cat "$TMP/state/lan")" ""
check_eq "vault membership added" "$(cat "$TMP/state/vault")" "eth1"
check_eq "one network reload" "$(grep -c '^ubus call network reload$' "$TMP/state/calls")" "1"
check_has "link went down" "$(cat "$TMP/state/calls")" 'ip link set dev eth1 down'
check_has "link came up" "$(cat "$TMP/state/calls")" 'ip link set dev eth1 up'

out=$(sh "$SWITCH" protected) || fail "idempotent protected switch failed"
check_has "idempotent result" "$out" '"changed":false'
check_eq "no redundant reload" "$(grep -c '^ubus call network reload$' "$TMP/state/calls")" "1"

out=$(sh "$SWITCH" direct) || fail "direct switch failed"
check_has "direct result" "$out" '"mode":"direct"'
check_eq "LAN membership restored" "$(cat "$TMP/state/lan")" "eth1"
check_eq "vault membership removed" "$(cat "$TMP/state/vault")" ""
seq=$(grep -E '^(ip link set dev eth1 (down|up)|sleep 1|ubus call network reload)$' "$TMP/state/calls" \
	| sed -e 's/.* down$/down/' -e 's/.* up$/up/' -e 's/^sleep 1$/sleep/' -e 's/^ubus call network reload$/reload/' \
	| tr '\n' ' ')
check_eq "carrier flap order" "$seq" "down sleep reload up down sleep reload up "

: >"$TMP/state/button"
TYPE=switch ACTION=pressed TW_LAN_SWITCH_BIN="$TMP/bin/record-mode" sh "$BUTTON"
TYPE=switch ACTION=released TW_LAN_SWITCH_BIN="$TMP/bin/record-mode" sh "$BUTTON"
TYPE=button ACTION=pressed TW_LAN_SWITCH_BIN="$TMP/bin/record-mode" sh "$BUTTON"
check_eq "button position mapping" "$(tr '\n' ' ' <"$TMP/state/button")" "protected direct "

if MISSING_VAULT=1 sh "$SWITCH" status >"$TMP/state/error" 2>/dev/null; then
	fail "missing protected bridge should fail"
fi
check_has "missing bridge error" "$(cat "$TMP/state/error")" 'protected LAN bridge not found'

echo "PASS: LAN switch ($PASS assertions)"
