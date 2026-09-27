#!/bin/sh
# Tests tw-sub-import: multi-link import with tags sidecar, no unproxied
# "direct" exit, TW_DEFAULT_TAG override, nested https subscription
# following, base64 bodies, fetch retries with honest errors and per-attempt
# logging, input trimming, and the unsupported-types diagnostic.
# Run: sh travelwizard/tests/test-sub-import.sh
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
	*tlsflaky*)
		c=$(cat "$CURL_CNT" 2>/dev/null || echo 0); c=$((c + 1))
		echo "$c" >"$CURL_CNT"
		[ "$c" -le "${CURL_FAIL_N:-0}" ] && exit 60
		cat "$STUB_NESTED" ;;
	*flaky*)
		c=$(cat "$CURL_CNT" 2>/dev/null || echo 0); c=$((c + 1))
		echo "$c" >"$CURL_CNT"
		[ "$c" -le "${CURL_FAIL_N:-0}" ] && exit 22
		cat "$STUB_NESTED" ;;
	*nested*) cat "$STUB_NESTED" ;;
	*direct*) cat "$STUB_DIRECT" ;;
	*mark500*) printf 'TW_FETCH:500:0.002:0.000:0.000:0.150|203.0.113.9\n'; exit 22 ;;
	*marked*) cat "$STUB_DIRECT"; printf 'TW_FETCH:200:0.001:0.140:0.370:0.510|203.0.113.9\n' ;;
	*empty*) exit 0 ;;
	*) exit 22 ;;
esac
EOF
cat >"$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
# stub: jsonfilter -e '@.field' < json
exec python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1][2:], ""))' "$2"
EOF
cat >"$TMP/bin/logger" <<'EOF'
#!/bin/sh
# stub: record syslog lines instead of emitting them
: "${LOGGER_LOG:=/dev/null}"
echo "$*" >>"$LOGGER_LOG"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/jsonfilter" "$TMP/bin/logger"
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
export CURL_LOG="$TMP/curl.log" CURL_CNT="$TMP/curl.cnt" LOGGER_LOG="$TMP/logger.log"
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
	'{"error":"subscription fetch failed (HTTP error)"}'
check t11-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "2"

# 12. nested links that cannot be fetched get an honest error (not
# "unsupported types"), after retries
: >"$CURL_LOG"
printf '# my subscriptions\nhttps://provider.example/dead\n' \
	| TW_FETCH_RETRIES=2 TW_FETCH_SLEEP=0 sh "$IMPORT" - "$TMP/out/t12.json" \
	2>/dev/null >"$TMP/t12.out"; :
check t12-error "$(cat "$TMP/t12.out")" \
	'{"error":"found 1 nested subscription link(s) but none could be fetched (HTTP error); try again"}'
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

# 8b. ICMP is dropped silently first: some proxy outbounds cannot carry it,
# and without the rule every ping logs an error each (phones probe Apple
# continuously)
check t8b-icmp-rule "$(grep -o '{"network":"icmp","action":"reject","method":"drop"}' "$TMP/out/t1.json")" \
	'{"network":"icmp","action":"reject","method":"drop"}'
check t8b-icmp-first "$(grep -c '"rules":\[{"network":"icmp"' "$TMP/out/t1.json")" "1"

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

# 15. naive/hysteria2/tuic links import with their sing-box outbounds
NAIVE='naive+https://user1:pass1@203.0.113.20:443?padding=true&sni=naive.example.com#Naive%20One'
HY2='hysteria2://hy2pass@203.0.113.21:8443?sni=hy2.example.com&up=100Mbps&down=200Mbps#Hy2%20One'
HY2B='hy2://hy2pass@203.0.113.22:8443?insecure=1#Hy2%20Two'
TUIC='tuic://11111111-2222-3333-4444-555555555555:tuicpass@203.0.113.23:443?sni=tuic.example.com&alpn=h3&congestion_control=bbr#Tuic%20One'
printf '%s\n%s\n%s\n%s\n' "$NAIVE" "$HY2" "$HY2B" "$TUIC" \
	| sh "$IMPORT" - "$TMP/out/t15.json" >/dev/null 2>&1
check t15-tags "$(tr '\n' ' ' <"$TMP/out/t15.tags" | sed 's/ $//')" \
	"Naive One Hy2 One Hy2 Two Tuic One"
