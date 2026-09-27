#!/bin/sh
# Tests tw-vpn-apply (singbox/off): vpntun wiring, pbr policy, live config
# install, and the TUN-address re-assert: netifd flushes addresses it does
# not own when it reconfigures vpntun, which stalled the vault (masquerade
# fell back to a LAN IP) until the next connect. Run: sh travelwizard/tests/test-vpn-apply.sh
HERE=$(cd "$(dirname "$0")" && pwd)
APPLY="$HERE/../feed/travelwizard/files/usr/sbin/tw-vpn-apply"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export STUB_UCI="$TMP/uci-state" JSHN_ACC="$TMP/jshn-acc" UCI_LOG="$TMP/uci.log"
export IP_LOG="$TMP/ip.log" IP_TUN_ADDR="$TMP/tun-addr" IP_OVPN_ADDR="$TMP/ovpn-addr"
export IP_LINK_UP=1 IP_ADDR_BROKEN=0
export IP_ROUTE="default via 10.0.0.1 dev phy1-sta0"
export UBUS_WWAN='{"up":true,"l3_device":"phy1-sta0"}' UBUS_WAN='{"up":false}'

# Stateful uci stub (same shape as test-subnet-fix.sh, plus -q show and a
# deterministic section name for add).
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
ST="$STUB_UCI"
echo "uci $*" >>"$UCI_LOG"
case "$1" in
	show) python3 -c '
import sys
want = sys.argv[1] + "."
lists, order = {}, []
for ln in open("'"$ST"'"):
    ln = ln.rstrip("\n")
    if not ln.startswith(want):
        continue
    k, v = ln.split("=", 1)
    if v.startswith("@@"):
        lists.setdefault(k, []).append(v[2:])
        if k not in order:
            order.append(k)
    else:
        print(ln)
for k in order:
    print(k + "=" + " ".join("'"'"'" + v + "'"'"'" for v in lists[k]))
' "$2" 2>/dev/null; exit 0 ;;
	-q) case "$2" in
		get) grep -F "$3=" "$ST" | grep -v '=@@' | head -n 1 | sed 's/^[^=]*=//'; exit 0 ;;
		show) grep -q "^$3[.=]" "$ST" 2>/dev/null; exit $? ;;
		delete) grep -v "^$3[.=]" "$ST" >"$ST.tmp"; mv "$ST.tmp" "$ST"; exit 0 ;;
		esac; exit 1 ;;
	set) k=${2%%=*}; v=${2#*=}
		grep -v -F "$k=" "$ST" >"$ST.tmp" 2>/dev/null; mv "$ST.tmp" "$ST"
		printf '%s=%s\n' "$k" "$v" >>"$ST"; exit 0 ;;
	add_list) grep -qxF "${2%%=*}=@@${2#*=}" "$ST" 2>/dev/null || printf '%s\n' "${2%%=*}=@@${2#*=}" >>"$ST"; exit 0 ;;
	del_list) grep -v -xF "${2%%=*}=@@${2#*=}" "$ST" >"$ST.tmp" 2>/dev/null; mv "$ST.tmp" "$ST"; exit 0 ;;
	add) printf 'cfg_added\n'; exit 0 ;;
	commit) exit 0 ;;
esac
exit 1
EOF
cat >"$TMP/bin/jshn.sh" <<'EOF'
json_init() { : >"$JSHN_ACC"; }
json_add_boolean() { printf 'b\t%s\t%s\n' "$1" "$2" >>"$JSHN_ACC"; }
json_add_string() { printf 's\t%s\t%s\n' "$1" "$2" >>"$JSHN_ACC"; }
json_dump() {
	python3 -c 'import json; d = {}
for ln in open("'"$JSHN_ACC"'"):
    t, k, v = ln.rstrip("\n").split("\t", 2)
    d[k] = (v == "1") if t == "b" else v
print(json.dumps(d))'
}
EOF
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
case "$2" in
	network.interface.wwan) printf '%s' "$UBUS_WWAN" ;;
	network.interface.wan) printf '%s' "$UBUS_WAN" ;;
esac
exit 0
EOF
cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
exec python3 -c '
import json, sys, re
expr = sys.argv[1]
doc = json.load(sys.stdin)
toks = re.findall(r"\.([A-Za-z0-9_]+)|\[\"([^\"]+)\"\]|\[(\d+)\]", expr)
v = doc
for dot, name, idx in toks:
    try:
        v = v[dot or name] if (dot or name) else v[int(idx)]
    except (KeyError, IndexError, TypeError):
        v = None
        break
