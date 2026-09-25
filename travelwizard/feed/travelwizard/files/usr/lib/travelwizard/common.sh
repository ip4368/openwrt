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
		# already a uci value (saved from a live wwan config)
		psk|psk2|psk-mixed|sae|sae-mixed|owe|wep-open|wep-shared) echo "$1" ;;
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

# Convert `iw <iface> scan dump` (kernel scan cache) to iwinfo-like Cell
# blocks on stdin, so the normal scan parser consumes both sources. Channel
# comes from freq (iw's channel lines vary); encryption keywords match what
# tw_uci_encryption expects. iw escapes SSID bytes that are not printable
# ASCII (so every UTF-8 name), a backslash, and edge spaces as \xHH; those
# are decoded back to the raw bytes, as iwinfo would print them.
# Usage: iw .. scan dump | tw_scan_dump_conv
tw_scan_dump_conv() {
	local out
	out=$(awk '
	# \xHH -> \0ooo, which printf %b turns into the byte in any shell (awk
	# itself would re-encode values over 127 as UTF-8 in a UTF-8 locale).
	function unesc(s,   out, h, v) {
		out = ""
		while (match(s, /\\x[0-9a-fA-F][0-9a-fA-F]/)) {
			h = tolower(substr(s, RSTART + 2, 2))
			v = (index("0123456789abcdef", substr(h, 1, 1)) - 1) * 16 \
				+ index("0123456789abcdef", substr(h, 2, 1)) - 1
			out = out substr(s, 1, RSTART - 1) (v ? sprintf("\\0%03o", v) : "")
			s = substr(s, RSTART + RLENGTH)
		}
		return out s
	}
	function emit() {
		if (bssid == "") return
		n++
		if (essid == "") essid = "(hidden) " bssid
		f = int(freq)
		if (f >= 2412 && f <= 2472) chan = int((f - 2407) / 5)
		else if (f == 2484) chan = 14
		else if (f >= 5000 && f < 6000) chan = int((f - 5000) / 5)
		else if (f >= 6000) chan = 999
		else chan = ""
		if (!privacy) enc = "none"
		else if (eap) enc = "WPA2-EAP"
		else if (rsn && sae && psk) enc = "WPA2 PSK+SAE"
		else if (rsn && sae) enc = "SAE"
		else if (rsn) enc = "WPA2 PSK"
		else if (wpa) enc = "WPA PSK"
		else enc = "WEP"
		printf "Cell %02d - Address: %s\n", n, bssid
		printf "\t  ESSID: \"%s\"\n", essid
		printf "\t  Mode: Master  Channel: %s\n", chan
		printf "\t  Signal: %d dBm\n", sig
		printf "\t  Encryption: %s\n", enc
	}
	/^BSS / {
		emit()
		bssid = $2; sub(/\(.*/, "", bssid)
		essid = ""; sig = -999; freq = 0
		privacy = 0; rsn = 0; wpa = 0; sae = 0; psk = 0; eap = 0
		next
	}
	/^[ \t]+SSID: / { line = $0; sub(/^[^:]*: /, "", line); essid = unesc(line); next }
	/^[ \t]+freq: / { freq = $2; next }
	/^[ \t]+signal: / { sig = int($2); next }
	/capability: .*0x[0-9a-fA-F]+/ {
		# bit 4 (0x10) is Privacy: the hex digit in the 16s place is odd
		if (match($0, /0x[0-9a-fA-F]+/)) {
			hex = substr($0, RSTART + 2, RLENGTH - 2)
			if (substr(hex, length(hex) - 1, 1) ~ /[13579bdfBDF]/)
				privacy = 1
		}
		next
	}
	/^[ \t]+RSN:/ { rsn = 1; next }
	/^[ \t]+WPA:/ { wpa = 1; next }
	/Authentication suites:/ {
		if ($0 ~ /SAE/) sae = 1
		if ($0 ~ /PSK/) psk = 1
		if ($0 ~ /802\.1X/) eap = 1
		next
	}
	END { emit() }
	')
	# only ESSIDs can hold a backslash: iw never prints one unescaped
	[ -n "$out" ] && printf '%b\n' "$out"
}

# Scan one interface: trigger fresh scans (retried: while the sta is
# connected, wpa_supplicant's background scans briefly hold the radio and a
# single attempt can come back empty), then fall back to the kernel scan
# cache — fresh in exactly that case, since a refused trigger means someone
# is actively scanning. Prints Cell blocks; fails only when both fail.
# Usage: tw_scan_one <iface> [iwinfo_bin] [iw_bin]
tw_scan_one() {
	local iface="$1" iwinfo_bin="${2:-iwinfo}" iw_bin="${3:-iw}"
	local tries="${TW_SCAN_RETRIES:-3}" sleep_s="${TW_SCAN_SLEEP:-3}"
	local n=1 out
	while [ "$n" -le "$tries" ]; do
		out=$("$iwinfo_bin" "$iface" scan 2>/dev/null)
		case "$out" in
			*Cell*) printf '%s\n' "$out"; return 0 ;;
		esac
		n=$((n + 1))
		[ "$n" -le "$tries" ] || break
		sleep "$sleep_s"
		# The scan that refused ours has usually finished by now: take
		# its results instead of paying for another full scan.
		out=$("$iw_bin" "$iface" scan dump 2>/dev/null | tw_scan_dump_conv)
		case "$out" in
			*Cell*) printf '%s\n' "$out"; return 0 ;;
		esac
	done
	out=$("$iw_bin" "$iface" scan dump 2>/dev/null | tw_scan_dump_conv)
	case "$out" in
		*Cell*) printf '%s\n' "$out"; return 0 ;;
	esac
	return 1
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

