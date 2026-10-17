#!/bin/sh
# ArDroid X11 server wrapper: starts Xvnc in the background, then execs
# pulseaudio in the foreground (the systemd unit supervises this script;
# if pulseaudio dies the unit restarts, bringing Xvnc back too).
# Ported from Podroid's OpenRC podroid-x11 (start-stop-daemon replaced by
# plain backgrounding + a liveness poll).
set -eu

XVNC_DISPLAY=:0
XVNC_GEOMETRY=1280x720
XVNC_PORT=5900
PA_PORT=4713
PA_RUNTIME=/run/podroid-pulse
PA_LOGFILE=/var/log/pulse.log
XVNC_LOGFILE=/var/log/xvnc.log

# Per-boot DPI from the kernel cmdline token written by the Android app.
XVNC_DPI=$(sed -n 's/.*podroid\.x11\.dpi=\([0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null)
[ -z "$XVNC_DPI" ] && XVNC_DPI=96

# /tmp lives on the persistent ext4 overlay: wipe a stale X lock/socket.
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

mkdir -p "$PA_RUNTIME"
chmod 755 "$PA_RUNTIME"

/usr/bin/Xvnc $XVNC_DISPLAY \
    -geometry $XVNC_GEOMETRY \
    -depth 24 \
    -SecurityTypes None \
    -localhost no \
    -rfbport $XVNC_PORT \
    -AlwaysShared \
    -dpi $XVNC_DPI \
    -AcceptSetDesktopSize >>"$XVNC_LOGFILE" 2>&1 &
_xvnc_pid=$!

# Liveness poll: confirm the daemon survived launch (bad geometry / bound
# port kills it instantly). Caps at ~1s.
_i=0
while [ "$_i" -lt 10 ]; do
    sleep 0.1
    kill -0 "$_xvnc_pid" 2>/dev/null && break
    _i=$((_i + 1))
done
if ! kill -0 "$_xvnc_pid" 2>/dev/null; then
    echo "podroid-x11: Xvnc failed to start (see $XVNC_LOGFILE)" > /dev/console
    exit 1
fi

# PulseAudio in the foreground: --system=no with an explicit runtime dir so
# it runs as root without tripping pulse's "system mode is risky" refusal.
# Stdout goes to the unit's log (pulse.log) via StandardOutput=.
export PULSE_RUNTIME_PATH="$PA_RUNTIME"
export XDG_RUNTIME_DIR="$PA_RUNTIME"
exec /usr/bin/pulseaudio \
    --daemonize=no \
    --disallow-exit \
    --exit-idle-time=-1 \
    --load="module-null-sink sink_name=podroid_sink rate=44100 channels=2 format=s16le" \
    --load="module-simple-protocol-tcp source=podroid_sink.monitor record=true rate=44100 format=s16le channels=2 listen=0.0.0.0 port=$PA_PORT" \
    --load="module-native-protocol-unix"
