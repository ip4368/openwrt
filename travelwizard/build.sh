#!/bin/sh
# Build the TravelWizard GL-MT3000 firmware with OpenWrt's SDK + ImageBuilder.
#
#   ./travelwizard/build.sh prepare  # online: populate and lock the APK cache
#   ./travelwizard/build.sh          # offline: rebuild local APKs + the image
#
# The normal build runs both containers with networking disabled. It still uses
# ImageBuilder's complete package installation and rootfs finalization pipeline.
set -eu

REL="${REL:-v25.12.5}"
PROFILE="glinet_gl-mt3000"
HERE=$(cd "$(dirname "$0")" && pwd)
FEED="$HERE/feed"
OUT="$HERE/build"
SDK="openwrt/sdk:mediatek-filogic-$REL"
IB="openwrt/imagebuilder:mediatek-filogic-$REL"
SDK_VOLUME_PREFIX="travelwizard-sdk-mediatek-filogic-$REL"
IB_VOLUME_PREFIX="travelwizard-imagebuilder-mediatek-filogic-$REL"
CACHE_SCHEMA=1

# NOTE: wpad-basic-mbedtls is already the stock default; no -wpad-mini needed.
# NOTE: the `luci` metapackage is required, not just luci-base — it pulls in
# uhttpd (web server) and the default theme. Without it nothing listens on :80.
PACKAGES="luci travelwizard luci-app-travelwizard wpad-basic-mbedtls iwinfo iw wireguard-tools luci-proto-wireguard openvpn-openssl luci-app-openvpn sing-box pbr curl ca-bundle jsonfilter coreutils-base64 coreutils-timeout qrencode"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage:
  ./travelwizard/build.sh prepare  Download and lock all remote APKs
  ./travelwizard/build.sh build    Build packages + image without a network
  ./travelwizard/build.sh          Same as "build"

Environment:
  REL=$REL        OpenWrt container release
  PULL=1          Refresh the SDK/ImageBuilder images during "prepare"

Docker volumes (persistent build state):
  $SDK_VOLUME_PREFIX-<image-id>
  $IB_VOLUME_PREFIX-<image-id>
EOF
}

case "$REL" in
	*[!A-Za-z0-9_.-]*) die "REL contains characters unsafe for a Docker volume name: $REL" ;;
esac

MODE="${1:-build}"
case "$MODE" in
	build|prepare) ;;
	-h|--help|help) usage; exit 0 ;;
	*) usage >&2; die "unknown command: $MODE" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"

ensure_image_for_prepare() {
	image=$1
	if [ "${PULL:-0}" = 1 ] || ! docker image inspect "$image" >/dev/null 2>&1; then
		docker pull "$image"
	fi
}

ensure_image_for_build() {
	image=$1
	docker image inspect "$image" >/dev/null 2>&1 ||
		die "missing $image; run ./travelwizard/build.sh prepare while online"
}

if [ "$MODE" = prepare ]; then
	ensure_image_for_prepare "$SDK"
	ensure_image_for_prepare "$IB"
else
	ensure_image_for_build "$SDK"
	ensure_image_for_build "$IB"
fi

SDK_ID=$(docker image inspect "$SDK" --format '{{.Id}}')
IB_ID=$(docker image inspect "$IB" --format '{{.Id}}')
SDK_IMAGE_TOKEN=$(printf '%s' "${SDK_ID#sha256:}" | cut -c 1-12)
IB_IMAGE_TOKEN=$(printf '%s' "${IB_ID#sha256:}" | cut -c 1-12)
SDK_VOLUME="$SDK_VOLUME_PREFIX-$SDK_IMAGE_TOKEN"
IB_VOLUME="$IB_VOLUME_PREFIX-$IB_IMAGE_TOKEN"
SDK_KEY=$(printf '%s\n' \
	"schema=$CACHE_SCHEMA" \
	"sdk=$SDK_ID" \
	'target=mediatek/filogic' |
	shasum -a 256 | awk '{ print $1 }')
DEPENDENCY_DECLARATIONS=$(sed -n 's/^[[:space:]]*DEPENDS:=/DEPENDS:=/p' \
	"$FEED/travelwizard/Makefile" "$FEED/luci-app-travelwizard/Makefile")
