#!/bin/sh
# Tests tw-probe: argument/link validation plus the full probe flow with a
# stub sing-box (listens on the config's SOCKS port), stub curl and stub
# nslookup; per-port locks; listener ownership via a fake /proc.
# Run: sh travelwizard/tests/test-probe.sh
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE="$HERE/../feed/travelwizard/files/usr/sbin/tw-probe"
IMPORT="$HERE/../feed/travelwizard/files/usr/sbin/tw-sub-import"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/sb"
# on device INSTALL_BIN ships tw-sub-import executable; mirror that here
cp "$IMPORT" "$TMP/bin/tw-sub-import"
chmod +x "$TMP/bin/tw-sub-import"
IMPORT_BIN="$TMP/bin/tw-sub-import"
export TW_COMMON="$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"
export TW_PROBE_LOCK_DIR="$TMP/locks"
# stub nslookup: answers unless NS_FAIL is set (never touches real DNS)
cat >"$TMP/bin/nslookup" <<'EOF'
#!/bin/sh
[ -n "$NS_FAIL" ] && { echo ";; connection timed out"; exit 1; }
printf 'Server:\t\t%s\nAddress:\t%s#53\n\nName:\t%s\nAddress: 142.250.1.1\n' "$2" "$2" "$1"
EOF
chmod +x "$TMP/bin/nslookup"
export TW_NSLOOKUP_BIN="$TMP/bin/nslookup"
SS='ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@203.0.113.12:8388#Someone'
printf 'Someone\t%s\n' "$SS" >"$TMP/sb/tw-p1.map"

# 1. missing/bad profile id
check p1-noargs "$(TW_SB_DIR="$TMP/sb" sh "$PROBE" 2>/dev/null)" \
	'{"tag":"","ok":false,"error":"bad profile id"}'
check p1-slash "$(TW_SB_DIR="$TMP/sb" sh "$PROBE" '../x' 't' 2>/dev/null)" \
	'{"tag":"t","ok":false,"error":"bad profile id"}'

# 2. unknown profile (no .map sidecar)
check p2-nomap "$(TW_SB_DIR="$TMP/sb" sh "$PROBE" 'p9' 't' 2>/dev/null)" \
	'{"tag":"t","ok":false,"error":"no endpoint index for this profile (refresh the subscription first)"}'

# 3. tag lookup is exact: "One" must not match "Someone"
check p3-unknown "$(TW_SB_DIR="$TMP/sb" sh "$PROBE" 'p1' 'One' 2>/dev/null)" \
	'{"tag":"One","ok":false,"error":"unknown endpoint"}'

# 4. exact tag resolves, then the missing binary is reported
check p4-nobin "$(TW_SB_DIR="$TMP/sb" TW_SINGBOX_BIN=nope-sing-box \
	sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":false,"error":"sing-box not installed"}'

# 5. sing-box that dies instantly -> clean startup error, no hang
cat >"$TMP/bin/sing-box" <<'EOF'
#!/bin/sh
[ "$1" = "check" ] && exit 0
exit 1
EOF
chmod +x "$TMP/bin/sing-box"
check p5-dead "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_PROBE_TRIES=2 TW_SINGBOX_BIN=sing-box PATH="$TMP/bin:$PATH" \
	sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":false,"error":"could not start a probe instance (no free local port)"}'

# 6. success path: stub sing-box listens, stub curl reports timing
cat >"$TMP/bin/sing-box" <<'EOF'
#!/bin/sh
# check exits at once (like the real binary); run listens, then idles
[ "$1" = "check" ] && exit 0
cfg=""; prev=""
for a in "$@"; do [ "$prev" = "-c" ] && cfg="$a"; prev="$a"; done
# the SOCKS inbound comes first; a DNS probe listener may follow on :53
port=$(grep -o '"listen_port":[0-9]*' "$cfg" | head -n 1 | grep -o '[0-9]*')
exec python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(30)' "$port"
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
echo '204 0.123'
exit 0
EOF
chmod +x "$TMP/bin/sing-box" "$TMP/bin/curl"
check p6-ok "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_READY_WAIT=6 \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":true,"latency_ms":123,"http_code":"204","udp":"ok"}'