check t15-naive "$(grep -o '"type":"naive","tag":"Naive One","server":"203.0.113.20","server_port":443,"username":"user1","password":"pass1"' "$TMP/out/t15.json")" \
	'"type":"naive","tag":"Naive One","server":"203.0.113.20","server_port":443,"username":"user1","password":"pass1"'
check t15-naive-sni "$(grep -o '"server_name":"naive.example.com"' "$TMP/out/t15.json" | head -n 1)" \
	'"server_name":"naive.example.com"'
check t15-hy2 "$(grep -o '"tag":"Hy2 One".*"up_mbps":100,"down_mbps":200' "$TMP/out/t15.json" | head -n 1 | grep -c up_mbps)" "1"
check t15-hy2-insecure "$(grep -o '"tag":"Hy2 Two".*"insecure":true' "$TMP/out/t15.json" | head -n 1 | grep -c insecure)" "1"
check t15-tuic "$(grep -o '"type":"tuic","tag":"Tuic One","server":"203.0.113.23","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","password":"tuicpass"' "$TMP/out/t15.json")" \
	'"type":"tuic","tag":"Tuic One","server":"203.0.113.23","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","password":"tuicpass"'
check t15-tuic-cc "$(grep -o '"congestion_control":"bbr"' "$TMP/out/t15.json")" \
	'"congestion_control":"bbr"'
check t15-tuic-alpn "$(grep -o '"alpn":\["h3"\]' "$TMP/out/t15.json")" '"alpn":["h3"]'
check t15-resolver "$(grep -c '"domain_resolver":"local-dns"' "$TMP/out/t15.json")" "4"
check t15-json "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("valid")' "$TMP/out/t15.json")" \
	"valid"

# 16. supported schemes with missing server/credentials report malformed,
# not "unsupported types"
printf 'vless://@#NoCreds\ntrojan://#NoServer\n' \
	| sh "$IMPORT" - "$TMP/out/t16.json" 2>/dev/null >"$TMP/t16.out"; :
check t16-error "$(cat "$TMP/t16.out")" \
	'{"error":"no usable links (malformed vless x1, trojan x1 link(s): missing server or credentials?)"}'

# 17. malformed + unsupported together name both
printf 'vless://@#Bad\nfoo://bar\n' \
	| sh "$IMPORT" - "$TMP/out/t17.json" 2>/dev/null >"$TMP/t17.out"; :
check t17-error "$(cat "$TMP/t17.out")" \
	'{"error":"no usable links (malformed: vless x1; unsupported types: foo)"}'

# 18. an unreachable nested URL no longer hides coexisting clues, and the
# nested URL itself is not misreported as an "unsupported type"
: >"$CURL_LOG"
printf 'https://provider.example/dead\nfoo://bar\nvless://@#Bad\n' \
	| TW_FETCH_RETRIES=1 TW_FETCH_SLEEP=0 sh "$IMPORT" - "$TMP/out/t18.json" \
	2>/dev/null >"$TMP/t18.out"; :
check t18-error "$(cat "$TMP/t18.out")" \
	'{"error":"found 1 nested subscription link(s) but none could be fetched (HTTP error); try again; also saw unsupported types: foo; also saw malformed vless x1 link(s)"}'

# 19. a sing-box build without the naive tag skips naive links (naming them)
# instead of failing the whole import
cat >"$TMP/bin/sb-no-naive" <<'EOF'
#!/bin/sh
# usage: sb-no-naive check -c FILE; mimics stock OpenWrt (no naive tag)
if grep -q '"type":"naive"' "$3" 2>/dev/null; then
	echo "FATAL initialize outbound: naive outbound is not included in this build" >&2
	exit 1
fi
exit 0
EOF
chmod +x "$TMP/bin/sb-no-naive"
printf '%s\n%s\n' "$NAIVE" "$VLESS" \
	| TW_SINGBOX_BIN=sb-no-naive sh "$IMPORT" - "$TMP/out/t19.json" \
	>"$TMP/t19.out" 2>/dev/null
check t19-count "$(grep -o '"count":[0-9]*' "$TMP/t19.out")" '"count":1'
check t19-tags "$(grep -o '"tags":\[[^]]*\]' "$TMP/t19.out")" '"tags":["Server One"]'
check t19-checked "$(grep -o '"checked":[a-z]*' "$TMP/t19.out")" '"checked":true'
check t19-skipped "$(grep -o '"skipped":\[[^]]*\]' "$TMP/t19.out")" \
	'"skipped":["naive+https x1 (not in this sing-box build)"]'
