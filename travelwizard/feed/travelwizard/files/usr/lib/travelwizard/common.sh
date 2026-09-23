# Shared helpers for travelwizard scripts. Source, do not execute.
#   . /usr/lib/travelwizard/common.sh

# Print the name of the active upstream interface.
# Prefers the interface owning the default route (this honors the user's
# upstream choice, enforced through route metrics); falls back to the first
# interface that is up.
tw_upstream() {
	local i up dev gwdev
	gwdev=$(ip route show default 2>/dev/null \
		| awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n 1)
	for i in wwan wan; do
		up=$(ubus call "network.interface.$i" status 2>/dev/null \
			| jsonfilter -e '@.up' 2>/dev/null)
		[ "$up" = "true" ] || continue
		[ -n "$gwdev" ] || { echo "$i"; return 0; }
		dev=$(tw_l3dev "$i")
		[ "$dev" = "$gwdev" ] && { echo "$i"; return 0; }
	done
	for i in wwan wan; do
		up=$(ubus call "network.interface.$i" status 2>/dev/null \
			| jsonfilter -e '@.up' 2>/dev/null)
		[ "$up" = "true" ] && { echo "$i"; return 0; }
	done
	return 1
}

# Print the effective VPN mode: the active profile's type, else the legacy
# single-config mode, else off.
tw_active_mode() {
	local sec m
	sec=$(uci -q get travelwizard.main.active_profile)
	if [ -n "$sec" ]; then
		m=$(uci -q get "travelwizard.$sec.type" 2>/dev/null)
		[ -n "$m" ] && { echo "$m"; return 0; }
	fi
	m=$(uci -q get travelwizard.main.vpn_mode); echo "${m:-off}"
}

# Map a Wi-Fi channel number to a radio band (2g|5g). Unknown -> 2g.
tw_band_of_channel() {
	case "$1" in
		''|*[!0-9]*) echo "2g" ;;
		*) if [ "$1" -le 14 ]; then echo "2g"; else echo "5g"; fi ;;
	esac
}

# Map a scan encryption string to a UCI wifi-iface encryption value.
# Prints "eap" for enterprise (unsupported) and "none" for open networks.
tw_uci_encryption() {
	case "$1" in
		""|none|NONE|unknown|UNKNOWN) echo "none" ;;
		*802.1x*|*8021x*|*EAP*) echo "eap" ;;
		*WEP*|*Wep*) echo "wep-open" ;;
		*SAE*|*Sae*)
			case "$1" in *PSK*|*Psk*) echo "sae-mixed" ;; *) echo "sae" ;; esac ;;
		*PSK*|*Psk*) echo "psk-mixed" ;;
		*) echo "sae-mixed" ;;
	esac
}

# Print one usable scan interface per radio, whatever the kernel naming is
# (phyX-apY on modern OpenWrt, wlanX on older builds). Extra args override
# the sysfs dir and iwinfo binary for testing.
# Usage: tw_scan_ifs [sysfs_dir] [iwinfo_bin]
tw_scan_ifs() {
	local sysfs="${1:-/sys/class/net}"
	local iwinfo_bin="${2:-iwinfo}"
	local ifdir if phy seen=""
	for ifdir in "$sysfs"/*; do
		[ -e "$ifdir" ] || continue
		if="${ifdir##*/}"
		# NOTE: iwinfo exits 0 with a usage blurb for non-Wi-Fi ifaces,
		# so require real wireless output, not just a zero exit code.
		"$iwinfo_bin" "$if" info 2>/dev/null | grep -q "ESSID:" || continue
		if [ -e "$ifdir/phy80211" ] || [ -L "$ifdir/phy80211" ]; then
			phy=$(readlink "$ifdir/phy80211"); phy=${phy##*/}
		else
			phy="$if"
		fi
		case " $seen " in
			*" $phy "*) continue ;;
		esac
		seen="$seen $phy"
		echo "$if"
	done
}

# True when the vault kill-switch is intact: the vault zone's forward
# policy is REJECT/DROP and nothing forwards vault traffic to wan
# (neither a forwarding section nor an ACCEPT rule).
tw_kill_holding() {
	local z fwd s
	z=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\([^.]*\)\.name='vault'$/\1/p" | head -n 1)
	[ -n "$z" ] || return 1
	fwd=$(uci -q get "firewall.$z.forward")
	[ "$fwd" = "REJECT" ] || [ "$fwd" = "DROP" ] || return 1
	for s in $(uci show firewall 2>/dev/null \
		| sed -n 's/^firewall\.\([^.]*\)=forwarding/\1/p'); do
		[ "$(uci -q get "firewall.$s.src")" = "vault" ] \
			&& [ "$(uci -q get "firewall.$s.dest")" = "wan" ] && return 1
	done
	for s in $(uci show firewall 2>/dev/null \
		| sed -n 's/^firewall\.\([^.]*\)=rule/\1/p'); do
		[ "$(uci -q get "firewall.$s.src")" = "vault" ] || continue
		[ "$(uci -q get "firewall.$s.dest")" = "wan" ] || continue
		[ "$(uci -q get "firewall.$s.target")" = "ACCEPT" ] && return 1
	done
	return 0
}