print("true" if v is True else "false" if v is False else "" if v is None else v)
' "$2"
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >>"$IP_LOG"
while [ "${1#-}" != "$1" ]; do shift; done
case "$1 $2" in
	"link show")
		[ "$IP_LINK_UP" = "0" ] && exit 1
		echo "25: $3: <UP> mtu 1500"; exit 0 ;;
	"addr show")
		case "$3" in tun_tw) cat "$IP_OVPN_ADDR";; *) cat "$IP_TUN_ADDR";; esac \
			2>/dev/null; exit 0 ;;
	"addr add")
		[ "$IP_ADDR_BROKEN" = "1" ] && exit 1
		case "$5" in tun_tw) f="$IP_OVPN_ADDR";; *) f="$IP_TUN_ADDR";; esac
		echo "25: $5 inet $3 scope global $5" >"$f"; exit 0 ;;
	"route show")
		[ "$3" = "default" ] && { printf '%s' "$IP_ROUTE"; exit 0; }
		echo "default dev tun0 table 30001"
		echo "default dev tun_tw table 30001"; exit 0 ;;
esac
exit 0
EOF
cat >"$TMP/bin/sing-box" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/openvpn" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/uci" "$TMP/bin/ubus" "$TMP/bin/jsonfilter" "$TMP/bin/ip" \
	"$TMP/bin/sing-box" "$TMP/bin/openvpn" "$TMP/bin/sleep"
PATH="$TMP/bin:$PATH"; export PATH
export TW_JSHN="$TMP/bin/jshn.sh"
export TW_COMMON="$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"

printf '{"inbounds":[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30"]}],"outbounds":[]}' \
	>"$TMP/prof.json"

seed() { # $1 type ("" = off), $2 profile id
	: >"$STUB_UCI"; : >"$UCI_LOG"; : >"$IP_LOG"
	: >"$IP_TUN_ADDR"; : >"$IP_OVPN_ADDR"
	IP_LINK_UP=1; IP_ADDR_BROKEN=0; export IP_LINK_UP IP_ADDR_BROKEN
	uci set network.vault.ipaddr="10.20.30.1"
	uci set sing-box.main.enabled="1"
	uci set pbr.config.enabled="1"
	uci set travelwizard.main.vault_dns="1.1.1.1 9.9.9.9"
	uci set dhcp.vault.dhcp_option="6,1.1.1.1,9.9.9.9"
	uci set firewall.vz="zone"
	uci set firewall.vz.name="'vault'"
	uci set firewall.vz.forward="REJECT"
	if [ -n "$1" ]; then
		uci set travelwizard.main.active_profile="$2"
		uci set "travelwizard.$2.type"="$1"
		uci set "travelwizard.$2.name"="Net"
		if [ "$1" = "openvpn" ]; then
			printf 'client\nremote vpn.example 1194 udp\n' >"$TMP/ovpn.conf"
			uci set "travelwizard.$2.config_file"="$TMP/ovpn.conf"
		else
			uci set "travelwizard.$2.config_file"="$TMP/prof.json"
		fi
	else
		uci set travelwizard.main.vpn_mode="off"
	fi
	: >"$UCI_LOG"
}
run() { TW_SB_LIVE="$TMP/live.json" sh "$APPLY" 2>/dev/null; }
val() { uci -q get "$1"; }

# 1. singbox apply wires vpntun as static-owned so netifd reloads re-assert
# the TUN address instead of flushing it as foreign.
seed singbox px1
printf '25: tun0 inet 172.19.0.1/30 scope global tun0\n' >"$IP_TUN_ADDR"
out=$(run)
check vpntun-proto "$(val network.vpntun.proto)" "static"
check vpntun-device "$(val network.vpntun.device)" "tun0"
check vpntun-ipaddr "$(val network.vpntun.ipaddr)" "172.19.0.1"
check vpntun-netmask "$(val network.vpntun.netmask)" "255.255.255.252"
check vpntun-auto "$(val network.vpntun.auto)" "1"
check mode "$(printf '%s' "$out" | grep -o '"mode": "[a-z]*"')" '"mode": "singbox"'
check applied "$(printf '%s' "$out" | grep -o '"applied": [a-z]*')" '"applied": true'
check live-copied "$(cat "$TMP/live.json")" "$(cat "$TMP/prof.json")"

# 2. pbr policy points the vault subnet at the tunnel.
check pbr-name "$(val pbr.cfg_added.name)" "vault-via-vpn"
check pbr-src "$(val pbr.cfg_added.src_addr)" "10.20.30.0/24"
check pbr-if "$(val pbr.cfg_added.interface)" "vpntun"
check pbr-enabled "$(val pbr.cfg_added.enabled)" "1"
check pbr-uplink "$(val pbr.config.uplink_interface)" "wwan"
check pbr-flag "$(printf '%s' "$out" | grep -o '"pbr": [a-z]*')" '"pbr": true'
check kill "$(printf '%s' "$out" | grep -o '"kill_holding": [a-z]*')" '"kill_holding": true'

