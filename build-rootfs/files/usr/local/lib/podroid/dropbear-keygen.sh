#!/bin/sh
# Generate Dropbear SSH host keys on first boot (Alpine's dropbear-openrc
# did this via its init script; Arch's dropbear package ships no unit).
set -u  # NOTE: no -e — these are best-effort boot scripts (ported from OpenRC); a single failing optional command must not abort the whole script
mkdir -p /etc/dropbear
for t in rsa ecdsa ed25519; do
    key="/etc/dropbear/dropbear_${t}_host_key"
    [ -f "$key" ] || dropbearkey -t "$t" -f "$key" >/dev/null 2>&1
done
exit 0
