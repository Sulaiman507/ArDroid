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
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
    sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
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

# ── root password "ardroid" (pre-hashed; openssl makes a random salt) ─────────
ROOT_HASH=$(openssl passwd -6 ardroid)
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
printf '127.0.0.1 localhost ardroid\n::1 localhost ip6-localhost\n' > "$ROOTFS/etc/hosts"

# ── login banner ─────────────────────────────────────────────────────────────
cat > "$ROOTFS/etc/issue" <<'EOF'
Welcome to ArDroid (Arch Linux ARM)
Kernel \r on \m (\l)

  Default login:  root  /  ardroid
  Change root password:    passwd
  Create a regular user:   useradd -m -G wheel <name>
                           (wheel group → can run sudo/doas)

EOF

# ── podroid helper scripts (portable sh; unchanged from Podroid) ─────────────
mkdir -p "$ROOTFS/usr/local/bin"
cp /build/files/usr/local/bin/podroid-resize  "$ROOTFS/usr/local/bin/"
cp /build/files/usr/local/bin/podroid-login   "$ROOTFS/usr/local/bin/"
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
    # Vendor units (docker, lxc) live in /usr/lib; ours in /etc. A .wants
    # symlink enables the unit by name even if its /etc target dangles.
    if [ -e "$ROOTFS/etc/systemd/system/$svc.service" ] || \
       [ -e "$ROOTFS/usr/lib/systemd/system/$svc.service" ]; then
        ln -sf "/etc/systemd/system/$svc.service" \
            "$ROOTFS/etc/systemd/system/multi-user.target.wants/$svc.service"
    else
        echo "WARN: unit $svc.service missing, skipping enable"
    fi
done
# Serial gettys (backend-agnostic via podroid-getty wrapper, like inittab did).
mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
for inst in hvc0 ttyS0; do
    ln -sf "/etc/systemd/system/podroid-getty@.service" \
        "$ROOTFS/etc/systemd/system/getty.target.wants/podroid-getty@$inst.service"
done
# We use serial gettys only; mask the default tty1 getty.
ln -sf /dev/null "$ROOTFS/etc/systemd/system/getty@tty1.service"
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

# ── shrink: docs, caches, logs ───────────────────────────────────────────────
rm -rf "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/info"
rm -rf /var/cache/pacman/pkg/* /tmp/* /var/tmp/* "$ROOTFS/var/log"/*
# /etc/pacman.d/gnupg stays (keyring needed for future pacman runs).

echo "ArDroid rootfs ready."