# Print the first answer address from nslookup output on stdin, or nothing.
# Unlike tw_resolve_ipv4 this is safe with an explicit (non-loopback) server:
# only addresses after a "Name:" line count, so the "Server:"/"Address: #53"
# lines are never mistaken for answers. Handles bind and busybox formats.
tw_ns_answer() {
	awk '
		$1 == "Name:" { want = 1; next }
		want && $1 == "Address:" && $2 !~ /:/ && $2 !~ /#/ && $2 !~ /^127\./ { print $2; exit }
		want && $1 == "Address" && $3 !~ /:/ && $3 !~ /#/ && $3 !~ /^127\./ { print $3; exit }'
}

# Print the oldest savednet section name (by last_used), or nothing.
_tw_saved_oldest() {
	local s ts best="" best_ts=""
	for s in $(uci show travelwizard 2>/dev/null \
		| sed -n 's/^travelwizard\.\([^.]*\)=savednet/\1/p'); do
		ts=$(uci -q get "travelwizard.$s.last_used")
		case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
		if [ -z "$best" ] || [ "$ts" -lt "$best_ts" ]; then
			best="$s"; best_ts="$ts"
		fi
	done
	[ -n "$best" ] && echo "$best"
}

# Remember a successfully joined upstream network for one-tap reconnect.
# Updates the entry when the SSID is already known, else adds one (capped
# at 16 entries, oldest first out). Silent; the caller commits.
tw_saved_upsert() {
	local ssid="$1" key="$2" band="$3" enc="$4" bssid="$5"
	local s sec="" count=0 oldest now
	[ -n "$ssid" ] || return 1
	now=$(date +%s)
	for s in $(uci show travelwizard 2>/dev/null \
		| sed -n 's/^travelwizard\.\([^.]*\)=savednet/\1/p'); do
		count=$((count + 1))
		if [ "$(uci -q get "travelwizard.$s.ssid")" = "$ssid" ]; then
			sec="$s"
		fi
	done
	if [ -z "$sec" ]; then
		while [ "$count" -ge 16 ]; do
			oldest=$(_tw_saved_oldest)
			[ -n "$oldest" ] || break
			uci -q delete "travelwizard.$oldest"
			count=$((count - 1))
		done
		sec=$(uci add travelwizard savednet)
		[ -n "$sec" ] || return 1
	fi
	uci set "travelwizard.$sec.ssid=$ssid"
	uci set "travelwizard.$sec.key=$key"
	uci set "travelwizard.$sec.band=$band"
	uci set "travelwizard.$sec.enc=$enc"
	uci set "travelwizard.$sec.bssid=$bssid"
	uci set "travelwizard.$sec.last_used=$now"
	return 0
}

# Remember the network the Wi-Fi uplink is configured for; run when wwan
# comes up. tw-wan-join saves it as well, but its request can be torn down
# before it gets there: the browser's device drops off this router's Wi-Fi
# while the radio retunes to the upstream channel. Known SSIDs keep their
# scan-derived settings and only take the key that just worked and a fresh
# timestamp. Silent; the caller commits.
tw_saved_record_wwan() {
	local ssid key enc radio s sec=""
	ssid=$(uci -q get wireless.wwan.ssid)
	[ -n "$ssid" ] || return 1
	key=$(uci -q get wireless.wwan.key)
	for s in $(uci show travelwizard 2>/dev/null \
		| sed -n 's/^travelwizard\.\([^.]*\)=savednet/\1/p'); do
		[ "$(uci -q get "travelwizard.$s.ssid")" = "$ssid" ] && sec="$s"
	done
	if [ -n "$sec" ]; then
		uci set "travelwizard.$sec.key=$key"
		uci set "travelwizard.$sec.last_used=$(date +%s)"
		return 0
	fi
	enc=$(uci -q get wireless.wwan.encryption)
	radio=$(uci -q get wireless.wwan.device)
	tw_saved_upsert "$ssid" "$key" "$(uci -q get "wireless.$radio.band")" "${enc:-none}" ""
}

# True when a default route via the given device exists in some table.
# Used after tw-vpn-apply to confirm pbr actually installed the vault
# policy (a bare connected route does not count: those exist even with
# no policy routing at all).
tw_tunnel_routed() {
	ip route show table all 2>/dev/null | awk -v dev="$1" '
		$1 == "default" {
			for (i = 1; i <= NF; i++)
				if ($i == "dev" && $(i + 1) == dev) { found = 1; exit }
		}
		END { exit !found }'
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
