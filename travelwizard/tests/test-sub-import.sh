#!/bin/sh
# Tests tw-sub-import: multi-link import with tags sidecar, no unproxied
# "direct" exit, TW_DEFAULT_TAG override, nested https subscription
# following, base64 bodies, fetch retries with honest errors, input
# trimming, and the unsupported-types diagnostic. Run: sh travelwizard/tests/test-sub-import.sh
HERE=$(cd "$(dirname "$0")" && pwd)
IMPORT="$HERE/../feed/travelwizard/files/usr/sbin/tw-sub-import"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
# stub: last arg is the URL; body chosen by URL substring via env.
# *flaky* fails CURL_FAIL_N times first; every call is logged.
for a in "$@"; do url="$a"; done
echo "$url" >>"$CURL_LOG"
case "$url" in
	*flaky*)
		c=$(cat "$CURL_CNT" 2>/dev/null || echo 0); c=$((c + 1))
		echo "$c" >"$CURL_CNT"
		[ "$c" -le "${CURL_FAIL_N:-0}" ] && exit 22
		cat "$STUB_NESTED" ;;
	*nested*) cat "$STUB_NESTED" ;;
	*direct*) cat "$STUB_DIRECT" ;;
	*) exit 22 ;;
esac
EOF
cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
# stub: jsonfilter -e '@.field' < json
exec python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1][2:], ""))' "$2"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/jsonfilter"
PATH="$TMP/bin:$PATH"; export PATH

VLESS='vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?security=tls&sni=example.com&type=tcp#Server%20One'
TROJAN='trojan://secret@203.0.113.11:443?sni=example.org#Server-Two'
SS='ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@203.0.113.12:8388#ServerThree'

# 1. multi-link import via stdin
printf '%s\n%s\n%s\n' "$VLESS" "$TROJAN" "$SS" \
	| sh "$IMPORT" - "$TMP/out/t1.json" >/dev/null 2>&1
check t1-tags "$(tr '\n' ' ' <"$TMP/out/t1.tags" | sed 's/ $//')" \
	"Server One Server-Two ServerThree"
check t1-default "$(grep -o '"default":"[^"]*"' "$TMP/out/t1.json")" \
	'"default":"Server One"'
check t1-selector "$(grep -o '"outbounds":\["[^]]*\]' "$TMP/out/t1.json")" \
	'"outbounds":["Server One","Server-Two","ServerThree"]'
# the selector must never offer an unproxied exit
check t1-no-direct "$(grep -c '"direct"' "$TMP/out/t1.json")" "0"
check t1-src-lines "$(wc -l <"$TMP/out/t1.src" | tr -d ' ')" "3"
check t1-stack "$(grep -o '"stack":"[a-z]*"' "$TMP/out/t1.json")" \
	'"stack":"gvisor"'
# outbounds must not restrict the network: "network":"tcp" would disable
# UDP outright (verified live: vault DNS dies, XUDP never engages)
check t1-no-netlimit "$(grep -c '"network":"tcp"' "$TMP/out/t1.json")" "0"
# tag -> source-link index for per-endpoint probing
check t1-map-tags "$(cut -f1 "$TMP/out/t1.map" | tr '\n' ' ' | sed 's/ $//')" \
	"Server One Server-Two ServerThree"
check t1-map-link "$(awk -F'\t' 'NR==1{print $2}' "$TMP/out/t1.map" | grep -c '^vless://')" "1"
check t1-map-lines "$(wc -l <"$TMP/out/t1.map" | tr -d ' ')" "3"

# 2. TW_DEFAULT_TAG override picks another server
printf '%s\n%s\n' "$VLESS" "$TROJAN" \
	| TW_DEFAULT_TAG="Server-Two" sh "$IMPORT" - "$TMP/out/t2.json" >/dev/null 2>&1