CACHE_KEY=$(printf '%s\n' \
	"schema=$CACHE_SCHEMA" \
	"release=$REL" \
	"profile=$PROFILE" \
	"imagebuilder=$IB_ID" \
	"packages=$PACKAGES" \
	"$DEPENDENCY_DECLARATIONS" |
	shasum -a 256 | awk '{ print $1 }')
CACHE_OUT="$OUT/cache/$CACHE_KEY"

value_from_makefile() {
	file=$1
	name=$2
	sed -n "s/^${name}:=//p" "$file" | sed -n '1p'
}

TW_VERSION=$(value_from_makefile "$FEED/travelwizard/Makefile" PKG_VERSION)
TW_RELEASE=$(value_from_makefile "$FEED/travelwizard/Makefile" PKG_RELEASE)
LUCI_VERSION=$(value_from_makefile "$FEED/luci-app-travelwizard/Makefile" PKG_VERSION)
LUCI_RELEASE=$(value_from_makefile "$FEED/luci-app-travelwizard/Makefile" PKG_RELEASE)
[ -n "$TW_VERSION" ] && [ -n "$TW_RELEASE" ] || die "cannot read travelwizard package version"
[ -n "$LUCI_VERSION" ] && [ -n "$LUCI_RELEASE" ] || die "cannot read LuCI package version"
TW_APK="travelwizard-$TW_VERSION-r$TW_RELEASE.apk"
LUCI_APK="luci-app-travelwizard-$LUCI_VERSION-r$LUCI_RELEASE.apk"

mkdir -p "$OUT/ipk" "$OUT/image" "$CACHE_OUT"

tree_hash() {
	(
		cd "$1"
		find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
			shasum -a 256 "$file"
		done
	) | shasum -a 256 | awk '{ print $1 }'
}

TW_SOURCE_KEY=$(printf '%s\n%s\n' "$SDK_KEY" "$(tree_hash "$FEED/travelwizard")" |
	shasum -a 256 | awk '{ print $1 }')
LUCI_SOURCE_KEY=$(printf '%s\n%s\n' "$SDK_KEY" "$(tree_hash "$FEED/luci-app-travelwizard")" |
	shasum -a 256 | awk '{ print $1 }')

prepare_sdk() {
	printf '%s\n' "Preparing the persistent SDK workspace (network disabled)..."
	docker volume create "$SDK_VOLUME" >/dev/null
	docker run --rm --network none --platform linux/amd64 \
		-v "$SDK_VOLUME:/builder" \
		-v "$FEED/travelwizard:/builder/package/travelwizard:ro" \
		-v "$FEED/luci-app-travelwizard:/builder/package/luci-app-travelwizard:ro" \
		-w /builder "$SDK" \
		sh -eu -c '
			export STAGING_DIR_HOST=/builder/staging_dir/host
			SDK_KEY=$1
			CURRENT=$(cat .travelwizard-cache/sdk-key 2>/dev/null || true)
			[ "$CURRENT" = "$SDK_KEY" ] && exit 0
			printf "CONFIG_TARGET_mediatek=y\nCONFIG_TARGET_mediatek_filogic=y\n" > .config
			make defconfig >/dev/null
			mkdir -p .travelwizard-cache
			printf "%s\n" "$SDK_KEY" > .travelwizard-cache/sdk-key
		' sh "$SDK_KEY"
}

sdk_is_ready() {
	docker volume inspect "$SDK_VOLUME" >/dev/null 2>&1 || return 1
	actual=$(docker run --rm --network none --platform linux/amd64 \
		-v "$SDK_VOLUME:/builder" -w /builder "$SDK" \
		sh -c 'cat .travelwizard-cache/sdk-key 2>/dev/null' || true)
	[ "$actual" = "$SDK_KEY" ]
}

