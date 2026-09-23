#!/bin/sh
# Tests the vault leak-hardening helpers: tw_dhcp_dns_option (DNS option 6
# built only from valid IPv4), tw_set_vault_dns (fallback + change
# detection), and tw_pbr_set_vault_net (policy follows a renumbered vault).
# Run: sh travelwizard/tests/test-vault-dns.sh
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
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
# stub: flat key=value store in $STUB_UCI; lists are space-joined
[ "$1" = "-q" ] && shift
db="$STUB_UCI"; touch "$db"
del() { grep -vF "$1=" "$db" >"$db.tmp"; mv "$db.tmp" "$db"; }
case "$1" in
	show) grep "^$2\." "$db" ;;
	get) grep -F "$2=" "$db" | head -n 1 | sed 's/^[^=]*=//' ;;
	set) k=${2%%=*}; del "$k"; echo "$2" >>"$db" ;;
	delete) del "$2" ;;
	add_list) k=${2%%=*}; v=${2#*=}
		old=$(grep -F "$k=" "$db" | sed 's/^[^=]*=//'); del "$k"
		echo "$k=${old:+$old }$v" >>"$db" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/uci"
PATH="$TMP/bin:$PATH"; export PATH
STUB_UCI="$TMP/uci.db"; export STUB_UCI

# 1. option builder: commas/spaces, invalid entries and IPv6 dropped
check opt-basic "$(tw_dhcp_dns_option '1.1.1.1 9.9.9.9')" "6,1.1.1.1,9.9.9.9"
check opt-commas "$(tw_dhcp_dns_option '10.64.0.1, 10.64.0.2')" "6,10.64.0.1,10.64.0.2"
check opt-typo "$(tw_dhcp_dns_option '1.1.1 1.0.0.1')" "6,1.0.0.1"
check opt-v6 "$(tw_dhcp_dns_option '2606:4700::1111 8.8.8.8')" "6,8.8.8.8"
check opt-range "$(tw_dhcp_dns_option '256.1.1.1 1.2.3.4.5')" ""
check opt-empty "$(tw_dhcp_dns_option '')" ""

# 2. set vault DNS: writes once, reports no change on repeat, falls back
: >"$STUB_UCI"
tw_set_vault_dns "10.64.0.1" && got=changed || got=same
check set-first "$got" "changed"
check set-value "$(uci -q get dhcp.vault.dhcp_option)" "6,10.64.0.1"
tw_set_vault_dns "10.64.0.1" && got=changed || got=same
check set-repeat "$got" "same"
tw_set_vault_dns "not-an-ip" && got=changed || got=same
check set-fallback "$got" "changed"
check set-fallback-value "$(uci -q get dhcp.vault.dhcp_option)" "6,1.1.1.1,9.9.9.9"

# 3. pbr policy follows the vault subnet; other policies untouched
cat >"$STUB_UCI" <<'EOF'
pbr.config=pbr
pbr.@policy[0]=policy
pbr.@policy[0].name=other
pbr.@policy[0].src_addr=192.168.40.0/24
pbr.@policy[1]=policy
pbr.@policy[1].name=vault-via-vpn
pbr.@policy[1].src_addr=10.20.30.0/24
EOF
tw_pbr_set_vault_net "10.20.31.0/24" && got=changed || got=same
check pbr-changed "$got" "changed"
check pbr-vault "$(uci -q get 'pbr.@policy[1].src_addr')" "10.20.31.0/24"
check pbr-other "$(uci -q get 'pbr.@policy[0].src_addr')" "192.168.40.0/24"
tw_pbr_set_vault_net "10.20.31.0/24" && got=changed || got=same
check pbr-repeat "$got" "same"

echo "PASS: vault dns ($PASS assertions)"
