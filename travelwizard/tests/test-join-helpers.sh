#!/bin/sh
# Unit tests for join helpers: channel->band mapping (places the STA on the
# right radio) and scan-encryption->UCI mapping (picks the right WPA mode).
# Run: sh travelwizard/tests/test-join-helpers.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../feed/travelwizard/files/usr/lib/travelwizard/common.sh"

PASS=0
check() {
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
		echo "FAIL: $1: got [$2] want [$3]"; exit 1
	fi
}

check band-1 "$(tw_band_of_channel 1)" 2g
check band-6 "$(tw_band_of_channel 6)" 2g
check band-13 "$(tw_band_of_channel 13)" 2g
check band-14 "$(tw_band_of_channel 14)" 2g
check band-36 "$(tw_band_of_channel 36)" 5g
check band-44 "$(tw_band_of_channel 44)" 5g
check band-48 "$(tw_band_of_channel 48)" 5g
check band-149 "$(tw_band_of_channel 149)" 5g
check band-165 "$(tw_band_of_channel 165)" 5g
check band-empty "$(tw_band_of_channel '')" 2g
check band-junk "$(tw_band_of_channel 'Channel:')" 2g

check enc-open "$(tw_uci_encryption 'NONE')" none
check enc-open2 "$(tw_uci_encryption '')" none
check enc-psk "$(tw_uci_encryption 'WPA PSK (CCMP)')" psk-mixed
check enc-psk-tkip "$(tw_uci_encryption 'WPA PSK (TKIP / CCMP)')" psk-mixed
check enc-sae "$(tw_uci_encryption 'SAE (CCMP)')" sae
check enc-mixed "$(tw_uci_encryption 'WPA PSK / SAE / FT SAE (CCMP)')" sae-mixed
check enc-eap "$(tw_uci_encryption '802.1x (CCMP)')" eap
check enc-wep "$(tw_uci_encryption 'WEP Open (WEP-40)')" wep-open
check enc-future "$(tw_uci_encryption 'Something New (CCMP)')" sae-mixed

echo "PASS: join helpers ($PASS assertions)"
