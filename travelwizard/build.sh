#!/bin/sh
# Build the TravelWizard GL-MT3000 firmware via Docker (no local toolchain).
# 1. SDK compiles the feed's script-only packages into .apk files.
# 2. ImageBuilder assembles the sysupgrade image with the package set below.
# Usage: ./travelwizard/build.sh        (REL=v25.12.5 ./travelwizard/build.sh)
set -eu
REL="${REL:-v25.12.5}"
HERE=$(cd "$(dirname "$0")" && pwd)
FEED="$HERE/feed"
OUT="$HERE/build"
SDK="openwrt/sdk:mediatek-filogic-$REL"
IB="openwrt/imagebuilder:mediatek-filogic-$REL"
# NOTE: wpad-basic-mbedtls is already the stock default; no -wpad-mini needed.
# NOTE: the `luci` metapackage is required, not just luci-base — it pulls in
# uhttpd (web server) and the default theme. Without it nothing listens on :80.
PACKAGES="luci travelwizard luci-app-travelwizard wpad-basic-mbedtls iwinfo iw wireguard-tools luci-proto-wireguard openvpn-openssl luci-app-openvpn sing-box pbr curl ca-bundle jsonfilter coreutils-base64 coreutils-timeout qrencode"

mkdir -p "$OUT/ipk" "$OUT/image"
docker run --rm --platform linux/amd64 \
	-v "$FEED/travelwizard:/builder/package/travelwizard:ro" \
	-v "$FEED/luci-app-travelwizard:/builder/package/luci-app-travelwizard:ro" \
	-v "$OUT:/out" -w /builder "$SDK" \
	sh -c 'printf "CONFIG_TARGET_mediatek=y\nCONFIG_TARGET_mediatek_filogic=y\n" > .config \
		&& make defconfig >/dev/null 2>&1 \
		&& make package/travelwizard/compile package/luci-app-travelwizard/compile -j"$(nproc)" \
		&& find bin/packages \( -name "travelwizard*" -o -name "luci-app-travelwizard*" \) -exec cp {} /out/ipk/ \;'
docker run --rm --platform linux/amd64 \
	-v "$OUT/ipk:/in:ro" -v "$OUT/image:/out" -w /builder "$IB" \
	sh -c "cp /in/*.apk packages/ && make image PROFILE=\"glinet_gl-mt3000\" PACKAGES=\"$PACKAGES\" && cp bin/targets/mediatek/filogic/*glinet_gl-mt3000*-sysupgrade.bin /out/"
echo "OK: $OUT/image"