# Build a dnsmasq DHCP option 6 value ("6,a,b") from a comma/space list of
# DNS servers, keeping only well-formed IPv4 addresses. Prints nothing when
# none are valid.
tw_dhcp_dns_option() {
	local s out=""
	for s in $(printf '%s' "$1" | tr ',' ' '); do
		tw_is_ipv4 "$s" && out="$out,$s"
	done
	[ -n "$out" ] && echo "6$out"
}

# True for a dotted-quad IPv4 address with every octet in 0-255.
tw_is_ipv4() {
	local IFS=.
	case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
	# shellcheck disable=SC2086
	set -- $1
	[ $# -eq 4 ] && [ "$1" -le 255 ] && [ "$2" -le 255 ] \
		&& [ "$3" -le 255 ] && [ "$4" -le 255 ]
}

# Point vault DHCP clients at the given DNS servers (see tw_dhcp_dns_option).
# Vault clients must not use the router's dnsmasq: it resolves over the
# direct upstream. Public resolvers are reached through the forward path,
# so pbr carries the queries into the tunnel (or the kill switch drops
# them). Returns 0 when the option changed (caller commits + restarts).
tw_set_vault_dns() {
	local opt old
	opt=$(tw_dhcp_dns_option "$1")
	[ -n "$opt" ] || opt=$(tw_dhcp_dns_option "1.1.1.1 9.9.9.9")
	old=$(uci -q get dhcp.vault.dhcp_option)
	[ "$old" = "$opt" ] && return 1
	uci -q delete dhcp.vault.dhcp_option
	uci add_list dhcp.vault.dhcp_option="$opt"
	return 0
}

# Point every "vault-via-vpn" pbr policy at the given source network.
# Returns 0 when something changed (caller commits + restarts pbr).
tw_pbr_set_vault_net() {
	local s pname changed=1
	for s in $(uci show pbr 2>/dev/null \
		| sed -n 's/^pbr\.\([^.]*\)=policy/\1/p'); do
		pname=$(uci -q get pbr."$s".name)
		pname=${pname#"'"}
		pname=${pname%"'"}
		[ "$pname" = "vault-via-vpn" ] || continue
		[ "$(uci -q get pbr."$s".src_addr)" = "$1" ] && continue
		uci set pbr."$s".src_addr="$1"
		changed=0
	done
	return $changed
}

# Print the first non-loopback IPv4 address for a hostname, or nothing.
# Handles both bind-tools and busybox nslookup output formats.
tw_resolve_ipv4() {
	nslookup "$1" 2>/dev/null | awk '
		$1 == "Address:" && $2 !~ /:/ && $2 !~ /^127\./ { print $2; exit }
		$1 == "Address" && $3 !~ /:/ && $3 !~ /^127\./ { print $3; exit }'
}

# Print the l3 device of an interface, e.g. "phy0-ap0" / "eth1".
tw_l3dev() {
	ubus call "network.interface.$1" status 2>/dev/null \
		| jsonfilter -e '@.l3_device' 2>/dev/null
}

# Print "address mask" of the first IPv4 address of an interface.
tw_ipv4() {
	local st addr mask
	st=$(ubus call "network.interface.$1" status 2>/dev/null)
	addr=$(echo "$st" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	mask=$(echo "$st" | jsonfilter -e '@["ipv4-address"][0].mask' 2>/dev/null)
	[ -n "$addr" ] && [ -n "$mask" ] && echo "$addr $mask"
}

ip2int() {
	local IFS=.
	# shellcheck disable=SC2086
	set -- $1
	echo $(( ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4 ))
}

# nets_overlap ip1/plen1 ip2/plen2 -> true when the networks overlap.
nets_overlap() {
	local a b m min
	a=$(ip2int "$1"); b=$(ip2int "$3")
	if [ "$2" -lt "$4" ]; then min=$2; else min=$4; fi
	m=$(( (4294967295 << (32 - min)) & 4294967295 ))
	[ $(( a & m )) -eq $(( b & m )) ]
}

# network_of ip/plen -> prints network address.
network_of() {
	local a m
	a=$(ip2int "$1")
	m=$(( (4294967295 << (32 - $2)) & 4294967295 ))
	a=$(( a & m ))
	echo "$(( (a >> 24) & 255 )).$(( (a >> 16) & 255 )).$(( (a >> 8) & 255 )).$(( a & 255 ))"
}