# 7. non-2xx answer and curl timeout surface as probe failures
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
echo '500 0.050'
exit 0
EOF
chmod +x "$TMP/bin/curl"
check p7-http "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_READY_WAIT=6 \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":false,"error":"endpoint answered HTTP 500"}'
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
exit 28
EOF
chmod +x "$TMP/bin/curl"
check p7-timeout "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_READY_WAIT=6 \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":false,"error":"probe timed out after 12s"}'

# 8. TIME_WAIT / remote-side sockets must NOT count as listening.
# 19800 = 0x4D58. The first line is a stale server-side TIME_WAIT on the
# probe port (left by the previous probe's curl), the second an unrelated
# connection *to* that port; neither means a proxy is accepting.
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
echo '204 0.123'
exit 0
EOF
chmod +x "$TMP/bin/curl"
cat >"$TMP/fake-timewait.txt" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt
   1: 0100007F:4D58 0100007F:8251 06 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
   2: 0100007F:8252 0100007F:4D58 01 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
EOF
check p8-timewait "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_READY_WAIT=1 TW_PROBE_TRIES=1 \
	TW_PROC_NET_TCP="$TMP/fake-timewait.txt" TW_PROC_NET_TCP6="$TMP/no-tcp6" \
	TW_PROC_DIR="$TMP/noproc" \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":false,"error":"could not start a probe instance (no free local port)"}'

# 9. ...while a real LISTEN line does count (positive control). All five
# candidate ports listen: candidates rotate by PID, so whichever comes
# first must succeed without waiting out the other ports. Without a
# per-process view (no fake /proc) the LISTEN entry alone is trusted.
cat >"$TMP/fake-listen.txt" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt
   0: 0100007F:4D58 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
   1: 0100007F:4D59 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
   2: 0100007F:4D5A 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
   3: 0100007F:4D5B 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
   4: 0100007F:4D5C 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 3 0000000000000000
EOF
check p9-listen "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_READY_WAIT=6 TW_PROBE_PORT_SPAN=5 \
	TW_PROC_NET_TCP="$TMP/fake-listen.txt" TW_PROC_NET_TCP6="$TMP/no-tcp6" \
	TW_PROC_DIR="$TMP/noproc" \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":true,"latency_ms":123,"http_code":"204","udp":"ok"}'

# 10. UDP is informational: a failed DNS relay still passes the endpoint
check p10-udp-failed "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl NS_FAIL=1 \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":true,"latency_ms":123,"http_code":"204","udp":"failed"}'
# the probe config carries the per-port DNS listener, routed ahead of the
# port-53 hijack
printf '%s\n' "$SS" | TW_INBOUND=socks TW_SOCKS_PORT=19801 \
	TW_DNS_PROBE_IP=127.77.80.52 sh "$IMPORT" - "$TMP/p10.json" >/dev/null 2>&1
check p10-dns-inbound "$(grep -o '"tag":"dns-probe-in","listen":"127.77.80.52","listen_port":53' "$TMP/p10.json")" \
	'"tag":"dns-probe-in","listen":"127.77.80.52","listen_port":53'
check p10-dns-rule "$(grep -c '"rules":\[{"inbound":"dns-probe-in","action":"route","outbound":"proxy"},{"port":53' "$TMP/p10.json")" "1"
printf '%s\n' "$SS" | TW_INBOUND=socks TW_DNS_PROBE_IP='127.0.0.1","x' \
	sh "$IMPORT" - "$TMP/p10b.json" >/dev/null 2>&1
check p10-dns-garbage "$(grep -c 'dns-probe-in' "$TMP/p10b.json")" "0"

