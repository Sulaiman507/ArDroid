#!/bin/sh
# ArDroid rootfs builder — Arch Linux ARM (aarch64) + systemd.
# Runs INSIDE the Dockerfile builder stage whose filesystem (/) IS the
# Arch rootfs, so ROOTFS=/ and pacman runs natively (aarch64, emulated via
# qemu-user-static binfmt on x86_64 hosts).
set -eu
ROOTFS=/

# ── pacman sandbox ───────────────────────────────────────────────────────────
# pacman 7+ sandboxes package downloads with Landlock; qemu-user/Docker
# kernels (e.g. GitHub Actions runners) often lack Landlock, which makes
# every pacman download fail ("restricting filesystem access failed").
# This is a throwaway builder container, so disable the sandbox.
# (Removed again after the pacman run below — the shipped guest keeps
# pacman's default sandboxing.)
PACMAN_SANDBOX_DISABLED=0
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
    sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
    PACMAN_SANDBOX_DISABLED=1
fi

# ── neuter hooks that need a live systemd ────────────────────────────────────
# Most hooks go through /usr/share/libalpm/scripts/systemd-hook, which
# skips gracefully when systemd is not PID 1. A few call /usr/bin/systemctl
# DIRECTLY by absolute path instead — e.g. openssh's
# 10-openssh-mark-sshd-for-restart.hook ("Marking sshd.service for
# restart...") — and abort the whole transaction inside this builder
# container, where systemd can never be PID 1. Move such hooks aside for
# the pacman run (NoExtract keeps upgrades from reinstalling them), then
# restore everything afterwards so the shipped guest is pristine.
HOOKS_NEUTERED=""
mkdir -p /build/hooks-disabled
for hook in /usr/share/libalpm/hooks/*.hook; do
    [ -e "$hook" ] || continue
    if grep -qE '^Exec = /usr/bin/systemctl' "$hook"; then
        base="usr/share/libalpm/hooks/$(basename "$hook")"
        mv "$hook" /build/hooks-disabled/
        echo "NoExtract = $base" >> /etc/pacman.conf
        HOOKS_NEUTERED="$HOOKS_NEUTERED$base;"
    fi
done
# openssh's hooks arrive WITH the package during this transaction, so the
# scan above cannot see them — exclude the unguarded one explicitly:
OPENSSH_MARK_HOOK="usr/share/libalpm/hooks/10-openssh-mark-sshd-for-restart.hook"
if ! grep -qF "$OPENSSH_MARK_HOOK" /etc/pacman.conf; then
    echo "NoExtract = $OPENSSH_MARK_HOOK" >> /etc/pacman.conf
    HOOKS_NEUTERED="$HOOKS_NEUTERED$OPENSSH_MARK_HOOK;"
fi

# ── pacman keyring ───────────────────────────────────────────────────────────
# The Arch Linux ARM keyring ships in the tarball but is never initialized;
# without this every package install fails signature verification.
pacman-key --init
pacman-key --populate archlinuxarm

# ── packages ─────────────────────────────────────────────────────────────────
# Mirrors Podroid's Alpine set, mapped to Arch Linux ARM names (all verified
# against the ALARM aarch64 repo db). Deliberately NOT installed:
#   openrc/busybox-openrc -> systemd (in base) is the init system
#   gcompat               -> glibc is native on Arch, no compat layer needed
#   bridge-utils          -> not in the ALARM aarch64 repos; iproute2 covers it
#   lxc-templates         -> merged into Arch's lxc package
pacman -Syu --noconfirm \
    base systemd systemd-sysvcompat bash openssl \
    podman docker docker-compose \
    lxc dnsmasq \
    crun fuse-overlayfs \
    iptables nftables iproute2 \
    dropbear openssh \
    curl ca-certificates \
    shadow slirp4netns aardvark-dns netavark \
    libcap sudo opendoas \
    gzip xz \
    tigervnc pulseaudio \
    ttf-dejavu xorg-fonts-misc \
    dhcpcd \
    squashfs-tools

# ── box64 (x86_64 userspace emulator) ─────────────────────────────────────────
# Not in the ALARM repos (checked the aarch64 extra db); the AUR package's
# arch array includes aarch64, so it is built here with makepkg. Lets the guest
# run x86_64 binaries directly — the practical answer to "does ARM Arch run
# everything". Must run while DisableSandbox is still active above (the
# builder kernel lacks Landlock too).
#
# CI SPEEDUP: the workflow may provide a prebuilt package at
# /build/box64-prebuilt.pkg.tar.zst (actions/cache, keyed on the AUR HEAD sha).
# If present and valid, install it directly and skip the ~1.5h AUR compile.
# Otherwise build from the AUR and save the package to /build/box64.pkg.tar.zst
# so CI can cache it for the next build.
#
# box64.install's post_install runs `systemctl restart systemd-binfmt`;
# systemd is never PID 1 in this builder, so neuter it for the install.
mkdir -p /build/bin
printf '#!/bin/sh\nexit 0\n' > /build/bin/systemctl
chmod +x /build/bin/systemctl
if [ -s /build/box64-prebuilt.pkg.tar.zst ] && \
        pacman -Qip /build/box64-prebuilt.pkg.tar.zst >/dev/null 2>&1; then
    echo "Installing prebuilt box64 package (CI cache, skipping AUR compile)..."
    PATH=/build/bin:$PATH pacman -U --noconfirm /build/box64-prebuilt.pkg.tar.zst
    cp /build/box64-prebuilt.pkg.tar.zst /build/box64.pkg.tar.zst
else
    echo "Building box64 from the AUR (no usable cached package)..."
    # Build deps go in --asdeps so the orphan sweep afterwards drops exactly
    # what the build added. sudo/gzip are ALSO in base-devel: re-mark them
    # explicit so the sweep can't take them (the guest needs sudo for wheel).
    pacman -S --asdeps --noconfirm --needed base-devel git cmake python
    pacman -D --asexplicit sudo gzip
    useradd -m builder
    printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
    su builder -c 'git clone --depth 1 https://aur.archlinux.org/box64.git /tmp/box64-build && cd /tmp/box64-build && makepkg -s --noconfirm'
    # Ask makepkg for the exact package path (robust against naming variations).
    _pkg=$(su builder -c 'cd /tmp/box64-build && makepkg --packagelist' | head -1)
    if [ -z "$_pkg" ] || [ ! -f "$_pkg" ]; then
        echo "FATAL: box64 package not produced; /tmp/box64-build contains:" >&2
        ls -la /tmp/box64-build/ >&2
        exit 1
    fi
    PATH=/build/bin:$PATH pacman -U --noconfirm "$_pkg"
    cp "$_pkg" /build/box64.pkg.tar.zst
    rm -rf /tmp/box64-build
    userdel -r builder
    rm -f /etc/sudoers.d/builder
    # Drop the toolchain; the user can `pacman -S base-devel` themselves.
    _orp=$(pacman -Qtdq 2>/dev/null || true)
    if [ -n "$_orp" ]; then
        # shellcheck disable=SC2086
        pacman -Rs --noconfirm $_orp || true
    fi
fi
# Fail fast: the binary must actually execute on this (emulated) aarch64.
box64 --help > /dev/null || { echo "FATAL: box64 did not survive the build" >&2; exit 1; }
rm -rf /build/bin

# ── restore pacman.conf ──────────────────────────────────────────────────────
# The DisableSandbox above was a builder-only workaround; take it back out
# so the shipped guest keeps pacman's default download sandboxing.
if [ "$PACMAN_SANDBOX_DISABLED" = 1 ]; then
    sed -i '/^DisableSandbox$/d' /etc/pacman.conf
fi

# ── file capabilities for rootless podman ────────────────────────────────────
# setcap explicitly: the squashfs must ship the security.capability xattr
# (preserved by mksquashfs without -no-xattrs).
if command -v setcap >/dev/null 2>&1; then
    setcap cap_setuid+ep "$ROOTFS/usr/bin/newuidmap"
    setcap cap_setgid+ep "$ROOTFS/usr/bin/newgidmap"
fi

# ── privilege escalation ─────────────────────────────────────────────────────
chmod u+s "$ROOTFS/usr/bin/sudo" 2>/dev/null || true
# opendoas uses the same doas.conf format as Alpine's doas.
mkdir -p "$ROOTFS/etc/doas.d"
echo "permit persist :wheel" > "$ROOTFS/etc/doas.d/doas.conf"
chmod 0400 "$ROOTFS/etc/doas.d/doas.conf"
mkdir -p "$ROOTFS/etc/sudoers.d"
echo "%wheel ALL=(ALL) ALL" > "$ROOTFS/etc/sudoers.d/wheel"
chmod 0440 "$ROOTFS/etc/sudoers.d/wheel"

# ── root password "root" (pre-hashed; openssl makes a random salt) ─────────────
# NOTE: intentionally simple — the user asked for it (was "ardroid").
# Change it anytime inside the guest with `passwd`.
ROOT_HASH=$(openssl passwd -6 root)
sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$ROOTFS/etc/shadow"

# ── locale ───────────────────────────────────────────────────────────────────
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$ROOTFS/etc/locale.gen"
locale-gen
echo "LANG=en_US.UTF-8" > "$ROOTFS/etc/locale.conf"

# ── machine-id: empty file -> systemd generates a unique ID on first boot ────
: > "$ROOTFS/etc/machine-id"

# ── resolv.conf: podroid-network writes it directly; drop Arch's ─────────────
# systemd-resolved stub symlink (resolved isn't running in the guest).
rm -f "$ROOTFS/etc/resolv.conf"
: > "$ROOTFS/etc/resolv.conf"

# ── hostname ─────────────────────────────────────────────────────────────────
echo "ardroid" > "$ROOTFS/etc/hostname"
# NOTE: /etc/hosts is a read-only bind mount inside `docker build`, so it
# cannot be written here (the build failed with "Read-only file system").
# Stage the desired content instead; the guest installs it at first boot
# (see podroid-bootstrap.sh), where /etc/hosts is a regular writable file.
printf '127.0.0.1 localhost ardroid\n::1 localhost ip6-localhost\n' > "$ROOTFS/etc/hosts.ardroid"

# ── pacman: DisableSandbox in the GUEST image ─────────────────────────────────
# The VM kernel (Alpine's prebuilt vmlinuz-virt, reused as-is) has no Landlock
# support, so pacman 7's download sandbox can never work inside the guest —
# `pacman -Syu` fails with "restricting filesystem access failed because
# Landlock is not supported by the kernel!". The builder-only DisableSandbox
# above covers the image build; the guest needs its own copy, permanently.
if ! grep -q '^DisableSandbox' "$ROOTFS/etc/pacman.conf"; then
    sed -i 's/^\[options\]$/[options]\nDisableSandbox/' "$ROOTFS/etc/pacman.conf"
fi

# ── login banner ─────────────────────────────────────────────────────────────
cat > "$ROOTFS/etc/issue" <<'EOF'
Welcome to ArDroid (Arch Linux ARM)
Kernel \r on \m (\l)

  Default login:  root  /  root
  Change root password:    passwd
  Create a regular user:   useradd -m -G wheel <name>
                           (wheel group → can run sudo/doas)

EOF

# ── post-login welcome (shown by every login shell) ──────────────────────────
# Printed right after login; the pre-login greeting is /etc/issue (printed by
# agetty — see podroid-getty; it only looked unreliable while the hidden
# serial-getty@hvc0 twin raced our getty, now masked).
cat > "$ROOTFS/etc/profile.d/ardroid-welcome.sh" <<'EOF'
# ArDroid welcome banner (login shells only)
if [ -z "$ARDROID_WELCOME_SHOWN" ]; then
    export ARDROID_WELCOME_SHOWN=1
    printf '\n  Welcome to \033[1mArDroid\033[0m (Arch Linux ARM)\n'
    printf '  %-22s %s\n' "Update system:" "pacman -Syu"
    printf '  %-22s %s\n' "Run x86_64 binaries:" "box64 ./program"
    printf '  %-22s %s\n' "Containers:" "podman / docker / lxc"
    printf '  %-22s %s\n' "Change root password:" "passwd"
    printf '\n'
fi
EOF
chmod 644 "$ROOTFS/etc/profile.d/ardroid-welcome.sh"

# ── podroid helper scripts (portable sh; unchanged from Podroid) ─────────────
mkdir -p "$ROOTFS/usr/local/bin"
cp /build/files/usr/local/bin/podroid-resize  "$ROOTFS/usr/local/bin/"
cp /build/files/usr/local/bin/podroid-getty   "$ROOTFS/usr/local/bin/"
cp /build/files/usr/local/bin/podroid-backup  "$ROOTFS/usr/local/bin/"
# systemd service helpers (ported from the old OpenRC init.d scripts).
mkdir -p "$ROOTFS/usr/local/lib/podroid"
cp /build/files/usr/local/lib/podroid/*.sh "$ROOTFS/usr/local/lib/podroid/"
chmod 0755 "$ROOTFS"/usr/local/lib/podroid/*.sh
# vsock binaries are COPY'd from the vsock-builder Docker stage; the mode bit
# can be lost on some buildkit versions — guard it.
chmod +x "$ROOTFS/usr/local/bin/podroid-vsock-agent" 2>/dev/null || true
chmod +x "$ROOTFS/usr/local/bin/podroid-hostd" 2>/dev/null || true
chmod +x "$ROOTFS/usr/local/bin/podroid-overlay-normalize" 2>/dev/null || true
# The CLIs are argv[0]-dispatch symlinks onto the one multi-call binary.
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-notify"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-forward"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-open"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-power"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-headless"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-server"
chmod +x "$ROOTFS/usr/local/bin/podroid-"*

# ── systemd units ────────────────────────────────────────────────────────────
# Installed from files/etc/systemd/system; enabled via explicit symlinks
# (the build host can't chroot into the aarch64 rootfs to run systemctl).
mkdir -p "$ROOTFS/etc/systemd/system"
cp /build/files/etc/systemd/system/*.service "$ROOTFS/etc/systemd/system/"
chmod 0644 "$ROOTFS"/etc/systemd/system/podroid-*.service \
           "$ROOTFS"/etc/systemd/system/dropbear.service 2>/dev/null || true

# Vendor-unit ordering overrides (bind mounts from podroid-bootstrap, etc.).
mkdir -p "$ROOTFS/etc/systemd/system/docker.service.d"
cat > "$ROOTFS/etc/systemd/system/docker.service.d/podroid.conf" <<'EOF'
[Unit]
After=podroid-bootstrap.service
Before=podroid-ready.service
EOF
mkdir -p "$ROOTFS/etc/systemd/system/lxc.service.d"
cat > "$ROOTFS/etc/systemd/system/lxc.service.d/podroid.conf" <<'EOF'
[Unit]
After=podroid-bootstrap.service podroid-lxc-net.service
Before=podroid-ready.service
EOF
chmod 0644 "$ROOTFS"/etc/systemd/system/docker.service.d/podroid.conf \
           "$ROOTFS"/etc/systemd/system/lxc.service.d/podroid.conf

# Enable: everything the old OpenRC default runlevel started.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-resize \
           podroid-vsock podroid-downloads podroid-hostd podroid-x11 \
           podroid-lxc-net podroid-ready dropbear docker lxc; do
    # Our units live in /etc, vendor units (docker, lxc) in /usr/lib —
    # point the .wants symlink at the real location, never a dangling path.
    if [ -e "$ROOTFS/etc/systemd/system/$svc.service" ]; then
        _target="/etc/systemd/system/$svc.service"
    elif [ -e "$ROOTFS/usr/lib/systemd/system/$svc.service" ]; then
        _target="/usr/lib/systemd/system/$svc.service"
    else
        echo "WARN: unit $svc.service missing, skipping enable"
        continue
    fi
    ln -sf "$_target" \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/$svc.service"
done
# Serial gettys (backend-agnostic via podroid-getty wrapper, like inittab did).
mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
for inst in hvc0 ttyS0; do
    ln -sf "/etc/systemd/system/podroid-getty@.service" \
        "$ROOTFS/etc/systemd/system/getty.target.wants/podroid-getty@$inst.service"
done
# We use serial gettys only; mask the default tty1 getty.
ln -sf /dev/null "$ROOTFS/etc/systemd/system/getty@tty1.service"
# systemd-getty-generator auto-creates serial-getty@hvc0 at every boot when
# /dev/hvc0 exists; that hidden twin races podroid-getty@hvc0 for the same
# console input and scrambles logins (root-caused 2026-10-20). Mask it in the
# image too (the engines also pass systemd.mask= on the kernel cmdline).
ln -sf /dev/null "$ROOTFS/etc/systemd/system/serial-getty@hvc0.service"
# Boot straight into multi-user (no graphical.target needed; Xvnc is a unit).
ln -sf /usr/lib/systemd/system/multi-user.target \
    "$ROOTFS/etc/systemd/system/default.target"

# ── podroid state dirs ───────────────────────────────────────────────────────
mkdir -p "$ROOTFS/etc/podroid"
cp /build/files/etc/podroid/forwards.conf "$ROOTFS/etc/podroid/forwards.conf"
chmod 0644 "$ROOTFS/etc/podroid/forwards.conf"
mkdir -p "$ROOTFS/etc/podroid/migrations"
cp /build/files/etc/podroid/migrations/README "$ROOTFS/etc/podroid/migrations/"
for f in /build/files/etc/podroid/migrations/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$ROOTFS/etc/podroid/migrations/"
    chmod 0755 "$ROOTFS/etc/podroid/migrations/$(basename "$f")"
done
printf '%s\n' "${SYSTEM_VERSION:-0}" > "$ROOTFS/etc/podroid/system-version"
chmod 0644 "$ROOTFS/etc/podroid/system-version"

# ── /etc/profile.d (sourced by bash login shells, like on Alpine) ────────────
mkdir -p "$ROOTFS/etc/profile.d"
cp /build/files/etc/profile.d/podroid-color.sh "$ROOTFS/etc/profile.d/"
cp /build/files/etc/profile.d/podroid-x11.sh   "$ROOTFS/etc/profile.d/"
chmod 0644 "$ROOTFS/etc/profile.d/podroid-color.sh" "$ROOTFS/etc/profile.d/podroid-x11.sh"

# ── /etc/containers/storage.conf: pin Podman to the in-kernel overlay ────────
mkdir -p "$ROOTFS/etc/containers"
cp /build/files/etc/containers/storage.conf "$ROOTFS/etc/containers/storage.conf"
chmod 0644 "$ROOTFS/etc/containers/storage.conf"

# ── pre-create container storage dirs (saves first-boot mkdir) ──────────────
mkdir -p "$ROOTFS/var/lib/containers/storage" \
         "$ROOTFS/run/containers/storage" \
         "$ROOTFS/run/libpod" \
         "$ROOTFS/run/crun" \
         "$ROOTFS/mnt/persist" \
         "$ROOTFS/var/log"

# ── restore neutered hooks ───────────────────────────────────────────────────
# Bring back the hooks moved aside above, drop the NoExtract workarounds,
# and re-extract the skipped openssh hook from the package cache — so the
# shipped guest contains every file its packages ship. (Runs before the
# cache cleanup below.)
for hook in /build/hooks-disabled/*.hook; do
    [ -e "$hook" ] || continue
    mv "$hook" /usr/share/libalpm/hooks/
done
if [ -n "$HOOKS_NEUTERED" ]; then
    _rest="$HOOKS_NEUTERED"
    while [ -n "$_rest" ]; do
        _one="${_rest%%;*}"; _rest="${_rest#*;}"
        [ -n "$_one" ] && sed -i "\|^NoExtract = $_one\$|d" /etc/pacman.conf
    done
    _ospkg=$(ls /var/cache/pacman/pkg/openssh-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
    if [ -n "$_ospkg" ] && [ ! -e "/$OPENSSH_MARK_HOOK" ]; then
        tar -xf "$_ospkg" -C / "$OPENSSH_MARK_HOOK"
    fi
fi

# ── shrink: docs, caches, logs ───────────────────────────────────────────────
rm -rf "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/info"
rm -rf /var/cache/pacman/pkg/* /tmp/* /var/tmp/* "$ROOTFS/var/log"/*
# /etc/pacman.d/gnupg stays (keyring needed for future pacman runs).

echo "ArDroid rootfs ready."