check t2-default "$(grep -o '"default":"[^"]*"' "$TMP/out/t2.json")" \
	'"default":"Server-Two"'

# 3. nested https subscription URL is followed (curl stubbed)
printf 'https://provider.example/nested\n' >"$TMP/top.txt"
printf '%s\n' "$SS" >"$TMP/nested-body.txt"
STUB_NESTED="$TMP/nested-body.txt"; export STUB_NESTED
sh "$IMPORT" - "$TMP/out/t3.json" <"$TMP/top.txt" >/dev/null 2>&1
check t3-tags "$(cat "$TMP/out/t3.tags")" "ServerThree"

# 4. base64-wrapped subscription body is unwrapped
printf '%s\n%s\n' "$VLESS" "$TROJAN" | base64 | tr -d '\n' >"$TMP/b64.txt"
sh "$IMPORT" - "$TMP/out/t4.json" <"$TMP/b64.txt" >/dev/null 2>&1
check t4-tags "$(tr '\n' ' ' <"$TMP/out/t4.tags" | sed 's/ $//')" \
	"Server One Server-Two"

# 5. unsupported-only input reports the offending schemes (never queued,
# so never fetched: no network involved)
printf 'foo://bar\nquux://x\n' \
	| sh "$IMPORT" - "$TMP/out/t5.json" 2>/dev/null >"$TMP/t5.out"; :
check t5-error "$(cat "$TMP/t5.out")" \
	'{"error":"no supported links (found only unsupported types: foo,quux)"}'

# 10. flaky main fetch recovers via retry (attempts logged)
export CURL_LOG="$TMP/curl.log" CURL_CNT="$TMP/curl.cnt"
printf '%s\n' "$SS" >"$TMP/nested-body.txt"
STUB_NESTED="$TMP/nested-body.txt"; export STUB_NESTED
: >"$CURL_LOG"; rm -f "$CURL_CNT"
CURL_FAIL_N=2 TW_FETCH_RETRIES=3 TW_FETCH_SLEEP=0 \
	sh "$IMPORT" 'https://provider.example/flaky' "$TMP/out/t10.json" >/dev/null 2>&1
check t10-tags "$(cat "$TMP/out/t10.tags")" "ServerThree"
check t10-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "3"

# 11. persistently failing main fetch errors after its retries
: >"$CURL_LOG"
TW_FETCH_RETRIES=2 TW_FETCH_SLEEP=0 \
	sh "$IMPORT" 'https://provider.example/nonexistent' "$TMP/out/t11.json" \
	2>/dev/null >"$TMP/t11.out"; :
check t11-error "$(cat "$TMP/t11.out")" \
	'{"error":"subscription fetch failed (unreachable or HTTP error)"}'
check t11-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "2"

# 12. nested links that cannot be fetched get an honest error (not
# "unsupported types"), after retries
: >"$CURL_LOG"
printf 'https://provider.example/dead\n' \
	| TW_FETCH_RETRIES=2 TW_FETCH_SLEEP=0 sh "$IMPORT" - "$TMP/out/t12.json" \
	2>/dev/null >"$TMP/t12.out"; :
check t12-error "$(cat "$TMP/t12.out")" \
	'{"error":"found 1 nested subscription link(s) but none could be fetched (network error); try again"}'
check t12-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "2"

# 13. leading/trailing whitespace does not demote a URL to the nested path
printf '%s\n' "$TROJAN" >"$TMP/direct-body.txt"
STUB_DIRECT="$TMP/direct-body.txt"; export STUB_DIRECT
: >"$CURL_LOG"
TW_FETCH_SLEEP=0 sh "$IMPORT" '  https://provider.example/direct  ' \
	"$TMP/out/t13.json" >/dev/null 2>&1
check t13-tags "$(cat "$TMP/out/t13.tags")" "Server-Two"
check t13-trimmed "$(cat "$CURL_LOG")" "https://provider.example/direct"

# 6. TW_INBOUND=socks emits a loopback SOCKS probe config (no TUN)
printf '%s\n' "$SS" \
	| TW_INBOUND=socks TW_SOCKS_PORT=19801 sh "$IMPORT" - "$TMP/out/t6.json" >/dev/null 2>&1
check t6-socks "$(grep -c '"type":"socks"' "$TMP/out/t6.json")" "1"
check t6-port "$(grep -o '"listen_port":[0-9]*' "$TMP/out/t6.json")" \
	'"listen_port":19801'
check t6-no-tun "$(grep -c '"type":"tun"' "$TMP/out/t6.json")" "0"

# 7. a non-numeric probe port falls back to 18080 (no JSON injection)
printf '%s\n' "$SS" \
	| TW_INBOUND=socks TW_SOCKS_PORT='1,"x"' sh "$IMPORT" - "$TMP/out/t7.json" >/dev/null 2>&1
check t7-port "$(grep -o '"listen_port":[0-9]*' "$TMP/out/t7.json")" \
	'"listen_port":18080'

# 8. port 53 is hijacked into DNS-over-TCP through the proxy, while each
# outbound resolves its own server name via the system resolver (without
# that, a domain-name endpoint can never resolve: DNS needs the proxy,
# the proxy needs DNS)
check t8-dns-server "$(grep -o '"type":"tcp","server":"[0-9.]*","detour":"proxy"' "$TMP/out/t1.json")" \
	'"type":"tcp","server":"1.1.1.1","detour":"proxy"'
check t8-dns-local "$(grep -c '"tag":"local-dns","type":"local"' "$TMP/out/t1.json")" "1"
check t8-dns-rule "$(grep -o '{"port":53,"action":"hijack-dns"}' "$TMP/out/t1.json")" \
	'{"port":53,"action":"hijack-dns"}'
check t8-no-dns-out "$(grep -c 'dns-out' "$TMP/out/t1.json")" "0"
check t8-resolver "$(grep -c '"domain_resolver":"local-dns"' "$TMP/out/t1.json")" "3"
check t8-json "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("valid")' "$TMP/out/t1.json")" \
	"valid"

# 9. TW_DNS_SERVER override is honored; garbage falls back to 1.1.1.1
printf '%s\n' "$SS" \
	| TW_DNS_SERVER=9.9.9.9 sh "$IMPORT" - "$TMP/out/t9.json" >/dev/null 2>&1
check t9-override "$(grep -o '"type":"tcp","server":"[0-9.]*"' "$TMP/out/t9.json")" \
	'"type":"tcp","server":"9.9.9.9"'
printf '%s\n' "$SS" \
	| TW_DNS_SERVER='1.1.1.1","x' sh "$IMPORT" - "$TMP/out/t9b.json" >/dev/null 2>&1
check t9-fallback "$(grep -o '"type":"tcp","server":"[0-9.]*"' "$TMP/out/t9b.json")" \
	'"type":"tcp","server":"1.1.1.1"'

# 14. a config that fails sing-box check never replaces the working one
# (nor its sidecars); a passing one replaces all four files
cat >"$TMP/bin/sb-reject" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$TMP/bin/sb-accept" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/sb-reject" "$TMP/bin/sb-accept"
cp "$TMP/out/t1.json" "$TMP/out/t14.json"
cp "$TMP/out/t1.tags" "$TMP/out/t14.tags"
cp "$TMP/out/t1.map" "$TMP/out/t14.map"
cp "$TMP/out/t1.src" "$TMP/out/t14.src"
printf '%s\n' "$TROJAN" | TW_SINGBOX_BIN=sb-reject \
	sh "$IMPORT" - "$TMP/out/t14.json" 2>/dev/null >"$TMP/t14.out"; :
check t14-error "$(cat "$TMP/t14.out")" \
	'{"error":"generated config failed sing-box check"}'
check t14-config-kept "$(cmp -s "$TMP/out/t1.json" "$TMP/out/t14.json" && echo same)" "same"
check t14-tags-kept "$(tr '\n' ' ' <"$TMP/out/t14.tags" | sed 's/ $//')" \
	"Server One Server-Two ServerThree"
check t14-map-kept "$(wc -l <"$TMP/out/t14.map" | tr -d ' ')" "3"
check t14-no-litter "$(ls "$TMP/out" | grep -c '\.new\.')" "0"
printf '%s\n' "$TROJAN" | TW_SINGBOX_BIN=sb-accept \
	sh "$IMPORT" - "$TMP/out/t14.json" >"$TMP/t14.out" 2>/dev/null
check t14-checked "$(grep -o '"checked":[a-z]*' "$TMP/t14.out")" '"checked":true'
check t14-replaced "$(cat "$TMP/out/t14.tags")" "Server-Two"
check t14-src "$(wc -l <"$TMP/out/t14.src" | tr -d ' ')" "1"
check t14-mode "$(ls -l "$TMP/out/t14.json" | cut -c1-10)" "-rw-------"

echo "PASS: sub import ($PASS assertions)"
