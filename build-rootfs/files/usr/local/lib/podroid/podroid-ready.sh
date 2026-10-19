#!/bin/sh
# ArDroid VM ready marker (consumed by the Android boot detector).
# Ported from Podroid's OpenRC podroid-ready: runs after everything else.
set -u  # NOTE: no -e — these are best-effort boot scripts (ported from OpenRC); a single failing optional command must not abort the whole script

# OOM-protect ArDroid's infrastructure processes so a hungry user app
# (Firefox, Chromium, big npm builds, podman pulls) gets reaped first.
# -1000 makes a process completely immune to OOM. Match by argv[0]
# basename instead of pidfile to catch all variants (multiple Xvnc
# screens, forked dropbear instances per SSH session, the agent's
# listener children).
for _name in dropbear Xvnc pulseaudio podroid-vsock-agent dnsmasq; do
    for _pid in $(pgrep -x "$_name" 2>/dev/null); do
        echo -1000 > "/proc/$_pid/oom_score_adj" 2>/dev/null
    done
done

# Emit the boot stages the BootStageDetector expects.
echo "Starting SSH..." > /dev/console
echo "Almost ready..." > /dev/console
echo "Ready!" > /dev/console
exit 0