# 3. TUN address already present: re-assert attempted (idempotent), silent.
check reasserted "$(grep -c 'addr add 172.19.0.1/30 dev tun0' "$IP_LOG")" "1"
check no-warning "$(printf '%s' "$out" | grep -c '"warning"')" "0"

# 4. TUN address missing after reload: repaired in place, still silent.
seed singbox px1
: >"$IP_TUN_ADDR"
out=$(run)
check repaired "$(cat "$IP_TUN_ADDR")" \
	"25: tun0 inet 172.19.0.1/30 scope global tun0"
check repair-silent "$(printf '%s' "$out" | grep -c '"warning"')" "0"

# 5. TUN address missing and unrepairable: loud warning, apply completes.
seed singbox px1
: >"$IP_TUN_ADDR"; IP_ADDR_BROKEN=1; export IP_ADDR_BROKEN
out=$(run)
check loud-warning "$(printf '%s' "$out" | grep -o '"warning": "[^"]*"' | grep -c 'tun0')" "1"
check loud-applied "$(printf '%s' "$out" | grep -o '"applied": [a-z]*')" '"applied": true'

# 6. tun0 link missing entirely: hard error naming tun0.
seed singbox px1
IP_LINK_UP=0; export IP_LINK_UP
out=$(run)
check nolink-error "$(printf '%s' "$out" | grep -c 'tun0 is missing')" "1"

# 7. switching singbox -> off scrubs the vpntun statics, keeps the
# policy row (disabled), and reports off.
seed singbox px1
printf '25: tun0 inet 172.19.0.1/30 scope global tun0\n' >"$IP_TUN_ADDR"
run >/dev/null
uci set travelwizard.main.active_profile=""
uci set travelwizard.main.vpn_mode="off"
out=$(run)
check off-mode "$(printf '%s' "$out" | grep -o '"mode": "[a-z]*"')" '"mode": "off"'
check off-disabled "$(val pbr.cfg_added.enabled)" "0"
check off-clean-device "$(val network.vpntun.device)" ""
check off-clean-ipaddr "$(val network.vpntun.ipaddr)" ""

# 8. openvpn apply adopts the server-pushed address into vpntun statics so
# later reloads re-assert it instead of flushing it as foreign.
seed openvpn ox1
printf '26: tun_tw inet 10.8.0.6/24 scope global tun_tw\n' >"$IP_OVPN_ADDR"
out=$(run)
check ovpn-mode "$(printf '%s' "$out" | grep -o '"mode": "[a-z]*"')" '"mode": "openvpn"'
check ovpn-device "$(val network.vpntun.device)" "tun_tw"
check ovpn-proto "$(val network.vpntun.proto)" "static"
check ovpn-ipaddr "$(val network.vpntun.ipaddr)" "10.8.0.6"
check ovpn-netmask "$(val network.vpntun.netmask)" "255.255.255.0"
check ovpn-pbr-if "$(val pbr.cfg_added.interface)" "vpntun"
check ovpn-silent "$(printf '%s' "$out" | grep -c '"warning"')" "0"

# 9. openvpn link not up yet: adopt is best effort, loud warning, apply
# completes (address is adopted on the next apply once connected).
seed openvpn ox1
: >"$IP_OVPN_ADDR"; IP_LINK_UP=0; export IP_LINK_UP
out=$(run)
check ovpn9-warn "$(printf '%s' "$out" | grep -o '"warning": "[^"]*"' | grep -c 'tun_tw')" "1"
check ovpn9-applied "$(printf '%s' "$out" | grep -o '"applied": [a-z]*')" '"applied": true'
check ovpn9-proto "$(val network.vpntun.proto)" "none"

# 10. unit: plen2mask (used by the vpntun adopt step).
. "$TW_COMMON"
check mask-0 "$(plen2mask 0)" "0.0.0.0"
check mask-8 "$(plen2mask 8)" "255.0.0.0"
check mask-24 "$(plen2mask 24)" "255.255.255.0"
check mask-30 "$(plen2mask 30)" "255.255.255.252"
check mask-32 "$(plen2mask 32)" "255.255.255.255"
plen2mask "" >/dev/null 2>&1 && got=yes || got=no
check mask-empty "$got" "no"
plen2mask x >/dev/null 2>&1 && got=yes || got=no
check mask-garbage "$got" "no"
plen2mask 33 >/dev/null 2>&1 && got=yes || got=no
check mask-range "$got" "no"
check mask-bad-out "$(plen2mask x)" ""

echo "PASS: vpn apply ($PASS assertions)"
