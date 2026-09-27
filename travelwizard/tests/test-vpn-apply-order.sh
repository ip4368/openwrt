#!/bin/sh
# Regression: a first proxy activation must load vpntun into netifd before
# starting the tunnel, and must not restart pbr until the tunnel is visible.
# Run: sh travelwizard/tests/test-vpn-apply-order.sh
HERE=$(cd "$(dirname "$0")" && pwd)
APPLY="$HERE/../feed/travelwizard/files/usr/sbin/tw-vpn-apply"

PASS=0
ok() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/init"
export CALLS="$TMP/calls" STUB_CONF="$TMP/profile.json"
: >"$CALLS"
printf '%s\n' '{"inbounds":[{"type":"tun"}]}' >"$STUB_CONF"

cat >"$TMP/jshn.sh" <<'EOF'
json_init() { :; }
json_add_string() { :; }
json_add_boolean() { :; }
json_dump() { echo '{}'; }
EOF
cat >"$TMP/common.sh" <<'EOF'
tw_active_mode() { echo singbox; }
tw_dhcp_dns_option() { printf '%s' "$1"; }
tw_set_vault_dns() { return 1; }
tw_upstream() { echo wwan; }
tw_tunnel_routed() { return 0; }
tw_kill_holding() { return 0; }
tw_tun_addr_ensure() { return 0; }
EOF
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
echo "uci $*" >>"$CALLS"
if [ "$1" = "-q" ] && [ "$2" = "get" ]; then
	case "$3" in
		travelwizard.main.active_profile) echo p1 ;;
		travelwizard.p1.type) echo singbox ;;
		travelwizard.p1.config_file) echo "$STUB_CONF" ;;
		travelwizard.p1.name) echo TestProxy ;;
		network.vault.ipaddr) echo 10.20.30.1 ;;
		sing-box.main.enabled) echo 1 ;;
		dhcp.vault.dhcp_option) echo 6,1.1.1,9.9.9.9 ;;
		pbr.cfgvpn.name) echo vault-via-vpn ;;
		*) exit 1 ;;
	esac
	exit 0
fi
if { [ "$1" = "-q" ] && [ "$2" = "show" ]; } || [ "$1" = "show" ]; then
	case "${3:-$2}" in
		sing-box.main) echo 'sing-box.main=sing-box' ;;
		pbr) echo 'pbr.cfgvpn=policy' ;;
	esac
	exit 0
fi
if [ "$1" = "add" ]; then echo cfgvpn; fi
exit 0
EOF
cat >"$TMP/bin/sing-box" <<'EOF'
#!/bin/sh
echo "sing-box $*" >>"$CALLS"
exit 0
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >>"$CALLS"
[ "$1 $2 $3" = "link show tun0" ]
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
cat >"$TMP/bin/ifup" <<'EOF'
#!/bin/sh
echo "ifup $*" >>"$CALLS"
exit 0
EOF
cat >"$TMP/init/service" <<'EOF'
#!/bin/sh
echo "${0##*/} $*" >>"$CALLS"
exit 0
EOF
chmod +x "$TMP/bin/"* "$TMP/init/service"
for s in sing-box openvpn network firewall dnsmasq pbr; do
	cp "$TMP/init/service" "$TMP/init/$s"
done

PATH="$TMP/bin:$PATH" \
TW_JSHN="$TMP/jshn.sh" TW_COMMON="$TMP/common.sh" \
TW_INIT_DIR="$TMP/init" TW_IFUP="$TMP/bin/ifup" \
TW_SB_LIVE="$TMP/live.json" \
	sh "$APPLY" >/dev/null || fail "apply failed"

line_of() { grep -n -m1 "$1" "$CALLS" | cut -d: -f1; }
NET=$(line_of '^network reload$')
START=$(line_of '^sing-box restart$')
IFUP=$(line_of '^ifup vpntun$')
FW=$(line_of '^firewall reload$')
PBR=$(line_of '^pbr restart$')
[ -n "$NET" ] && [ -n "$START" ] && [ -n "$IFUP" ] \
	&& [ -n "$FW" ] && [ -n "$PBR" ] || fail "missing lifecycle call: [$(cat "$CALLS")]"
ok
[ "$NET" -lt "$START" ] && [ "$START" -lt "$IFUP" ] \
	&& [ "$IFUP" -lt "$FW" ] && [ "$FW" -lt "$PBR" ] \
	|| fail "wrong first-connect order: network=$NET start=$START ifup=$IFUP firewall=$FW pbr=$PBR"
ok
grep -q '^uci set pbr.cfgvpn.interface=vpntun$' "$CALLS" \
	|| fail "pbr was not pointed at vpntun"
ok
cmp -s "$STUB_CONF" "$TMP/live.json" || fail "profile was not published"
ok

echo "PASS: vpn apply ordering ($PASS assertions)"