check t19-nouser "$(grep -c user1 "$TMP/out/t19.json")" "0"

# 20. the same input against a naive-capable build imports both endpoints
printf '%s\n%s\n' "$NAIVE" "$VLESS" \
	| TW_SINGBOX_BIN=sb-accept sh "$IMPORT" - "$TMP/out/t20.json" \
	>"$TMP/t20.out" 2>/dev/null
check t20-count "$(grep -o '"count":[0-9]*' "$TMP/t20.out")" '"count":2'
check t20-naive "$(grep -c '"type":"naive"' "$TMP/out/t20.json")" "1"
check t20-noskip "$(grep -c '"skipped"' "$TMP/t20.out")" "0"

# 21. unknown protocols are named in the success summary, not dropped silently
printf '%s\n%s\n' "$VLESS" 'ssr://user@203.0.113.30:443#Old' \
	| sh "$IMPORT" - "$TMP/out/t21.json" >"$TMP/t21.out" 2>/dev/null
check t21-count "$(grep -o '"count":[0-9]*' "$TMP/t21.out")" '"count":1'
check t21-skipped "$(grep -o '"skipped":\[[^]]*\]' "$TMP/t21.out")" '"skipped":["ssr x1"]'

# 22. a lone subscription URL on stdin (how the UI submits it) fetches
# directly like the URL argument: no bogus "https" skipped entry
printf '%s\n' "$TROJAN" >"$TMP/direct-body.txt"
STUB_DIRECT="$TMP/direct-body.txt"; export STUB_DIRECT
: >"$CURL_LOG"
printf 'https://provider.example/direct\n' \
	| TW_FETCH_SLEEP=0 sh "$IMPORT" - "$TMP/out/t22.json" >"$TMP/t22.out" 2>/dev/null
check t22-tags "$(cat "$TMP/out/t22.tags")" "Server-Two"
check t22-noskip "$(grep -c '"skipped"' "$TMP/t22.out")" "0"
check t22-calls "$(wc -l <"$CURL_LOG" | tr -d ' ')" "1"
check t22-url "$(cat "$CURL_LOG")" "https://provider.example/direct"

# 23. the same lone URL, unreachable, fails as a direct fetch (not nested)
: >"$CURL_LOG"
printf 'https://provider.example/dead\n' \
	| TW_FETCH_RETRIES=2 TW_FETCH_SLEEP=0 sh "$IMPORT" - "$TMP/out/t23.json" \
	2>/dev/null >"$TMP/t23.out"; :
check t23-error "$(cat "$TMP/t23.out")" \
	'{"error":"subscription fetch failed (HTTP error)"}'
check t23-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "2"

# 24. every failed attempt is logged with the curl rc + host for diagnosis
: >"$CURL_LOG"; : >"$LOGGER_LOG"
printf 'https://provider.example/dead\n' \
	| TW_FETCH_RETRIES=2 TW_FETCH_SLEEP=0 sh "$IMPORT" - "$TMP/out/t24.json" \
	2>/dev/null >"$TMP/t24.out"; :
check t24-logged "$(wc -l <"$LOGGER_LOG" | tr -d ' ')" "2"
check t24-rc "$(grep -c 'curl rc=22' "$LOGGER_LOG")" "2"
check t24-host "$(grep -c 'provider.example' "$LOGGER_LOG")" "2"

# 25. the -w marker yields the HTTP status in errors and logs
: >"$LOGGER_LOG"
TW_FETCH_RETRIES=1 TW_FETCH_SLEEP=0 sh "$IMPORT" 'https://provider.example/mark500' \
	"$TMP/out/t25.json" 2>/dev/null >"$TMP/t25.out"; :
check t25-error "$(cat "$TMP/t25.out")" \
	'{"error":"subscription fetch failed (HTTP 500)"}'
check t25-log "$(grep -c 'http=500' "$LOGGER_LOG")" "1"
check t25-timing "$(grep -c 't=0.002/0.000/0.000/0.150' "$LOGGER_LOG")" "1"
check t25-ip "$(grep -c 'ip=203.0.113.9' "$LOGGER_LOG")" "1"

