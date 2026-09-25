#!/bin/sh
# Tests tw-portal: offline -> DNAT port 80 from lan to the router + probe
# pages; uplink (even captive) -> no rules. Idempotent, derived every run.
# Run: sh travelwizard/tests/test-portal.sh
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../feed/travelwizard/files/usr/sbin/tw-portal"

PASS=0
ok() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/www"

# Stub uci: fixed lan net, firewall with/without the include (env FW_INC),
# and a call log for add/set/commit/delete assertions.
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
echo "uci $*" >>"$UCI_LOG"
case "$1" in
	-q) [ "$2" = "get" ] || exit 1
		case "$3" in
			network.lan.device) echo "br-lan" ;;
			network.lan.ipaddr) echo "192.168.40.1" ;;
			firewall.cfg99.fw4_compatible) [ "$FW_INC" = "2" ] && echo 1 ;;
			*) exit 1 ;;
		esac ;;
	show) case "$2" in
		firewall) [ "$FW_INC" = "1" ] || [ "$FW_INC" = "2" ] && {
			echo "firewall.cfg99=include"
			echo "firewall.cfg99.path='/usr/lib/travelwizard/fw-portal.sh'"
			} ;;
		dhcp) echo "dhcp.@dnsmasq[0]=dnsmasq"
			# real uci-show shape: one line, space-separated quoted values
			line=""
			for v in $DHCP_ADDRS; do line="$line '$v'"; done
			[ -n "$line" ] && echo "dhcp.@dnsmasq[0].address=$line" ;;
	esac
	exit 0 ;;
	add) echo "cfg99" ;;
	set|delete|commit|add_list|del_list) exit 0 ;;
	*) exit 1 ;;
esac
EOF
# Stub dnsmasq init: log restarts.
cat >"$TMP/bin/dnsmasq-init" <<'EOF'
#!/bin/sh
echo "dnsmasq $*" >>"$DNS_LOG"
EOF
# Stub ubus+jsonfilter: $TW_LINK_UP names the interface that is up (else none).
cat >"$TMP/bin/ubus" <<'EOF'
#!/bin/sh
echo "iface=$2"
EOF
cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
[ "$(cat)" = "iface=network.interface.$TW_LINK_UP" ] && echo "true"
exit 0
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
# Stub nft: canned ruleset from $NFT_STATE for list, log for add/delete.
cat >"$TMP/bin/nft" <<'EOF'
#!/bin/sh
echo "nft $*" >>"$NFT_LOG"
if [ "$1" = "--handle" ]; then cat "$NFT_STATE" 2>/dev/null; fi
exit 0
EOF
chmod +x "$TMP/bin/"*
export UCI_LOG="$TMP/uci.log" NFT_LOG="$TMP/nft.log" NFT_STATE="$TMP/nft.rules"
export DNS_LOG="$TMP/dns.log" DHCP_ADDRS=""
export TW_PORTAL_WWW="$TMP/www"
export TW_DNSMASQ_INIT="$TMP/bin/dnsmasq-init"
export TW_COMMON="$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"
PATH="$TMP/bin:$PATH"; export PATH
: >"$NFT_STATE"

run() {
	: >"$UCI_LOG"; : >"$NFT_LOG"; : >"$DNS_LOG"
	sh "$SCRIPT" "$@"
}

# 1. offline, no rule, no include -> add rule + include + probe pages.
export TW_LINK_UP="" FW_INC="0"
OUT=$(run auto) || fail "auto exited nonzero"
[ "$OUT" = '{"portal":true,"uplink":""}' ] || fail "json: [$OUT]"
ok
grep -q 'nft add rule inet fw4 dstnat iifname "br-lan" tcp dport 80 redirect to :80 comment "tw-portal"' \
	"$NFT_LOG" || fail "no nft add: [$(cat "$NFT_LOG")]"
ok
grep -q 'uci add firewall include' "$UCI_LOG" || fail "no include add: [$(cat "$UCI_LOG")]"
ok
grep -q 'uci set firewall.cfg99.fw4_compatible=1' "$UCI_LOG" \
	|| fail "include not fw4_compatible: [$(cat "$UCI_LOG")]"
ok
for f in generate_204 gen_204 hotspot-detect.html redirect connecttest.txt ncsi.txt success.txt; do
	[ -f "$TMP/www/$f" ] || fail "probe page $f missing"
	grep -q 'http://192.168.40.1/cgi-bin/luci/admin/travelwizard' "$TMP/www/$f" \
		|| fail "probe page $f has no wizard URL"
