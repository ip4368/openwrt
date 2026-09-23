#!/bin/sh
# Tests tw-sub-import: multi-link import with tags sidecar, no unproxied
# "direct" exit, TW_DEFAULT_TAG override, nested https subscription
# following, base64 bodies, and the unsupported-types diagnostic. Run: sh travelwizard/tests/test-sub-import.sh
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
# stub: last arg is the URL; body chosen by URL substring via env
for a in "$@"; do url="$a"; done
case "$url" in
	*nested*) cat "$STUB_NESTED" ;;
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

# 5. unsupported-only input reports the offending schemes
printf 'https://provider.example/dead\nfoo://bar\n' \
	| sh "$IMPORT" - "$TMP/out/t5.json" 2>/dev/null >"$TMP/t5.out"; :
check t5-error "$(cat "$TMP/t5.out")" \
	'{"error":"no supported links (found only unsupported types: foo,https)"}'

echo "PASS: sub import ($PASS assertions)"