# 26. the -w marker on success is stripped, never parsed as a link
printf '%s\n' "$TROJAN" >"$TMP/direct-body.txt"
STUB_DIRECT="$TMP/direct-body.txt"; export STUB_DIRECT
TW_FETCH_SLEEP=0 sh "$IMPORT" 'https://provider.example/marked' \
	"$TMP/out/t26.json" >"$TMP/t26.out" 2>/dev/null
check t26-tags "$(cat "$TMP/out/t26.tags")" "Server-Two"
check t26-noskip "$(grep -c '"skipped"' "$TMP/t26.out")" "0"

# 27. HTTP 200 with an empty body reports "empty response", not unreachable
TW_FETCH_RETRIES=1 TW_FETCH_SLEEP=0 sh "$IMPORT" 'https://provider.example/empty' \
	"$TMP/out/t27.json" 2>/dev/null >"$TMP/t27.out"; :
check t27-error "$(cat "$TMP/t27.out")" \
	'{"error":"subscription fetch failed (empty response)"}'

# 28. no retries by default: one attempt, loud failure, still logged
: >"$CURL_LOG"; : >"$LOGGER_LOG"
env -u TW_FETCH_RETRIES TW_FETCH_SLEEP=0 sh "$IMPORT" 'https://provider.example/dead' \
	"$TMP/out/t28.json" 2>/dev/null >"$TMP/t28.out"; :
check t28-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "1"
check t28-logged "$(wc -l <"$LOGGER_LOG" | tr -d ' ')" "1"
check t28-error "$(cat "$TMP/t28.out")" \
	'{"error":"subscription fetch failed (HTTP error)"}'

TLS_ERR='{"error":"subscription fetch failed (TLS error (certificate not trusted; if the router just started, wait for time sync and retry))"}'

# 29. TLS failure on a fresh-boot clock waits for sync instead of failing
printf '%s\n' "$SS" >"$TMP/nested-body.txt"
STUB_NESTED="$TMP/nested-body.txt"; export STUB_NESTED
: >"$CURL_LOG"; : >"$LOGGER_LOG"; rm -f "$CURL_CNT"
CURL_FAIL_N=2 TW_FW_EPOCH="$(date +%s)" TW_NTP_WAIT=30 TW_FETCH_SLEEP=0 \
	sh "$IMPORT" 'https://provider.example/tlsflaky' "$TMP/out/t29.json" >/dev/null 2>&1
check t29-tags "$(cat "$TMP/out/t29.tags")" "ServerThree"
check t29-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "3"
check t29-wait "$(grep -c 'kicking ntpd' "$LOGGER_LOG")" "1"
check t29-recovered "$(grep -c 'fetch recovered' "$LOGGER_LOG")" "1"

# 30. TLS failure with a sane clock fails fast (no NTP wait)
: >"$CURL_LOG"; : >"$LOGGER_LOG"; rm -f "$CURL_CNT"
CURL_FAIL_N=9 TW_FW_EPOCH=1 TW_FETCH_SLEEP=0 \
	sh "$IMPORT" 'https://provider.example/tlsflaky' "$TMP/out/t30.json" \
	2>/dev/null >"$TMP/t30.out"; :
check t30-error "$(cat "$TMP/t30.out")" "$TLS_ERR"
check t30-tries "$(wc -l <"$CURL_LOG" | tr -d ' ')" "1"
check t30-nokick "$(grep -c 'kicking ntpd' "$LOGGER_LOG")" "0"

# 31. the NTP wait is bounded: still failing after the cap errors out
: >"$CURL_LOG"; : >"$LOGGER_LOG"; rm -f "$CURL_CNT"
CURL_FAIL_N=99 TW_FW_EPOCH="$(date +%s)" TW_NTP_WAIT=4 TW_FETCH_SLEEP=0 \
	sh "$IMPORT" 'https://provider.example/tlsflaky' "$TMP/out/t31.json" \
	2>/dev/null >"$TMP/t31.out"; :
check t31-error "$(cat "$TMP/t31.out")" "$TLS_ERR"
check t31-kick "$(grep -c 'kicking ntpd' "$LOGGER_LOG")" "1"
check t31-probed "$([ "$(wc -l <"$CURL_LOG" | tr -d ' ')" -ge 2 ] && echo yes)" "yes"

