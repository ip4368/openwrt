#!/bin/sh
# fw4 include entrypoint: re-apply the setup-portal state after every
# firewall (re)start. Derives state; never fails the firewall.
# Installed as a firewall include by tw-portal itself (idempotent).
${TW_PORTAL_BIN:-/usr/sbin/tw-portal} auto >/dev/null 2>&1
exit 0
