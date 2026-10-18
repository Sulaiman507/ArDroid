#!/bin/sh
# ArDroid LXC bridge (lxcbr0, 10.0.3.1/24) with NAT + DHCP/DNS.
# Arch replacement for Alpine's dnsmasq.lxcbr0 (lxc-bridge) OpenRC service:
# creates the bridge, assigns the address, serves DHCP/DNS to containers,
# and masquerades their traffic. dnsmasq daemonizes itself and stays up.
set -u  # NOTE: no -e — these are best-effort boot scripts (ported from OpenRC); a single failing optional command must not abort the whole script

ip link show lxcbr0 >/dev/null 2>&1 || ip link add lxcbr0 type bridge
ip addr show lxcbr0 2>/dev/null | grep -q '10.0.3.1/24' \
    || ip addr add 10.0.3.1/24 dev lxcbr0
ip link set lxcbr0 up

# NAT for container traffic (skip if the rule already exists).
iptables -t nat -C POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 \
    -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 10.0.3.0/24 ! -d 10.0.3.0/24 \
        -j MASQUERADE

# One dnsmasq instance bound to lxcbr0 only.
pkill -f 'dnsmasq.*/run/dnsmasq-lxcbr0.pid' 2>/dev/null || true
dnsmasq --interface=lxcbr0 --bind-interfaces \
    --except-interface=lo \
    --dhcp-range=10.0.3.2,10.0.3.254,255.255.255.0 \
    --dhcp-option=option:router,10.0.3.1 \
    --pid-file=/run/dnsmasq-lxcbr0.pid

echo "lxcbr0 ready (10.0.3.1/24)" > /dev/console
exit 0