build_local_packages() {
	printf '%s\n' "Building the two local APKs (network disabled)..."
	sdk_is_ready || die "SDK cache is missing or stale; run ./travelwizard/build.sh prepare"
	TW_REBUILD=0
	LUCI_REBUILD=0
	TW_APK_HASH=$(shasum -a 256 "$OUT/ipk/$TW_APK" 2>/dev/null | awk '{ print $1 }' || true)
	LUCI_APK_HASH=$(shasum -a 256 "$OUT/ipk/$LUCI_APK" 2>/dev/null | awk '{ print $1 }' || true)
	[ -s "$OUT/ipk/$TW_APK" ] &&
		[ "$(cat "$OUT/ipk/.travelwizard.source" 2>/dev/null || true)" = "$TW_SOURCE_KEY $TW_APK_HASH" ] || TW_REBUILD=1
	[ -s "$OUT/ipk/$LUCI_APK" ] &&
		[ "$(cat "$OUT/ipk/.luci-app-travelwizard.source" 2>/dev/null || true)" = "$LUCI_SOURCE_KEY $LUCI_APK_HASH" ] || LUCI_REBUILD=1
	find "$OUT/ipk" -maxdepth 1 -type f -name 'travelwizard-*.apk' ! -name "$TW_APK" -delete
	find "$OUT/ipk" -maxdepth 1 -type f -name 'luci-app-travelwizard-*.apk' ! -name "$LUCI_APK" -delete

	if [ "$TW_REBUILD" = 0 ] && [ "$LUCI_REBUILD" = 0 ]; then
		printf '%s\n' "Local APKs are current; reusing them."
		return
	fi

	docker run --rm --network none --platform linux/amd64 \
		-v "$SDK_VOLUME:/builder" \
		-v "$FEED/travelwizard:/builder/package/travelwizard:ro" \
		-v "$FEED/luci-app-travelwizard:/builder/package/luci-app-travelwizard:ro" \
		-v "$OUT:/out" -w /builder "$SDK" \
		sh -eu -c '
			export STAGING_DIR_HOST=/builder/staging_dir/host
			TW_APK=$1
			LUCI_APK=$2
			TW_REBUILD=$3
			LUCI_REBUILD=$4
			[ "$(cat .travelwizard-cache/sdk-key)" = "$5" ]
			if [ "$TW_REBUILD" = 1 ]; then
				make -s -C package/travelwizard TOPDIR=/builder clean compile
			fi
			if [ "$LUCI_REBUILD" = 1 ]; then
				make -s -C package/luci-app-travelwizard TOPDIR=/builder clean compile
			fi
			find bin/packages -type f -name "$TW_APK" -exec cp {} /out/ipk/ \;
			find bin/packages -type f -name "$LUCI_APK" -exec cp {} /out/ipk/ \;
			test -s "/out/ipk/$TW_APK"
			test -s "/out/ipk/$LUCI_APK"
		' sh "$TW_APK" "$LUCI_APK" "$TW_REBUILD" "$LUCI_REBUILD" "$SDK_KEY"

	[ "$(find "$OUT/ipk" -maxdepth 1 -type f -name '*.apk' | wc -l | tr -d ' ')" = 2 ] ||
		die "expected exactly two freshly built APKs in $OUT/ipk"
	TW_APK_HASH=$(shasum -a 256 "$OUT/ipk/$TW_APK" | awk '{ print $1 }')
	LUCI_APK_HASH=$(shasum -a 256 "$OUT/ipk/$LUCI_APK" | awk '{ print $1 }')
	printf '%s %s\n' "$TW_SOURCE_KEY" "$TW_APK_HASH" > "$OUT/ipk/.travelwizard.source"
	printf '%s %s\n' "$LUCI_SOURCE_KEY" "$LUCI_APK_HASH" > "$OUT/ipk/.luci-app-travelwizard.source"
}