done
ok

# 2. offline, rule already there -> idempotent (no add, no file rewrite).
cat >"$NFT_STATE" <<'EOF'
		iifname "br-lan" tcp dport 80 redirect to :80 comment "tw-portal" # handle 7
EOF
BEFORE=$(ls -i "$TMP/www/generate_204" | awk '{ print $1 }')
OUT=$(run auto) || fail "auto exited nonzero"
grep -q 'nft add rule' "$NFT_LOG" && fail "duplicate add: [$(cat "$NFT_LOG")]"
ok
AFTER=$(ls -i "$TMP/www/generate_204" | awk '{ print $1 }')
[ "$BEFORE" = "$AFTER" ] || fail "probe page rewritten needlessly"
ok

# 3. uplink up, rule present -> delete by handle, keep include.
export TW_LINK_UP="wwan" FW_INC="1"
OUT=$(run auto) || fail "auto exited nonzero"
[ "$OUT" = '{"portal":false,"uplink":"wwan"}' ] || fail "json: [$OUT]"
ok
grep -q 'nft delete rule inet fw4 dstnat handle 7' "$NFT_LOG" \
	|| fail "no delete by handle: [$(cat "$NFT_LOG")]"
ok
grep -q 'uci add firewall include' "$UCI_LOG" && fail "include re-added: [$(cat "$UCI_LOG")]"
ok
# an include from an older version gains the fw4_compatible flag
grep -q 'uci set firewall.cfg99.fw4_compatible=1' "$UCI_LOG" \
	|| fail "old include not upgraded: [$(cat "$UCI_LOG")]"
ok
# with an uplink the probe pages are gone (no false "captive" answers)
[ -z "$(ls "$TMP/www")" ] || fail "probe pages left online: [$(ls "$TMP/www")]"
ok

# 4. uplink up, no rule, flagged include -> silent no-op; a page that is
# not ours is never touched.
: >"$NFT_STATE"
export FW_INC="2"
echo "someone else's page" >"$TMP/www/success.txt"
OUT=$(run auto) || fail "auto exited nonzero"
grep -q 'nft \(add\|delete\)' "$NFT_LOG" && fail "unexpected nft: [$(cat "$NFT_LOG")]"
ok
grep -q 'uci \(set\|commit\) firewall' "$UCI_LOG" && fail "include churn: [$(cat "$UCI_LOG")]"
ok
[ "$(cat "$TMP/www/success.txt")" = "someone else's page" ] || fail "foreign page removed"
ok
export TW_LINK_UP=""
OUT=$(run auto) || fail "auto exited nonzero"
[ "$(cat "$TMP/www/success.txt")" = "someone else's page" ] || fail "foreign page overwritten"
ok
rm -f "$TMP/www/success.txt"
export TW_LINK_UP="wwan"

# 5. status reports without changing anything.
cat >"$NFT_STATE" <<'EOF'
		iifname "br-lan" tcp dport 80 redirect to :80 comment "tw-portal" # handle 9
EOF
export TW_LINK_UP=""
OUT=$(run status) || fail "status exited nonzero"
[ "$OUT" = '{"portal":true,"uplink":""}' ] || fail "json: [$OUT]"
ok
grep -q 'nft \(add\|delete\)' "$NFT_LOG" && fail "status changed nft: [$(cat "$NFT_LOG")]"
ok

# 6. uninstall removes rule + include + probe pages.
export FW_INC="1"
run auto >/dev/null # offline: pages are back
[ -f "$TMP/www/generate_204" ] || fail "probe pages not restored offline"
ok
run uninstall >/dev/null || fail "uninstall exited nonzero"
grep -q 'nft delete rule inet fw4 dstnat handle 9' "$NFT_LOG" \
	|| fail "no delete: [$(cat "$NFT_LOG")]"
ok
grep -q 'uci delete firewall.cfg99' "$UCI_LOG" || fail "no include delete: [$(cat "$UCI_LOG")]"
ok
[ -z "$(ls "$TMP/www")" ] || fail "probe pages left: [$(ls "$TMP/www")]"
ok

# 7. the fw4 include just runs tw-portal auto and never fails.
cat >"$TMP/bin/tw-portal" <<'EOF'
#!/bin/sh
echo "tw-portal $*" >>"$FW_LOG"
exit 0
EOF
chmod +x "$TMP/bin/tw-portal"
export FW_LOG="$TMP/fw.log"
TW_PORTAL_BIN="$TMP/bin/tw-portal" \
	sh "$HERE/../feed/travelwizard/files/usr/lib/travelwizard/fw-portal.sh" \
	|| fail "fw-portal.sh exited nonzero"