# 11. a sing-box that rejects the UDP listener falls back to HTTPS only
cp "$TMP/bin/sing-box" "$TMP/bin/sing-box-nodns"
cat >"$TMP/bin/sing-box" <<'EOF'
#!/bin/sh
cfg=""; prev=""
for a in "$@"; do [ "$prev" = "-c" ] && cfg="$a"; prev="$a"; done
grep -q dns-probe-in "$cfg" && exit 1
exec "${0%/*}/sing-box-nodns" "$@"
EOF
chmod +x "$TMP/bin/sing-box"
check p11-fallback "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":true,"latency_ms":123,"http_code":"204","udp":"untested"}'
mv "$TMP/bin/sing-box-nodns" "$TMP/bin/sing-box"

# 12. per-port locks: a live holder keeps the port, a dead one is reclaimed
mkdir -p "$TMP/locks/19800"
echo $$ >"$TMP/locks/19800/pid"
check p12-locked "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_PROBE_PORT_SPAN=1 \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":false,"error":"could not start a probe instance (no free local port)"}'
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
echo "$DEAD" >"$TMP/locks/19800/pid"
check p12-reclaim "$(TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" \
	TW_SINGBOX_BIN=sing-box TW_CURL_BIN=curl TW_PROBE_PORT_SPAN=1 \
	PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null)" \
	'{"tag":"Someone","ok":true,"latency_ms":123,"http_code":"204","udp":"ok"}'
check p12-released "$(ls "$TMP/locks" | wc -l | tr -d ' ')" "0"

# 13. readiness needs a listener owned by our instance. The stub records
# itself in a fake /proc (status + socket fd) and only then publishes a
# LISTEN line on 19800 with inode LISTEN_INODE; its own socket is
# OWN_INODE. coreutils timeout forks, so the owner may be a child.
cat >"$TMP/bin/sing-box-proc" <<'EOF'
#!/bin/sh
[ "$1" = "check" ] && exit 0
mkdir -p "$TW_PROC_DIR/$$/fd"
if [ ! -d "$TW_PROC_DIR/$PPID" ]; then
	mkdir -p "$TW_PROC_DIR/$PPID/fd"
	echo "PPid: 1" >"$TW_PROC_DIR/$PPID/status"
fi
printf 'PPid:\t%s\n' "$PPID" >"$TW_PROC_DIR/$$/status"
ln -s "socket:[$OWN_INODE]" "$TW_PROC_DIR/$$/fd/3"
printf '   0: 0100007F:4D58 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %s 1 0000000000000000\n' \
	"$LISTEN_INODE" >>"$FAKE_TCP"
exec sleep 30
EOF
chmod +x "$TMP/bin/sing-box-proc"
probe_proc() { # $1 own inode $2 published inode
	rm -rf "$TMP/proc"; mkdir -p "$TMP/proc/self"
	head -n 1 "$TMP/fake-listen.txt" >"$TMP/tcp-live.txt"
	TW_SB_DIR="$TMP/sb" TW_SUBIMPORT="$IMPORT_BIN" TW_SINGBOX_BIN=sing-box-proc \
		TW_CURL_BIN=curl TW_READY_WAIT=2 TW_PROBE_TRIES=1 TW_PROBE_PORT_SPAN=1 \
		TW_PROC_NET_TCP="$TMP/tcp-live.txt" TW_PROC_NET_TCP6="$TMP/no-tcp6" \
		TW_PROC_DIR="$TMP/proc" FAKE_TCP="$TMP/tcp-live.txt" \
		OWN_INODE="$1" LISTEN_INODE="$2" \
		PATH="$TMP/bin:$PATH" sh "$PROBE" 'p1' 'Someone' 2>/dev/null
}
check p13-owned "$(probe_proc 4242 4242)" \
	'{"tag":"Someone","ok":true,"latency_ms":123,"http_code":"204","udp":"ok"}'
check p13-foreign "$(probe_proc 4242 1111)" \
	'{"tag":"Someone","ok":false,"error":"could not start a probe instance (no free local port)"}'

echo "PASS: probe ($PASS assertions)"
