#!/bin/sh
# Captive detection regression tests with a fake curl responder.
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../feed/travelwizard/files/usr/sbin/tw-captive-check"

PASS=0
fail() { echo "FAIL: $1"; exit 1; }
has() {
	case "$2" in *"$3"*) PASS=$((PASS + 1)) ;; *) fail "$1: [$2] lacks [$3]" ;; esac
}
lacks() {
	case "$2" in *"$3"*) fail "$1: [$2] unexpectedly has [$3]" ;; *) PASS=$((PASS + 1)) ;; esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/jshn.sh" <<'EOF'
JSON=""
json_init() { JSON=""; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
json_add_string() {
	local key value
	key=$(json_escape "$1"); value=$(json_escape "$2")
	JSON="$JSON${JSON:+,}\"$key\":\"$value\""
}
json_dump() { printf '{%s}\n' "$JSON"; }
EOF

cat >"$TMP/common.sh" <<'EOF'
tw_upstream() { [ "${NO_UPSTREAM:-0}" = 1 ] && return 1; echo wwan; }
tw_l3dev() { echo phy1-sta0; }
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
body=/dev/null url="" iface=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) body=$2; shift 2 ;;
		--interface) iface=$2; shift 2 ;;
		-D|--max-time) shift 2 ;;
		-s) shift ;;
		*) url=$1; shift ;;
	esac
done
: >"$body"
printf '%s iface=%s\n' "$url" "$iface" >>"$CURL_LOG"
case "$SCENARIO:$url" in
	online204:*) printf 'HTTP/1.1 204 No Content\r\n\r\n' ;;
	apple:*gstatic*) echo 'operation timed out' >&2; exit 28 ;;
	apple:*apple*) printf 'Success' >"$body"; printf 'HTTP/1.1 200 OK\r\n\r\n' ;;
	huawei:*hicloud*) printf 'HTTP/1.1 204 No Content\r\n\r\n' ;;
	huawei:*) echo 'operation timed out' >&2; exit 28 ;;
	inline:*) printf '<html>Sign in</html>' >"$body"; printf 'HTTP/1.1 200 OK\r\n\r\n' ;;
	redirect:*) printf 'HTTP/1.1 307 Temporary Redirect\r\nLocation: https://hotel.test/login\r\n\r\n' ;;
	relative:*) printf 'HTTP/1.1 302 Found\r\nLOCATION: /portal/start?x=1\r\n\r\n' ;;
	pathrelative:*) printf 'HTTP/1.1 302 Found\r\nLocation: auth/start\r\n\r\n' ;;
	code511:*) printf 'HTTP/1.1 511 Network Authentication Required\r\n\r\n' ;;
	code511relative:*) printf 'HTTP/1.1 511 Network Authentication Required\r\nLocation: /authenticate\r\n\r\n' ;;
	offline:*) echo 'operation timed out' >&2; exit 28 ;;
	noreason:*) printf 'HTTP/1.1 204\r\n\r\n' ;;
	filtered:*gstatic*) printf 'HTTP/1.1 302 Found\r\nLocation: http://block.test/denied\r\n\r\n' ;;
	filtered:*apple*) printf 'Success' >"$body"; printf 'HTTP/1.1 200 OK\r\n\r\n' ;;
	portalpartial:*gstatic*) printf 'HTTP/1.1 307 Temporary Redirect\r\nLocation: https://hotel.test/login\r\n\r\n' ;;
	portalpartial:*) exit 28 ;;
	mixed:*gstatic*) exit 28 ;;
	mixed:*) exit 6 ;;
	dnsonly:*) exit 6 ;;
	*) exit 7 ;;
esac
EOF
chmod +x "$TMP/bin/curl"

export TW_JSHN="$TMP/jshn.sh" TW_COMMON="$TMP/common.sh" TW_CURL="$TMP/bin/curl"
export CURL_LOG="$TMP/curl.log"
run_case() {
	SCENARIO=$1; export SCENARIO
	: >"$CURL_LOG"
	sh "$SCRIPT"
}