grep -q 'tw-portal auto' "$FW_LOG" || fail "fw include did not run auto"
ok

# 8. offline + no hijack -> add catch-all, restart once.
# (include already flagged from here on: the stub uci never persists it)
export TW_LINK_UP="" FW_INC="2" DHCP_ADDRS=""
: >"$NFT_STATE"
OUT=$(run auto) || fail "auto exited nonzero"
grep -q 'uci add_list dhcp.@dnsmasq\[0\].address=/#/192.168.40.1' "$UCI_LOG" \
	|| fail "no dns add: [$(cat "$UCI_LOG")]"
ok
[ "$(grep -c 'dnsmasq restart' "$DNS_LOG")" = "1" ] \
	|| fail "expected 1 restart: [$(cat "$DNS_LOG")]"
ok

# 9. offline + correct hijack -> silent (no churn, no restart).
export DHCP_ADDRS="/#/192.168.40.1"
OUT=$(run auto) || fail "auto exited nonzero"
grep -q 'uci \(add_list\|del_list\|commit\)' "$UCI_LOG" \
	&& fail "unexpected uci churn: [$(cat "$UCI_LOG")]"
ok
[ ! -s "$DNS_LOG" ] || fail "unexpected restart: [$(cat "$DNS_LOG")]"
ok

# 10. offline + stale hijack + custom entry -> swap stale, keep custom.
export DHCP_ADDRS="/#/10.0.0.9 /example.com/1.2.3.4"
OUT=$(run auto) || fail "auto exited nonzero"
grep -q 'uci del_list dhcp.@dnsmasq\[0\].address=/#/10.0.0.9' "$UCI_LOG" \
	|| fail "stale not removed: [$(cat "$UCI_LOG")]"
ok
grep -q 'example.com' "$UCI_LOG" && fail "custom entry touched: [$(cat "$UCI_LOG")]"
ok
grep -q 'uci add_list dhcp.@dnsmasq\[0\].address=/#/192.168.40.1' "$UCI_LOG" \
	|| fail "current not added: [$(cat "$UCI_LOG")]"
ok
[ "$(grep -c 'dnsmasq restart' "$DNS_LOG")" = "1" ] || fail "no restart"
ok

# 11. uplink up + hijack present -> remove, restart once.
export TW_LINK_UP="wwan" DHCP_ADDRS="/#/192.168.40.1"
OUT=$(run auto) || fail "auto exited nonzero"
[ "$OUT" = '{"portal":false,"uplink":"wwan"}' ] || fail "json: [$OUT]"
ok
grep -q 'uci del_list dhcp.@dnsmasq\[0\].address=/#/192.168.40.1' "$UCI_LOG" \
	|| fail "hijack not removed: [$(cat "$UCI_LOG")]"
ok
[ "$(grep -c 'dnsmasq restart' "$DNS_LOG")" = "1" ] || fail "no restart"
ok

# 12. uplink up + no hijack -> silent.
export DHCP_ADDRS=""
OUT=$(run auto) || fail "auto exited nonzero"
[ ! -s "$DNS_LOG" ] || fail "unexpected restart: [$(cat "$DNS_LOG")]"
ok

# 13. offline + duplicated hijack -> collapse to one, restart once.
export TW_LINK_UP="" FW_INC="1" DHCP_ADDRS="/#/192.168.40.1 /#/192.168.40.1"
: >"$NFT_STATE"
OUT=$(run auto) || fail "auto exited nonzero"
grep -q 'uci del_list dhcp.@dnsmasq\[0\].address=/#/192.168.40.1' "$UCI_LOG" \
	|| fail "dupe not collapsed: [$(cat "$UCI_LOG")]"
ok
grep -q 'uci add_list' "$UCI_LOG" && fail "re-added dupe: [$(cat "$UCI_LOG")]"
ok
[ "$(grep -c 'dnsmasq restart' "$DNS_LOG")" = "1" ] || fail "no restart"
ok

# 14. uninstall clears the hijack too.
export TW_LINK_UP="" DHCP_ADDRS="/#/192.168.40.1"
run uninstall >/dev/null || fail "uninstall exited nonzero"
grep -q 'uci del_list dhcp.@dnsmasq\[0\].address=/#/192.168.40.1' "$UCI_LOG" \
	|| fail "hijack left behind: [$(cat "$UCI_LOG")]"
ok

echo "PASS: portal ($PASS assertions)"
