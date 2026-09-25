#!/bin/sh
# Tests tw_resolve_ipv4 against both nslookup output formats found in the
# wild (bind-tools and busybox): server lines must be skipped, the first
# real answer wins, failures yield nothing.
# Run: sh travelwizard/tests/test-resolve.sh
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
cat >"$TMP/bin/nslookup" <<'EOF'
#!/bin/sh
# stub: replays the canned output named by the queried host
cat "$STUB_NS_DIR/$1.txt"
EOF
chmod +x "$TMP/bin/nslookup"
PATH="$TMP/bin:$PATH"; export PATH
STUB_NS_DIR="$TMP/ns"; export STUB_NS_DIR
mkdir -p "$STUB_NS_DIR"

cat >"$STUB_NS_DIR/bind.txt" <<'EOF'
Server:		127.0.0.1
Address:	127.0.0.1:53

Non-authoritative answer:
Name:	api.ipify.org
Address: 104.26.13.205
Name:	api.ipify.org
Address: 104.26.12.205
EOF
check bind-format "$(tw_resolve_ipv4 bind)" "104.26.13.205"

cat >"$STUB_NS_DIR/busybox.txt" <<'EOF'
Server:    127.0.0.1
Address 1: 127.0.0.1

Name:      api.ipify.org
Address 1: 54.231.100.7
Address 2: 54.231.100.8
EOF
check busybox-format "$(tw_resolve_ipv4 busybox)" "54.231.100.7"

cat >"$STUB_NS_DIR/nx.txt" <<'EOF'
Server:		127.0.0.1
Address:	127.0.0.1:53

** server can't find nope.invalid: NXDOMAIN
EOF
check nxdomain-empty "$(tw_resolve_ipv4 nx)" ""

# tw_ns_answer: same formats, but with an explicit non-loopback server,
# whose address must never be mistaken for the answer.
cat >"$TMP/explicit-bind.txt" <<'EOF'
Server:		1.1.1.1
Address:	1.1.1.1#53

Non-authoritative answer:
Name:	example.com
Address: 93.184.215.14
EOF
check explicit-bind "$(tw_ns_answer <"$TMP/explicit-bind.txt")" \
	"93.184.215.14"

cat >"$TMP/explicit-busybox.txt" <<'EOF'
Server:    1.1.1.1
Address 1: 1.1.1.1

Name:      example.com
Address 1: 93.184.215.14
Address 2: 2606:2800:220:1:248:1893:25c8:1946
EOF
check explicit-busybox "$(tw_ns_answer <"$TMP/explicit-busybox.txt")" \
	"93.184.215.14"

cat >"$TMP/explicit-nx.txt" <<'EOF'
Server:		1.1.1.1
Address:	1.1.1.1#53

** server can't find nope.invalid: NXDOMAIN
EOF
check explicit-nxdomain-empty "$(tw_ns_answer <"$TMP/explicit-nx.txt")" ""

echo "PASS: resolve ($PASS assertions)"