# 32. anytls imports with TLS aliases (peer/insecure) and ALPN
ANYTLS='anytls://any%2Dsecret@203.0.113.15:443?peer=any.example.com&insecure=1&alpn=h2,http/1.1&min_idle_session=2#AnyTLS'
printf '%s\n' "$ANYTLS" | sh "$IMPORT" - "$TMP/out/t32.json" >"$TMP/t32.out" 2>/dev/null
check t32-count "$(grep -o '"count":[0-9]*' "$TMP/t32.out")" '"count":1'
check t32-shape "$(python3 -c '
import json, sys
o = {x["tag"]: x for x in json.load(open(sys.argv[1]))["outbounds"]}["AnyTLS"]
t = o["tls"]
print(o["type"], o["password"], o["server_port"], o["min_idle_session"],
      t["server_name"], t["insecure"], ",".join(t["alpn"]))
' "$TMP/out/t32.json")" "anytls any-secret 443 2 any.example.com True h2,http/1.1"

# 33. a sing-box build without anytls skips those links (naming them)
# instead of failing the whole import
cat >"$TMP/bin/sb-no-anytls" <<'EOF'
#!/bin/sh
if grep -q '"type":"anytls"' "$3" 2>/dev/null; then
	echo "FATAL decode config: outbounds[0].type: unknown outbound type: anytls" >&2
	exit 1
fi
exit 0
EOF
chmod +x "$TMP/bin/sb-no-anytls"
printf '%s\n%s\n' "$ANYTLS" "$VLESS" \
	| TW_SINGBOX_BIN=sb-no-anytls sh "$IMPORT" - "$TMP/out/t33.json" \
	>"$TMP/t33.out" 2>/dev/null
check t33-count "$(grep -o '"count":[0-9]*' "$TMP/t33.out")" '"count":1'
check t33-skipped "$(grep -o '"skipped":\[[^]]*\]' "$TMP/t33.out")" \
	'"skipped":["anytls x1 (not in this sing-box build)"]'

# 34. hysteria2: peer/allow_insecure aliases, "Mbps" with a space, ALPN;
# an obfs type sing-box does not know is dropped (it would fail the check)
HY2C='hy2://p%40ss@203.0.113.24:443?peer=h.example.com&allow_insecure=1&up=50%20Mbps&alpn=h3&obfs=xor&obfs-password=x#Hy2C'
HY2D='hy2://pw@203.0.113.25:443?obfs=salamander&obfs-password=salt#Hy2D'
printf '%s\n%s\n' "$HY2C" "$HY2D" | sh "$IMPORT" - "$TMP/out/t34.json" >/dev/null 2>&1
check t34-shape "$(python3 -c '
import json, sys
o = {x["tag"]: x for x in json.load(open(sys.argv[1]))["outbounds"]}
c, d = o["Hy2C"], o["Hy2D"]
print(c["password"], c["up_mbps"], c["tls"]["server_name"], c["tls"]["insecure"],
      c["tls"]["alpn"][0], "obfs" in c, d["obfs"]["type"], d["obfs"]["password"])
' "$TMP/out/t34.json")" "p@ss 50 h.example.com True h3 False salamander salt"

# 35. tuic: only valid congestion/udp modes pass through; cc alias works;
# a link without a password is malformed
TUICB='tuic://u1:p1@203.0.113.26:443?congestion_control=vegas&udp_relay_mode=quic#TuicB'
TUICC='tuic://u2:p2@203.0.113.27:443?cc=new_reno&udp_relay_mode=bogus#TuicC'
TUICD='tuic://u3@203.0.113.28:443#TuicD'
printf '%s\n%s\n%s\n' "$TUICB" "$TUICC" "$TUICD" \
	| sh "$IMPORT" - "$TMP/out/t35.json" >"$TMP/t35.out" 2>/dev/null
check t35-count "$(grep -o '"count":[0-9]*' "$TMP/t35.out")" '"count":2'
check t35-shape "$(python3 -c '
import json, sys
o = {x["tag"]: x for x in json.load(open(sys.argv[1]))["outbounds"]}
b, c = o["TuicB"], o["TuicC"]
print("congestion_control" in b, b["udp_relay_mode"], c["congestion_control"],
      "udp_relay_mode" in c)
' "$TMP/out/t35.json")" "False quic new_reno False"

echo "PASS: sub import ($PASS assertions)"
