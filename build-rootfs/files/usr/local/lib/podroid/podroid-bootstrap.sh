#!/bin/sh
# ArDroid VM system bootstrap (cgroups, modules, devpts, sysctl).
# Ported from Podroid's OpenRC podroid-bootstrap; runs as a systemd oneshot
# right after podroid-migrate.
set -eu

echo "Loading kernel modules..." > /dev/console

# Seed the system clock from the host. AVF/crosvm doesn't wire an
# emulated RTC the way QEMU TCG does, so without this the guest boots
# at epoch (1970-01-01) and every TLS cert appears "not yet valid".
# AvfEngine passes `podroid.epoch=<unix-secs>` on the cmdline; no-op when
# the marker is absent (QEMU path).
PODROID_EPOCH=$(sed -n 's/.*podroid\.epoch=\([0-9]*\).*/\1/p' /proc/cmdline)
if [ -n "$PODROID_EPOCH" ] && [ "$PODROID_EPOCH" -gt 0 ] 2>/dev/null; then
    date -s "@$PODROID_EPOCH" >/dev/null 2>&1
fi

# Rootless podman needs / to be a shared mount so user namespaces can
# propagate mount events.
mount --make-rshared / 2>/dev/null

# /dev sub-mounts
mkdir -p /dev/pts /dev/shm /dev/mqueue 2>/dev/null
mountpoint -q /dev/pts    || mount -t devpts devpts /dev/pts \
    -o gid=5,mode=0620,ptmxmode=0666,noexec,nosuid
mountpoint -q /dev/shm    || mount -t tmpfs tmpfs /dev/shm \
    -o noexec,nosuid,nodev,size=64m
mountpoint -q /dev/mqueue || mount -t mqueue mqueue /dev/mqueue \
    -o noexec,nosuid,nodev
mkdir -p /sys/kernel/config 2>/dev/null
mountpoint -q /sys/kernel/config || mount -t configfs -o nosuid,nodev,noexec \
    configfs /sys/kernel/config || true
[ -c /dev/ptmx ] || mknod /dev/ptmx c 5 2 2>/dev/null
chmod 0666 /dev/ptmx /dev/pts/ptmx 2>/dev/null

# Hostname
[ -r /etc/hostname ] && hostname -F /etc/hostname 2>/dev/null

depmod -a 2>/dev/null
for m in 9p 9pnet 9pnet_virtio; do modprobe "$m" 2>/dev/null; done

# I/O scheduler: mq-deadline is what overlay/ext4 prefers under
# random-write loads (Podman/Docker graph driver).
for q in /sys/block/vda/queue/scheduler /sys/block/vdb/queue/scheduler; do
    [ -w "$q" ] && echo mq-deadline > "$q" 2>/dev/null
done

# Downloads share (QEMU virtio-9p). On AVF, podroid-downloads owns
# /mnt/downloads instead (9p over vsock) — skip the virtio-9p attempt there.
if ! grep -q 'podroid\.backend=avf' /proc/cmdline 2>/dev/null; then
    mkdir -p /mnt/downloads 2>/dev/null
    mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=262144,cache=mmap,noatime \
        downloads /mnt/downloads 2>/dev/null
fi

mkdir -p /dev/net 2>/dev/null
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
[ -c /dev/fuse ]    || mknod /dev/fuse   c 10 229 2>/dev/null
# Rootless containers need /dev/net/tun and /dev/fuse accessible to non-root.
chmod 0666 /dev/net/tun /dev/fuse 2>/dev/null

# cgroup v2 subtree controllers
mkdir -p /sys/fs/cgroup 2>/dev/null
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 cgroup2 /sys/fs/cgroup
printf '+cpuset +cpu +io +memory +hugetlb +pids +rdma\n' \
    > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null

# ZRAM swap (1.5x RAM, lz4).
if [ -b /dev/zram0 ]; then
    _mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null
    # *1536 = KiB→bytes (*1024) × 1.5 ratio; disksize wants bytes.
    echo $((_mem_kb * 1536)) > /sys/block/zram0/disksize 2>/dev/null
    mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null
fi

# OOM behavior: kernel default (0 = OOM killer picks the highest-badness
# victim). Per-service immunity is set in podroid-ready.
[ -w /proc/sys/vm/oom_kill_allocating_task ] && \
    echo 0 > /proc/sys/vm/oom_kill_allocating_task
# overcommit_memory=1 lets us hand out the address space browsers want
# without ENOMEM at mmap time.
[ -w /proc/sys/vm/overcommit_memory ] && \
    echo 1 > /proc/sys/vm/overcommit_memory

# sysctl for container networking
sysctl -qw net.ipv4.ip_forward=1 \
    net.ipv4.conf.all.forwarding=1 \
    net.ipv6.conf.all.forwarding=1 \
    net.ipv6.conf.default.forwarding=1 \
    net.bridge.bridge-nf-call-iptables=1 \
    net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null

# Bind /var/lib/docker onto raw ext4: Docker's overlay2 can't stack on the
# rootfs overlay (EINVAL), so without this `docker run` fails.
mkdir -p /mnt/persist/docker /var/lib/docker 2>/dev/null
mountpoint -q /var/lib/docker || mount --bind /mnt/persist/docker /var/lib/docker

# Same trick for Podman (kernel overlay can't stack on the rootfs overlay).
mkdir -p /mnt/persist/containers /var/lib/containers/storage 2>/dev/null
mountpoint -q /var/lib/containers/storage \
    || mount --bind /mnt/persist/containers /var/lib/containers/storage

# And for LXC.
mkdir -p /mnt/persist/lxc /var/lib/lxc 2>/dev/null
mountpoint -q /var/lib/lxc || mount --bind /mnt/persist/lxc /var/lib/lxc

# NOTE: the lxc bridge (lxcbr0, 10.0.3.1/24) + MASQUERADE/DHCP is owned by
# podroid-lxc-net.service (the Arch replacement for Alpine's dnsmasq.lxcbr0).

exit 0
