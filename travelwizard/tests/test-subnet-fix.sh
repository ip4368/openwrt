#!/bin/sh
# Tests tw-subnet-fix: overlap detection, re-addressing with multi-range
# candidate pools (a covering upstream supernet such as 10.0.0.0/8 must not
# strand the vault), pbr policy tracking, and the no-link/no-change paths.
# Run: sh travelwizard/tests/test-subnet-fix.sh
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../feed/travelwizard/files/usr/sbin/tw-subnet-fix"
COMMON="$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export STUB_UCI="$TMP/uci-state" JSHN_ACC="$TMP/jshn-acc" UBUS_WWAN="" UBUS_WAN="" IP_ROUTE=""
export UCI_LOG="$TMP/uci.log"

# Stateful uci stub over $STUB_UCI (key=value lines; list values carry a
# marker and print in the real one-line quoted shape).
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
		delete) grep -v "^$3[.=]" "$ST" >"$ST.tmp"; mv "$ST.tmp" "$ST"; exit 0 ;;
		esac; exit 1 ;;
	set) k=${2%%=*}; v=${2#*=}
		grep -v -F "$k=" "$ST" >"$ST.tmp" 2>/dev/null; mv "$ST.tmp" "$ST"
		printf '%s=%s\n' "$k" "$v" >>"$ST"; exit 0 ;;
	add_list) grep -qxF "${2%%=*}=@@${2#*=}" "$ST" 2>/dev/null || printf '%s\n' "${2%%=*}=@@${2#*=}" >>"$ST"; exit 0 ;;
	del_list) grep -v -xF "${2%%=*}=@@${2#*=}" "$ST" >"$ST.tmp" 2>/dev/null; mv "$ST.tmp" "$ST"; exit 0 ;;
	add) echo "cfg$RANDOM"; exit 0 ;;
	commit) exit 0 ;;
esac
exit 1
EOF
# Minimal jshn stub: only what tw-subnet-fix uses.
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
# ubus stub: canned per-interface status blobs.
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
case "$2" in
	network.interface.wwan) printf '%s' "$UBUS_WWAN" ;;
	network.interface.wan) printf '%s' "$UBUS_WAN" ;;
esac
exit 0
EOF
# jsonfilter stub: dotted/bracket paths (e.g. @.up, @["ipv4-address"][0].mask).
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
# ip stub: only the default-route lookup tw_upstream needs.
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "route show default" ] && printf "%s" "$IP_ROUTE"
exit 0
EOF
chmod +x "$TMP/bin/uci" "$TMP/bin/ubus" "$TMP/bin/jsonfilter" "$TMP/bin/ip"
PATH="$TMP/bin:$PATH"; export PATH
export TW_JSHN="$TMP/bin/jshn.sh" TW_COMMON="$COMMON"

seed() { # $1 lan ip, $2 vault ip: fresh uci state with pbr policy + dns
	: >"$STUB_UCI"; : >"$UCI_LOG"
	uci set network.lan.ipaddr="$1"
	uci set network.vault.ipaddr="$2"
	uci set travelwizard.main.lan_net="$1/24"
	uci set travelwizard.main.vault_net="$2/24"
	printf '%s\n' "pbr.cfg1=policy" "pbr.cfg1.name='vault-via-vpn'" \
		"pbr.cfg1.src_addr=${2%.*}.0/24" "pbr.config.enabled=1" >>"$STUB_UCI"
	uci set dhcp.@dnsmasq[0]=dnsmasq
	uci add_list dhcp.@dnsmasq[0].address="/secure.router/$1"
	: >"$UCI_LOG"
}
link() { # $1 wwan addr/mask or "", $2 l3dev: canned uplink (wan stays down)
	if [ -n "$1" ]; then
		UBUS_WWAN=$(printf '{"up":true,"l3_device":"%s","ipv4-address":[{"address":"%s","mask":%s}]}' \
			"$2" "${1%/*}" "${1#*/}")
		IP_ROUTE="default via 10.0.0.1 dev $2 proto static metric 10"
	else
		UBUS_WWAN='{"up":false}'; IP_ROUTE=""
	fi
	UBUS_WAN='{"up":false}'
	export UBUS_WWAN UBUS_WAN IP_ROUTE
}
run() { TW_JSHN="$TMP/bin/jshn.sh" TW_COMMON="$COMMON" sh "$SCRIPT" 2>/dev/null; }
val() { uci -q get "$1"; }
dns_addrs() { uci show dhcp 2>/dev/null | sed -n 's/^dhcp\.[^.]*\.address=//p' | tr ' ' '\n' | tr -d "'"; }

# 1. no uplink at all: quiet no-op
seed 192.168.40.1 10.20.30.1; link "" ""
check no-link "$(run)" '{"changed":false,"reason":"no upstream link"}'