prepare_cache() {
	prepare_sdk
	build_local_packages
	printf '%s\n' "Preparing the locked ImageBuilder APK cache (network enabled)..."
	docker volume create "$IB_VOLUME" >/dev/null

	docker run --rm --platform linux/amd64 \
		-v "$IB_VOLUME:/builder" \
		-v "$OUT/ipk:/in:ro" \
		-v "$CACHE_OUT:/out" \
		-w /builder "$IB" \
		sh -eu -c '
			export STAGING_DIR_HOST=/builder/staging_dir/host
			CACHE_KEY=$1
			PROFILE=$2
			PACKAGES=$3
			TW_APK=$4
			LUCI_APK=$5

			mkdir -p dl packages .travelwizard-cache
			find packages -maxdepth 1 -type f -name "*.apk" \
				! -name "base-files-*.apk" ! -name "libc-*.apk" ! -name "kernel-*.apk" -delete
			rm -rf dl
			mkdir -p dl
			rm -f packages/packages.adb .travelwizard-cache/key
			cp "/in/$TW_APK" "/in/$LUCI_APK" packages/

			make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES" > /out/online.manifest
			REMOTE_COUNT=$(find dl -maxdepth 1 -type f -name "*.apk" | wc -l | tr -d " ")
			[ "$REMOTE_COUNT" -gt 0 ]
			find dl -maxdepth 1 -type f -name "*.apk" -exec cp {} packages/ \;
			rm -f packages/packages.adb
			make package_index >/dev/null

			for apk in packages/*.apk; do
				case ${apk##*/} in
					travelwizard-*.apk|luci-app-travelwizard-*.apk) ;;
					*) sha256sum "$apk" ;;
				esac
			done | sort -k 2 > /out/remote-packages.sha256
			{
				printf "cache_key=%s\n" "$CACHE_KEY"
				printf "profile=%s\n" "$PROFILE"
				printf "remote_apks=%s\n" "$REMOTE_COUNT"
				printf "packages=%s\n" "$PACKAGES"
			} > /out/cache-info.txt
		' sh "$CACHE_KEY" "$PROFILE" "$PACKAGES" "$TW_APK" "$LUCI_APK"

	printf '%s\n' "Proving the prepared cache resolves with networking disabled..."
	docker run --rm --network none --platform linux/amd64 \
		-v "$IB_VOLUME:/builder" \
		-v "$HERE/repositories.offline:/builder/repositories:ro" \
		-v "$CACHE_OUT:/out" \
		-w /builder "$IB" \
		sh -eu -c '
			export STAGING_DIR_HOST=/builder/staging_dir/host
			CACHE_KEY=$1
			PROFILE=$2
			PACKAGES=$3
			TW_VERSION=$4
			LUCI_VERSION=$5
			rm -f packages/packages.adb
			make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES" > /out/offline.manifest
			grep -Fqx "travelwizard - $TW_VERSION" /out/offline.manifest
			grep -Fqx "luci-app-travelwizard - $LUCI_VERSION" /out/offline.manifest
			printf "%s\n" "$CACHE_KEY" > .travelwizard-cache/key
		' sh "$CACHE_KEY" "$PROFILE" "$PACKAGES" \
		"$TW_VERSION-r$TW_RELEASE" "$LUCI_VERSION-r$LUCI_RELEASE"

	cmp "$CACHE_OUT/online.manifest" "$CACHE_OUT/offline.manifest" >/dev/null ||
		die "online and offline package manifests differ"
	printf 'Prepared %s remote APKs in Docker volume %s.\n' \
		"$(sed -n 's/^remote_apks=//p' "$CACHE_OUT/cache-info.txt")" "$IB_VOLUME"
}

cache_is_ready() {
	[ -s "$CACHE_OUT/remote-packages.sha256" ] || return 1
	docker volume inspect "$IB_VOLUME" >/dev/null 2>&1 || return 1
	actual=$(docker run --rm --network none --platform linux/amd64 \
		-v "$IB_VOLUME:/builder" -w /builder "$IB" \
		sh -c 'cat .travelwizard-cache/key 2>/dev/null' || true)
	[ "$actual" = "$CACHE_KEY" ]
}

