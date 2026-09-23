#!/bin/sh
# Tests tw_active_mode resolution (active profile wins, else legacy mode,
# else off) with a stubbed uci. Run: sh travelwizard/tests/test-active-mode.sh
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
# stub: uci -q get travelwizard.<sec>.<opt>, driven by env
[ "$1" = "-q" ] && [ "$2" = "get" ] || exit 1
key="$3"
case "$key" in
	travelwizard.main.active_profile) printf '%s' "$STUB_ACTIVE" ;;
	travelwizard.main.vpn_mode) printf '%s' "${STUB_MODE:-off}" ;;
	travelwizard.*.type)
		sec=${key#travelwizard.}; sec=${sec%.type}
		[ "$sec" = "$STUB_SEC" ] && printf '%s' "$STUB_TYPE" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/uci"
PATH="$TMP/bin:$PATH"; export PATH

STUB_ACTIVE="p1" STUB_SEC="p1" STUB_TYPE="wireguard" STUB_MODE="off"
export STUB_ACTIVE STUB_SEC STUB_TYPE STUB_MODE
check active-wins "$(tw_active_mode)" "wireguard"

STUB_ACTIVE="p9" STUB_SEC="p1" STUB_TYPE="wireguard" STUB_MODE="singbox"
export STUB_ACTIVE STUB_SEC STUB_TYPE STUB_MODE
check missing-profile-falls-back "$(tw_active_mode)" "singbox"

STUB_ACTIVE="" STUB_MODE="openvpn"
export STUB_ACTIVE STUB_MODE
check legacy-used "$(tw_active_mode)" "openvpn"

STUB_ACTIVE="" STUB_MODE=""
export STUB_ACTIVE STUB_MODE
check default-off "$(tw_active_mode)" "off"

echo "PASS: active mode ($PASS assertions)"