# 2. ordinary hotel /24: nothing overlaps, nothing moves
seed 192.168.40.1 10.20.30.1; link "192.168.1.5/24" "phy1-sta0"
out=$(run)
check no-clash-changed "$(printf '%s' "$out" | grep -o '"changed": [a-z]*')" '"changed": false'
check no-clash-lan "$(val network.lan.ipaddr)" "192.168.40.1"
check no-clash-vault "$(val network.vault.ipaddr)" "10.20.30.1"
check no-clash-setupname "$(dns_addrs)" "/secure.router/192.168.40.1"
check no-clash-quiet "$(grep -c -E 'del_list|add_list|commit dhcp' "$UCI_LOG")" "0"

# 3. upstream on 10.0.0.0/8 (covers all of 10.x): the vault must escape to
# 172.26.x, not fail with "no free vault subnet"
seed 192.168.40.1 10.20.30.1; link "10.1.42.115/8" "phy1-sta0"
out=$(run)
check slash8-changed "$(printf '%s' "$out" | grep -o '"changed": [a-z]*')" '"changed": true'
check slash8-vault "$(val network.vault.ipaddr)" "172.26.30.1"
check slash8-vault-net "$(val travelwizard.main.vault_net)" "172.26.30.1/24"
check slash8-pbr "$(val pbr.cfg1.src_addr)" "172.26.30.0/24"
check slash8-lan-kept "$(val network.lan.ipaddr)" "192.168.40.1"

# 4. upstream clashes with the LAN only: LAN moves within 192.168, vault stays
seed 192.168.40.1 10.20.30.1; link "192.168.40.7/24" "phy1-sta0"
out=$(run)
check lanclash-changed "$(printf '%s' "$out" | grep -o '"changed": [a-z]*')" '"changed": true'
check lanclash-lan "$(val network.lan.ipaddr)" "192.168.51.1"
check lanclash-vault-kept "$(val network.vault.ipaddr)" "10.20.30.1"
check lanclash-setupname "$(dns_addrs)" "/secure.router/192.168.51.1"

# 5. upstream 192.168.0.0/16 covers every 192.168 pick: LAN escapes ranges too
seed 192.168.40.1 10.20.30.1; link "192.168.7.9/16" "phy1-sta0"
out=$(run)
check slash16-lan "$(val network.lan.ipaddr)" "172.25.40.1"
check slash16-vault-kept "$(val network.vault.ipaddr)" "10.20.30.1"
check slash16-setupname "$(dns_addrs)" "/secure.router/172.25.40.1"

# 6. vault-only move leaves the setup name on the (unchanged) LAN address
seed 192.168.40.1 10.20.30.1; link "10.1.42.115/8" "phy1-sta0"
run >/dev/null
check vaultmove-setupname "$(dns_addrs)" "/secure.router/192.168.40.1"

# 7. missing entry (upgrade) heals without a subnet move
seed 192.168.40.1 10.20.30.1; link "192.168.1.5/24" "phy1-sta0"
uci del_list dhcp.@dnsmasq[0].address=/secure.router/192.168.40.1
: >"$UCI_LOG"
out=$(run)
check heal-created "$(dns_addrs)" "/secure.router/192.168.40.1"
check heal-changed "$(printf '%s' "$out" | grep -o '"changed": [a-z]*')" '"changed": false'
check heal-committed "$(grep -c 'commit dhcp' "$UCI_LOG")" "1"

# 8. stale entry (old LAN address) is replaced, never duplicated
seed 192.168.40.1 10.20.30.1; link "192.168.1.5/24" "phy1-sta0"
uci del_list dhcp.@dnsmasq[0].address=/secure.router/192.168.40.1
uci add_list dhcp.@dnsmasq[0].address=/secure.router/192.168.51.1
out=$(run)
check stale-replaced "$(dns_addrs)" "/secure.router/192.168.40.1"

# 9. the portal catch-all in the same list is left alone
seed 192.168.40.1 10.20.30.1; link "192.168.1.5/24" "phy1-sta0"
uci add_list dhcp.@dnsmasq[0].address=/#/192.168.40.1
out=$(run)
check coexist "$(dns_addrs | sort | tr '\n' ' ')" "/#/192.168.40.1 /secure.router/192.168.40.1 "

# 10. old setup name (router.lan) from earlier builds is migrated away
seed 192.168.40.1 10.20.30.1; link "192.168.1.5/24" "phy1-sta0"
uci add_list dhcp.@dnsmasq[0].address=/router.lan/192.168.40.1
: >"$UCI_LOG"
out=$(run)
check migrate-old-gone "$(dns_addrs)" "/secure.router/192.168.40.1"
check migrate-changed "$(printf '%s' "$out" | grep -o '"changed": [a-z]*')" '"changed": false'
check migrate-committed "$(grep -c 'commit dhcp' "$UCI_LOG")" "1"

echo "PASS: subnet fix ($PASS assertions)"
