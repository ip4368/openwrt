#!/bin/sh
# Tests tw_kill_holding (vault kill-switch audit) against stubbed firewall
# configs: intact vs a vault->wan forwarding hole, an ACCEPT-rule hole,
# a lax zone policy, and a missing vault zone.
# Run: sh travelwizard/tests/test-kill-switch.sh
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
# stub: 'show firewall' dumps $STUB_FW; '-q get key' looks the key up in it
if [ "$1" = "show" ]; then cat "$STUB_FW"; exit 0; fi
[ "$1" = "-q" ] && [ "$2" = "get" ] || exit 1
grep -F "$3=" "$STUB_FW" | head -n 1 \
	| sed "s/^[^=]*=//; s/^'\(.*\)'$/\1/"
exit 0
EOF
chmod +x "$TMP/bin/uci"
PATH="$TMP/bin:$PATH"; export PATH

holds() { # $1 label $2 fixture: expect tw_kill_holding true
	STUB_FW="$2"; export STUB_FW
	tw_kill_holding && got=yes || got=no
	check "$1" "$got" "yes"
}
fails() { # $1 label $2 fixture: expect tw_kill_holding false
	STUB_FW="$2"; export STUB_FW
	tw_kill_holding && got=yes || got=no
	check "$1" "$got" "no"
}

cat >"$TMP/fw-ok.txt" <<'EOF'
firewall.@zone[2]=zone
firewall.@zone[2].name='vpn'
firewall.@zone[3]=zone
firewall.@zone[3].name='vault'
firewall.@zone[3].input='REJECT'
firewall.@zone[3].forward='REJECT'
firewall.@forwarding[1]=forwarding
firewall.@forwarding[1].src='vault'
firewall.@forwarding[1].dest='vpn'
firewall.@rule[10]=rule
firewall.@rule[10].name='Allow vault DNS'
firewall.@rule[10].src='vault'
firewall.@rule[10].dest_port='53'
firewall.@rule[10].target='ACCEPT'
EOF
holds intact "$TMP/fw-ok.txt"

cat >"$TMP/fw-fwd.txt" <<'EOF'
firewall.@zone[3]=zone
firewall.@zone[3].name='vault'
firewall.@zone[3].forward='REJECT'
firewall.@forwarding[1]=forwarding
firewall.@forwarding[1].src='vault'
firewall.@forwarding[1].dest='vpn'
firewall.@forwarding[2]=forwarding
firewall.@forwarding[2].src='vault'
firewall.@forwarding[2].dest='wan'
EOF
fails forwarding-hole "$TMP/fw-fwd.txt"

cat >"$TMP/fw-rule.txt" <<'EOF'
firewall.@zone[3]=zone
firewall.@zone[3].name='vault'
firewall.@zone[3].forward='REJECT'
firewall.@rule[9]=rule
firewall.@rule[9].name='oops'
firewall.@rule[9].src='vault'
firewall.@rule[9].dest='wan'
firewall.@rule[9].target='ACCEPT'
EOF
fails accept-rule-hole "$TMP/fw-rule.txt"

cat >"$TMP/fw-policy.txt" <<'EOF'
firewall.@zone[3]=zone
firewall.@zone[3].name='vault'
firewall.@zone[3].forward='ACCEPT'
EOF
fails lax-policy "$TMP/fw-policy.txt"

cat >"$TMP/fw-missing.txt" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name='lan'
firewall.@zone[0].forward='ACCEPT'
EOF
fails missing-zone "$TMP/fw-missing.txt"

# Named (non-@) sections with a DROP policy also hold, and a REJECT
# rule toward wan is not a hole.
cat >"$TMP/fw-ok2.txt" <<'EOF'
firewall.vault=zone
firewall.vault.name='vault'
firewall.vault.forward='DROP'
firewall.fw1=forwarding
firewall.fw1.src='vault'
firewall.fw1.dest='vpn'
firewall.r1=rule
firewall.r1.src='vault'
firewall.r1.dest='wan'
firewall.r1.target='REJECT'
EOF
holds named-sections-drop "$TMP/fw-ok2.txt"

echo "PASS: kill switch ($PASS assertions)"
