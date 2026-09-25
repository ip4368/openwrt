#!/bin/sh
# Tests tw_tunnel_routed: true only when a default route via the device
# exists (pbr policy installed); bare connected routes do not count.
# Run: sh travelwizard/tests/test-tunnel-route.sh
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
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
# stub: replays the canned table named by $STUB_TABLE
cat "$STUB_TABLE"
EOF
chmod +x "$TMP/bin/ip"
PATH="$TMP/bin:$PATH"; export PATH

routed() { # $1 label $2 fixture $3 dev: expect true
	STUB_TABLE="$2"; export STUB_TABLE
	tw_tunnel_routed "$3" && got=yes || got=no
	check "$1" "$got" "yes"
}
unrouted() { # $1 label $2 fixture $3 dev: expect false
	STUB_TABLE="$2"; export STUB_TABLE
	tw_tunnel_routed "$3" && got=yes || got=no
	check "$1" "$got" "no"
}

cat >"$TMP/pbr.txt" <<'EOF'
default via 192.168.1.1 dev eth1
10.20.30.0/24 dev br-vault scope link
172.19.0.0/30 dev tun0 scope link
default dev tun0 table 30001
EOF
routed pbr-default "$TMP/pbr.txt" tun0

cat >"$TMP/connected-only.txt" <<'EOF'
default via 192.168.1.1 dev eth1
172.19.0.0/30 dev tun0 scope link
EOF
unrouted connected-only "$TMP/connected-only.txt" tun0

cat >"$TMP/other-dev.txt" <<'EOF'
default via 192.168.1.1 dev eth1
default dev tw_wg table 30001
EOF
unrouted other-device "$TMP/other-dev.txt" tun0
routed wireguard-device "$TMP/other-dev.txt" tw_wg

cat >"$TMP/prefix-match.txt" <<'EOF'
default dev tun0extra table 30001
EOF
unrouted no-prefix-match "$TMP/prefix-match.txt" tun0

echo "PASS: tunnel route ($PASS assertions)"