out=$(run_case online204) || fail "204 run"
has "204 online" "$out" '"state":"online"'
has "primary tried" "$(cat "$CURL_LOG")" 'connectivitycheck.gstatic.com'
lacks "204 has no login" "$out" 'login_url'

out=$(run_case apple) || fail "Apple fallback run"
has "Apple fallback online" "$out" '"state":"online"'
has "Apple was tried" "$(cat "$CURL_LOG")" 'captive.apple.com'

out=$(run_case huawei) || fail "Huawei fallback run"
has "Huawei fallback online" "$out" '"state":"online"'
has "Huawei was tried" "$(cat "$CURL_LOG")" 'connectivitycheck.platform.hicloud.com'

out=$(run_case inline) || fail "inline run"
has "inline captive" "$out" '"state":"captive"'
has "inline original URL" "$out" '"login_url":"http://connectivitycheck.gstatic.com/generate_204"'

out=$(run_case redirect) || fail "redirect run"
has "redirect captive" "$out" '"state":"captive"'
has "absolute redirect" "$out" '"login_url":"https://hotel.test/login"'

out=$(run_case relative) || fail "relative run"
has "root-relative redirect" "$out" '"login_url":"http://connectivitycheck.gstatic.com/portal/start?x=1"'

out=$(run_case pathrelative) || fail "path-relative run"
has "path-relative redirect" "$out" '"login_url":"http://connectivitycheck.gstatic.com/auth/start"'

out=$(run_case code511) || fail "511 run"
has "511 captive" "$out" '"state":"captive"'
has "511 fallback URL" "$out" '"login_url":"http://connectivitycheck.gstatic.com/generate_204"'
has "511 detail" "$out" 'HTTP 511'

out=$(run_case code511relative) || fail "511 relative run"
has "511 relative URL" "$out" '"login_url":"http://connectivitycheck.gstatic.com/authenticate"'

out=$(run_case offline) || fail "offline run"
has "timeout offline" "$out" '"state":"offline"'
has "timeout class" "$out" '"failure":"timeout"'
has "timeout reason names first probe" "$out" 'connectivitycheck.gstatic.com: timed out'
has "timeout reason names last probe" "$out" 'connectivitycheck.platform.hicloud.com: timed out'
lacks "offline has no login" "$out" 'login_url'

out=$(run_case mixed) || fail "mixed failure run"
has "mixed offline" "$out" '"state":"offline"'
has "any timeout wins the class" "$out" '"failure":"timeout"'
has "mixed reason keeps DNS failures" "$out" 'captive.apple.com: DNS failed'

out=$(run_case dnsonly) || fail "DNS-only run"
has "DNS-only class" "$out" '"failure":"dns"'
lacks "DNS-only is not a timeout" "$out" 'timed out'

out=$(run_case noreason) || fail "no-reason-phrase run"
has "bare 204 status line is online" "$out" '"state":"online"'

out=$(run_case filtered) || fail "filtered run"
has "success beats a filtered probe" "$out" '"state":"online"'
lacks "filtered has no login" "$out" 'login_url'

out=$(run_case portalpartial) || fail "partial portal run"
has "portal evidence survives later timeouts" "$out" '"state":"captive"'
has "partial portal login" "$out" '"login_url":"https://hotel.test/login"'
lacks "captive has no failure class" "$out" '"failure"'

out=$(run_case online204) || fail "binding run"
has "probes bind the upstream device" "$(cat "$CURL_LOG")" 'iface=phy1-sta0'

NO_UPSTREAM=1; export NO_UPSTREAM
out=$(run_case online204) || fail "no-upstream run"
has "no upstream offline" "$out" '"state":"offline"'
has "no upstream reason" "$out" 'no upstream link'

echo "PASS: captive check ($PASS assertions)"