build_image() {
	cache_is_ready || die "APK cache is missing or stale; run ./travelwizard/build.sh prepare while online"
	build_local_packages
	find "$OUT/image" -maxdepth 1 -type f -delete

	printf '%s\n' "Assembling and finalizing the image (network disabled)..."
	docker run --rm --network none --platform linux/amd64 \
		-v "$IB_VOLUME:/builder" \
		-v "$OUT/ipk:/in:ro" \
		-v "$OUT/image:/out" \
		-v "$CACHE_OUT/remote-packages.sha256:/locked-remote-packages.sha256:ro" \
		-v "$HERE/repositories.offline:/builder/repositories:ro" \
		-v "$FEED/travelwizard:/source/travelwizard:ro" \
		-v "$FEED/luci-app-travelwizard:/source/luci-app-travelwizard:ro" \
		-w /builder "$IB" \
		sh -eu -c '
			export STAGING_DIR_HOST=/builder/staging_dir/host
			CACHE_KEY=$1
			PROFILE=$2
			PACKAGES=$3
			TW_APK=$4
			LUCI_APK=$5
			TW_VERSION=$6
			LUCI_VERSION=$7

			[ "$(cat .travelwizard-cache/key)" = "$CACHE_KEY" ]
			sha256sum -c /locked-remote-packages.sha256 >/dev/null
			REINDEX=0
			STALE=$(find packages -maxdepth 1 -type f -name "travelwizard-*.apk" ! -name "$TW_APK" -print -quit)
			if [ -n "$STALE" ]; then
				find packages -maxdepth 1 -type f -name "travelwizard-*.apk" ! -name "$TW_APK" -delete
				REINDEX=1
			fi
			STALE=$(find packages -maxdepth 1 -type f -name "luci-app-travelwizard-*.apk" ! -name "$LUCI_APK" -print -quit)
			if [ -n "$STALE" ]; then
				find packages -maxdepth 1 -type f -name "luci-app-travelwizard-*.apk" ! -name "$LUCI_APK" -delete
				REINDEX=1
			fi
			if ! cmp -s "/in/$TW_APK" "packages/$TW_APK"; then
				cp "/in/$TW_APK" packages/
				REINDEX=1
			fi
			if ! cmp -s "/in/$LUCI_APK" "packages/$LUCI_APK"; then
				cp "/in/$LUCI_APK" packages/
				REINDEX=1
			fi
			[ "$REINDEX" = 0 ] || rm -f packages/packages.adb
			make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" BIN_DIR=/out

			set -- /out/*.manifest
			[ "$#" -eq 1 ] && [ -f "$1" ]
			grep -Fqx "travelwizard - $TW_VERSION" "$1"
			grep -Fqx "luci-app-travelwizard - $LUCI_VERSION" "$1"
			set -- /out/*glinet_gl-mt3000*-sysupgrade.bin
			[ "$#" -eq 1 ] && [ -s "$1" ]

			set -- $(find build_dir -type d -path "*/root-mediatek")
			[ "$#" -eq 1 ]
			ROOT=$1
			for SOURCE_ROOT in /source/travelwizard/files /source/luci-app-travelwizard/files; do
				find "$SOURCE_ROOT" -type f -exec sh -eu -c '\''
					ROOT=$1
					SOURCE_ROOT=$2
					shift 2
					for SOURCE do
						RELATIVE=${SOURCE#"$SOURCE_ROOT"/}
						TARGET="$ROOT/$RELATIVE"
						[ -f "$TARGET" ] || { echo "missing from image root: $RELATIVE" >&2; exit 1; }
						cmp "$SOURCE" "$TARGET" || { echo "stale image file: $RELATIVE" >&2; exit 1; }
					done
				'\'' sh "$ROOT" "$SOURCE_ROOT" {} +
			done
			find "$ROOT/etc/rc.d" -type l -name "*tw-lan-switch" | grep -q .
			find "$ROOT/etc/rc.d" -type l -name "*tw-portal" | grep -q .
		' sh "$CACHE_KEY" "$PROFILE" "$PACKAGES" "$TW_APK" "$LUCI_APK" \
		"$TW_VERSION-r$TW_RELEASE" "$LUCI_VERSION-r$LUCI_RELEASE"

	cp "$CACHE_OUT/remote-packages.sha256" "$OUT/image/build-dependencies.sha256"
	{
		printf 'release=%s\n' "$REL"
		printf 'profile=%s\n' "$PROFILE"
		printf 'sdk_image=%s\n' "$SDK_ID"
		printf 'imagebuilder_image=%s\n' "$IB_ID"
		printf 'cache_key=%s\n' "$CACHE_KEY"
		printf 'travelwizard_apk=%s\n' "$TW_APK"
		printf 'luci_apk=%s\n' "$LUCI_APK"
	} > "$OUT/image/build-info.txt"
	shasum -a 256 "$OUT/image/"*sysupgrade.bin > "$OUT/image/travelwizard-image.sha256"
	printf 'OK: %s (offline build, cache %s)\n' "$OUT/image" "$CACHE_KEY"
}

case "$MODE" in
	prepare) prepare_cache ;;
	build) build_image ;;
esac
