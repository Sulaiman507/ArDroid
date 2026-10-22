# AGENTS.md

Guidance for AI assistants (سلوم/Muse, and any other agent or new contributor) working in this repository. This is the deep map: read it before touching anything. Keep it accurate when you change the code.

## What Is This

ArDroid is an Android app that runs a real **Arch Linux ARM** Linux VM on stock Android 8+ (arm64) to provide rootless **Podman / Docker / LXC** containers and an in-app **X11 desktop** - no root, no custom recovery. **box64** is pre-installed so x86_64 Linux binaries run on the ARM phone.

It is a fork of [Podroid](https://github.com/ExTV/Podroid) (ExTV/Podroid@ce01218, imported as one squashed commit - history not preserved) with the Alpine guest replaced by Arch Linux ARM. The app layer (Kotlin, engines, terminal, X11 viewer) is unchanged from upstream; only the guest rootfs and its bringup differ.

- **Two interchangeable VM backends** behind one interface (`VmEngine`):
  - **QEMU (TCG)** - software emulation, the default, needs no special permission.
  - **AVF (pKVM)** - hardware-accelerated via the Android Virtualization Framework on Pixel-class devices, after a one-time `pm grant`.
- The guest is a standard Arch Linux ARM root with **systemd as PID 1**. System services live in `/etc/systemd/system/podroid-*` on a read-only squashfs; a persistent ext4 overlay captures user changes (`pacman -S`, `systemctl enable`).
- An embedded **Termux-based terminal**, an **X11/VNC viewer** (Xvnc + PulseAudio), and a **guest-to-Android bridge** (`podroid-notify` / `podroid-forward`) round it out.
- **The kernel and initramfs are prebuilt and reused from Podroid** - kernel CONFIG changes in this repo do NOT take effect. Only the rootfs is built here.

## Key Facts

| | |
|---|---|
| Package | `com.excp.podroid` (debug: `com.excp.podroid.debug`) - rebrand deferred |
| Version | `versionName` / `versionCode` in `app/build.gradle.kts` |
| Min / target SDK | 26 (Android 8) / 36 |
| Architecture | arm64 (`aarch64`) only |
| Guest | Arch Linux ARM squashfs + persistent ext4 overlay, systemd PID 1 |
| Guest extras | `box64` (x86_64 userspace emulator, built from AUR), `podman`, `docker`, `lxc` |
| Root login | `root` / `root` (intentionally simple; change with `passwd` in the guest) |
| Kernel | prebuilt `vmlinuz-virt` reused from Podroid (Alpine-based); repo kernel configs are inert |
| QEMU | prebuilt `.so` reused from Podroid |
| UI | Jetpack Compose + Material 3, single Activity |
| DI | Hilt (constructor injection) |
| Async | Coroutines + StateFlow |
| Persistence | Jetpack DataStore (no database; Room is declared but unused) |
| Terminal | vendored Termux fork as local Gradle modules (`terminal-view`, `terminal-emulator`) |
| Languages | English + 中文 (Chinese); see `data/repository/LanguageManager.kt` + `res/values-zh/` |

## Build Commands

**Primary path: cloud build via GitHub Actions** (local Docker builds are impossible - no ARM emulation/binfmt on the dev VM):

1. Open the repo's **Actions** tab → **Build ArDroid APK (cloud)** → **Run workflow** on the branch (workflow_dispatch only).
2. The workflow downloads the Podroid v1.2.9 APK, extracts the prebuilt kernel/initramfs/QEMU `.so`, builds only the Arch rootfs via Docker (emulated aarch64), then `assembleDebug`.
3. Download the `ardroid-debug-apk` artifact when it finishes (~3h, box64 compiles from source under emulation).

```bash
./gradlew assembleDebug        # APK only (needs arch-rootfs.squashfs in app/src/main/assets/)
./gradlew installDebug
./gradlew :app:testDebugUnitTest   # unit tests (use the :app: form, not the bare task)
```

**Monitor VM boot:**
```bash
adb logcat -s PodroidQemu
adb shell run-as com.excp.podroid.debug cat files/console.log   # debug build
```

Native binaries require **16KB page alignment** (`-Wl,-z,max-page-size=16384`) - mandatory on Android 13+.

## Architecture

### Engine abstraction (the most important thing to understand)

Everything VM-related goes through `engine/VmEngine.kt`, a single interface implemented by two backends and one router:

- **`QemuEngine.kt`** - QEMU/TCG. Software emulation, SLIRP user-mode networking, control via QMP and virtio-console Unix sockets. No special permission.
- **`engine/avf/AvfEngine.kt`** - AVF/pKVM. Uses the Android Virtualization Framework (reached by reflection in `AvfReflect.kt`); networking and control ride **vsock**. Hardware-accelerated; needs `MANAGE_VIRTUAL_MACHINE` + `USE_CUSTOM_VIRTUAL_MACHINE` granted via `pm grant`.
- **`EngineHolder.kt`** - the single Hilt binding for `VmEngine`. Picks the concrete engine at startup based on `EngineSelection` (Auto / AVF / QEMU), watches Settings for backend changes, and routes imperative calls + flow access to whichever is current. Also owns the live diff that applies `PortForwardRepository` changes to the running VM.

When you touch VM behavior, decide whether it is backend-neutral (put it behind `VmEngine` / `EngineHolder`) or backend-specific (inside `QemuEngine` or `AvfEngine`).

### Data flow

```
Terminal UI (Compose)
    | TerminalSession (vendored Termux JNI)
libpodroid-bridge.so  <->  terminal.sock + ctrl.sock  <->  VM  <->  hvc0 + hvc1
boot monitor          <->  serial.sock (QEMU) / console stream (AVF)  ->  console.log + boot-stage detector
QmpClient             <->  qmp.sock (QEMU only)        -> runtime port forwards (netdev_add/remove)
HostRequestServer     <->  host.sock/hvc2 (QEMU) | vsock:9101 (AVF)    <- podroid-notify / podroid-forward
```

QEMU exposes these Unix sockets under `context.filesDir`, each with one role:

- **`terminal.sock`** ↔ virtio-console `/dev/hvc0` - primary terminal I/O. getty runs on hvc0; `libpodroid-bridge.so` relays it to a Termux PTY.
- **`ctrl.sock`** ↔ virtio-console `/dev/hvc1` - resize channel. The bridge debounces SIGWINCH bursts and writes one `RESIZE rows cols\n`; a guest resize daemon `stty`s hvc0.
- **`serial.sock`** ↔ PL011 `/dev/ttyAMA0` - boot-log sink only. The boot monitor streams kernel + init output into `console.log` and the boot-stage detector.
- **`qmp.sock`** - QEMU Machine Protocol for runtime port forwards + USB hot-plug.
- **`host.sock`** ↔ virtio-console `/dev/hvc2` - the guest→Android host bridge (see below).

On **AVF** there is no QMP and no PL011: the console is captured via `ConsoleFanout.kt`, control/resize go over `VsockControlChannel.kt`, port forwards over `VsockPortForwarder.kt`, and the host bridge over vsock port 9101.

### Boot pipeline

1. The engine launches the VM and starts the boot monitor (`QemuBootMonitor.kt` for QEMU; the console stream for AVF). `BootStageDetector.kt` scans the rolling console buffer (last ~1KB, not per-`read()` chunk - fast devices split markers like `Ready!` across reads).
2. **`init-podroid`** (initramfs, Alpine-based stub): mounts the persistent ext4 (`/dev/vda` → upper) and the read-only squashfs (`/dev/vdb` → lower), stacks an overlayfs, moves the mounts into the new root, and `switch_root`s into systemd.
3. **systemd** (PID 1) starts the `podroid-*` units (all under `build-rootfs/files/etc/systemd/system/`):
   - `podroid-bootstrap.service` - kernel modules, cgroup v2, devpts/shm/mqueue, sysctl, ZRAM swap, `mount --make-rshared /`, container dirs, `/etc/hosts` install.
   - `podroid-network.service` - eth0 up, addressing, default route, `/etc/resolv.conf`.
   - `podroid-lxc-net.service` - LXC bridge networking (dnsmasq).
   - `podroid-resize.service` - reads `RESIZE rows cols` from `/dev/hvc1`, `stty`s `/dev/hvc0`.
   - `podroid-hostd.service` - the host-bridge daemon (both backends).
   - `podroid-vsock.service` - the AVF control/forward agent (AVF boots only).
   - `dropbear.service` - SSH, when enabled.
   - `podroid-downloads.service` - Downloads-folder sharing.
   - `podroid-x11.service` - Xvnc + PulseAudio for the X11 viewer.
   - `podroid-migrate.service` - one-shot guest migrations on version change.
   - `podroid-getty@.service` - plain `agetty` on hvc0 via the `podroid-getty` wrapper (picks the tty from the `podroid.tty=` cmdline marker; Arch has `/sbin/agetty`, no `/sbin/getty`). The wrapper also restores the winsize from `/run/term_size` via `stty -F` (moved here from the deleted `podroid-login`). **Never pass `-l` here:** the host-side bridge connects to the console after boot (QEMU's chardev discards whatever agetty printed before that) and then sends a lone-CR "kick"; plain agetty reads it as an empty login name and re-displays `/etc/issue` + the login prompt — that re-display is the ONLY `/etc/issue` the user ever sees. With `-l` the CR landed in `/bin/login` (which never prints `/etc/issue`) and the pre-login greeting stayed invisible (root-caused 2026-10-21). `-t 30` was REMOVED 2026-10-22: with systemd Restart=always it re-printed the banner every 30 idle seconds in an endless loop (seen on-device). The kick-wait gate made it obsolete — agetty only starts once the bridge is attached, so the greeting prints exactly once; restarts now happen only on real logout: agetty exits after 30s idle at the login prompt and systemd restarts it, re-printing `/etc/issue` once the bridge is attached (verified on-device: the issue appears on every getty restart). Deeper: agetty frees the issue text from memory after its first print (util-linux issuefile.c), so the bridge's CR kick could only ever re-display an empty prompt — the kick had to become a *start* gate instead. The wrapper now waits for the kick (`timeout 30 dd` consuming one byte from the tty) before exec'ing agetty, but only on the first start after boot (flag `/run/ardroid-getty-kicked`); restarts skip the wait. Root-caused 2026-10-22. **Never let another getty share hvc0:** `systemd-getty-generator` auto-creates `serial-getty@hvc0` whenever `/dev/hvc0` exists — that hidden twin raced this getty for console input and scrambled logins (split/lost keystrokes, echoed passwords, doubled prompts; root-caused 2026-10-20). It is masked twice: an `/etc/systemd/system/serial-getty@hvc0.service` → `/dev/null` symlink baked into the image by `build-rootfs.sh`, and `systemd.mask=serial-getty@hvc0.service` on the guest cmdline from both engines.
   - `podroid-ready.service` - emits `Starting SSH...` / `Almost ready...` / `Ready!`, the markers `BootStageDetector` matches; `Ready!` flips state to `Running` and auto-starts the terminal bridge.
4. Two greetings: **before login**, agetty prints `/etc/issue` (default login + tips); **after login**, `/etc/profile.d/ardroid-welcome.sh` prints the welcome banner. (The issue text was long suppressed with `--noissue` for 'unreliability' — that was actually the `serial-getty@hvc0` twin printing it at random times; with the twin masked it is deterministic again.)

**Why `switch_root`, not `chroot`:** an earlier version `chroot`ed into the overlay, which broke `podman exec -it` - `setns(MNT)` in `crun exec` resets `fs->root`, so the exec'd process saw raw kernel paths (`/mnt/overlay/proc`) instead of `/proc`. `switch_root` reorganizes the kernel mount tree itself, so namespace forks see a clean `/`.

### Guest → Android host bridge

Lets guest processes call back to Android. Guest side: `podroid-hostd` (multi-call C binary, `build-rootfs/host-bridge/podroid-hostd.c`) owns a guest-local `AF_UNIX` socket `/run/podroid-host.sock`; `argv[0]` dispatch also exposes it as `podroid-notify` and `podroid-forward` (symlinks). The daemon relays one request line / one response line to Android over a backend transport: `/dev/hvc2` on QEMU, `AF_VSOCK:9101` on AVF (chosen by the `podroid.backend=avf` cmdline marker). Android side: `engine/hostbridge/` - `HostRequestServer` reads requests over a `HostTransport` (`QemuHostTransport` via `LocalSocket` to `host.sock`, or `AvfHostTransport` via `connectVsock`), `HostRequestDispatcher` parses them, and routes to `NotificationPoster` (posts via `NotificationManagerCompat`) or `PortForwardRepository` (rules persist and `EngineHolder` applies them live). `PodroidService` starts/stops the server over the VM lifecycle. Stop or parent cancellation shuts down the active transport to unblock reads; a transport returned by a late native connect is closed without dispatching. Android accepts only complete UTF-8 request lines up to 8191 bytes (matching the guest buffer). Free-text fields are base64 (`HostProtocol.kt`) so UTF-8 survives. The daemon also self-originates a `STATS containers=<n>` push (inotify-driven, debounced) whenever the podman container count changes, which `HostRequestDispatcher` persists to the `last_container_count` DataStore key for `HomeViewModel` to show live on Home - the same channel on both backends, no polling.

> **Gotcha:** `/dev/hvc2` is a virtio-console **TTY** that defaults to echo on. The daemon must `cfmakeraw()` it, or the TTY echoes Android's responses back and the protocol desyncs after the first request. AVF (a raw vsock socket) is unaffected.

### Downloads sharing over 9p (`engine/avf/AvfDownloadsShare.kt` + `engine/avf/ninep/`)

**AVF only.** Serves the real Android Downloads directory into the guest by running an in-process **9p2000.L** server (`Ninep2000LServer.kt`, ~886 LoC; wire format in `NinepCodec.kt`) over vsock. This is why the guest can read and write user files without the app holding broad storage permissions, and it is how `podroid-backup` archives land in `Downloads/Podroid/backups` for `ContainerBackupRepository` to list.

There is no QEMU equivalent, so any feature built on the share is backend-asymmetric by construction and must degrade cleanly on QEMU.

### USB passthrough (`engine/usb/UsbPassthroughManager.kt`)

QEMU backend only. An unprivileged app can't open `/dev/bus/usb`, so it takes the already-open fd from `UsbManager`/`UsbDeviceConnection` and streams it to QEMU over `qmp.sock` as SCM_RIGHTS (`add-fd`), then hot-plugs with `device_add usb-host,hostdevice=/dev/fdset/N`. A code-registered `BroadcastReceiver` (no manifest `device_filter.xml`) is live only while the VM is `Running`. Gated by the `usb_passthrough_enabled` setting, which also makes `buildCommand()` emit `-device qemu-xhci`. Needs a libusb-enabled QEMU build.

### X11 viewer (`x11/` + `ui/screens/x11/`)

In-app viewer that talks RFB to `Xvnc` in the guest, with touch→mouse, soft-keyboard, external mouse/keyboard, fullscreen, rotation lock, resolution presets, and PCM audio over PulseAudio loopback. Backed by always-on implicit VNC/audio port forwards.

### Terminal keyboard

`TerminalViewModel.shouldEnforceCharBasedInput()` returns `true`, so the soft keyboard runs char-based (`TYPE_TEXT_VARIATION_VISIBLE_PASSWORD | TYPE_TEXT_FLAG_NO_SUGGESTIONS`) and keystrokes reach the guest verbatim. Do NOT flip this back to `false` (`TYPE_NULL`) for word suggestions: that was tried in 6e93d6e and reverted on 2026-10-20 — with `TYPE_NULL` the IME commits composed/autocorrected text, which silently altered the getty password on the owner's phone (login rejected a password whose stored hash was verified correct). Suggestions stay off until an input path exists that cannot rewrite committed text.

### Internationalization

`data/repository/LanguageManager.kt` + `res/values/` / `res/values-zh/`. `MainActivity.attachBaseContext` wraps the context for the saved locale (read synchronously from a cache file before Hilt is available); changing the language in Settings persists it and recreates the Activity. Don't reintroduce hardcoded user-facing strings - use `stringResource` and keep `values` / `values-zh` in sync.

### Navigation

Single-activity Compose app: `ui/navigation/NavGraph.kt` routes `setup → home → terminal / settings / x11`. `TerminalViewModel` is scoped outside the `NavHost` so the session survives screen changes. The setup wizard shows until setup is marked complete in DataStore.

## Project Structure

```
/
├── app/                              # Android module
│   └── src/main/
│       ├── java/com/excp/podroid/
│       │   ├── MainActivity.kt           # single Activity, locale wrap, WindowSizeClass
│       │   ├── PodroidApplication.kt     # Hilt app, asset extraction on first run
│       │   ├── engine/
│       │   │   ├── VmEngine.kt           # backend interface
│       │   │   ├── EngineHolder.kt       # Hilt binding; routes to current engine; port-forward diff
│       │   │   ├── EngineModule.kt, EngineSelection.kt
│       │   │   ├── QemuEngine.kt         # QEMU/TCG backend, buildCommand()
│       │   │   ├── QemuBootMonitor.kt, BootStageDetector.kt
│       │   │   ├── QmpClient.kt          # QMP: port forwards + USB add-fd
│       │   │   ├── ResizeNotifyingSession.kt, VmState.kt
│       │   │   ├── avf/                  # AVF/pKVM backend (engine, reflection, vsock, console)
│       │   │   │   ├── AvfDownloadsShare.kt  # live Downloads share, AVF only (see below)
│       │   │   │   ├── AvfDiagnostics.kt     # AVF diagnostic + smoke-test entry point
│       │   │   └── ninep/                # in-process 9p2000.L server (Ninep2000LServer, NinepCodec)
│       │   │   ├── hostbridge/           # guest->Android bridge (transport, server, dispatcher, notify)
│       │   │   │   └── HeadlessModeManager.kt # single source of truth for server (headless) mode
│       │   │   ├── control/              # ControlProvider: shell-only `adb shell content call` test interface
│       │   │   └── usb/                  # UsbPassthroughManager
│       │   ├── service/PodroidService.kt # foreground service; owns VM lifecycle, wakelock, notification; also VmControlReceiver (boot autostart + START_VM/STOP_VM automation intents)
│       │   ├── data/repository/          # Settings, PortForward, Update, Language, ContainerBackup (all DataStore)
│       │   ├── di/                       # Hilt module
│       │   ├── util/                     # NetworkUtils, ShellQuote, HostMetrics + VmLoadSampler (Status screen), DeviceResourcePolicy (load-balance sizing)
│       │   ├── x11/                      # X11/VNC viewer engine
│       │   └── ui/                       # Compose: navigation, theme, screens/{setup,home,terminal,settings,x11,status,backup}, components
│       ├── res/values, res/values-zh/    # strings (EN + Chinese)
│       ├── assets/                       # vmlinuz-virt, initrd.img, arch-rootfs.squashfs (all gitignored, built via CI),
│       │                                 # qemu/, colors/ (122), fonts/ (13), ui-fonts/
│       └── jniLibs/arm64-v8a/            # native executables (see below)
├── terminal-view/, terminal-emulator/   # vendored Termux fork (local Gradle modules)
├── init-podroid                         # initramfs bootstrap: overlay + switch_root (Alpine-based stub, prebuilt)
├── podroid-bridge.c                     # PTY <-> virtio-console relay -> libpodroid-bridge.so
├── podroid-launcher.c                   # exec wrapper that ties QEMU's lifetime to the app -> libpodroid-launcher.so
├── build-rootfs/
│   ├── Dockerfile.rootfs, build-rootfs.sh   # Arch Linux ARM rootfs build (pacman + box64 from AUR)
│   ├── vsock-agent/                     # podroid-vsock-agent.c (AVF control/forward agent)
│   ├── host-bridge/                     # podroid-hostd.c (guest->Android bridge daemon + CLIs)
│   └── files/                           # systemd units, helpers, configs baked into the squashfs
│       ├── etc/systemd/system/          # 12 podroid-*.service units (+ podroid-getty@.service)
│       └── usr/local/bin/               # podroid-getty, podroid-bootstrap, ...
├── .github/workflows/build-apk.yml     # cloud build (workflow_dispatch): rootfs via Docker + assembleDebug
└── README.md, CONTRIBUTING.md, CREDITS.md
```

## Native Binaries (`app/src/main/jniLibs/arm64-v8a/`)

ELF executables renamed `.so` for APK packaging; run via `ProcessBuilder` / `TerminalSession`, not loaded as JNI libraries. All 16KB-aligned.

| File | What it is |
|---|---|
| `libqemu-system-aarch64.so` | QEMU TCG emulator (prebuilt, reused from Podroid) |
| `libpodroid-bridge.so` | PTY ↔ virtio-console relay (from `podroid-bridge.c`) |
| `libpodroid-launcher.so` | exec wrapper for QEMU process lifetime (from `podroid-launcher.c`) |
| `libslirp.so` | SLIRP user-mode networking (soname patched `.so.0`→`.so`) |

The terminal emulator JNI is built from the vendored `terminal-emulator` module (rebuilt for 16KB pages), not shipped as a prebuilt here.

## QEMU command construction (`QemuEngine.buildCommand()`)

- `-serial unix:serial.sock` (boot log) + a `virtio-serial-pci` bus carrying three virtconsoles: `terminal.sock` (hvc0), `ctrl.sock` (hvc1), `host.sock` (hvc2, the host bridge - **order matters**, the guest expects host bridge on hvc2).
- `-qmp unix:qmp.sock` for runtime port forwards + USB.
- RAM, CPU count, and user-editable extras (`-cpu`, `-accel`, RNG, etc.) from `SettingsRepository`.
- Two virtio block devices: `/dev/vda` ← `storage.img` (writable ext4 overlay upper, resized on first boot), `/dev/vdb` ← `arch-rootfs.squashfs` (read-only zstd lower).
- SLIRP networking; `-device qemu-xhci` when USB passthrough is enabled.

## Build pipelines

- **`.github/workflows/build-apk.yml`** (the real build): downloads the Podroid v1.2.9 release APK, extracts the prebuilt `vmlinuz-virt`/`initrd.img`/QEMU `.so`, builds the Arch rootfs with Docker (emulated aarch64), then Gradle `assembleDebug`. Artifact: `ardroid-debug-apk`.
- **Build speedups** (both automatic, both fall back to a full rebuild on any doubt):
  - *Rootfs reuse:* if `build-rootfs/` and the workflow file are unchanged since the last successful run, the `arch-rootfs.squashfs` is downloaded from that run's `arch-rootfs-squashfs` artifact instead of rebuilding (~15 min vs ~3h). Every run re-uploads the squashfs to keep the chain alive.
  - *box64 package cache:* `actions/cache` keyed on the AUR HEAD sha; `build-rootfs.sh` installs `/build/box64-prebuilt.pkg.tar.zst` when valid, else compiles from the AUR and exports the package for the next run (~1.5h saved).
- **`build-rootfs/Dockerfile.rootfs`** - fetches the Arch Linux ARM aarch64 tarball, runs `build-rootfs.sh`: `pacman -Syu` (base + systemd + podman + docker + lxc + dropbear + openssh + tigervnc + pulseaudio + ...), builds **box64 from the AUR** as a throwaway `builder` user (build deps installed `--asdeps`, orphan-swept after; `sudo`/`gzip` re-marked `--asexplicit` so the sweep can't remove them), writes `/etc/issue` + `/etc/profile.d/ardroid-welcome.sh`, sets the root password hash, installs the 12 systemd units + helpers, then `mksquashfs -comp zstd`. A build-time check `unsquashfs -l`s the image and **fails the build** if `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, or `/usr/bin/box64` are missing.
- The local `Dockerfile` / `build-all.sh` kernel+QEMU stages are **legacy** - the kernel and QEMU are prebuilt and reused; do not spend time on kernel configs.

## Performance tuning (TCG path; KVM is impossible without root)

In `QemuEngine.buildCommand()`: `tcg,thread=multi`, larger `tb-size` for ≥2GB RAM, dedicated `iothread` on `virtio-blk-pci`, `-cpu max,pauth-impdef=on`. More vCPUs are not better here: on an 8-core phone, 8 measured slower than 4 on every metric. Guest cmdline: `mitigations=off` (safe inside TCG), per-device `mq-deadline`. `init-podroid`/bootstrap: ZRAM lz4 swap at 1.5x RAM (lz4 averages about 3x, so the backing store stays well under RAM). `CONFIG_EXT4_FS_SECURITY=y` + `CONFIG_SQUASHFS_XATTR=y` keep `security.capability` xattrs across the overlay (rootless podman's `newuidmap` needs them). What won't work without root: `io_uring` (seccomp), CPU affinity, KSM, TAP networking, host hugepages.

## Quirks & gotchas

- **The kernel is prebuilt - repo kernel configs are inert.** Don't tune `podroid_kernel.config`; it changes nothing in the shipped APK.
- **pacman needs `DisableSandbox`.** The reused kernel lacks Landlock, so pacman 7's sandbox fails with "restricting filesystem access failed". `DisableSandbox` is set in the builder's `pacman.conf` AND baked into the guest image at `$ROOTFS/etc/pacman.conf`. If `pacman -Syu` in the guest ever fails with a sandbox error, this line is missing.
- **`mksquashfs -e` consumes every argument after it.** Pseudo-dir defs (`-p "/proc d 555 0 0"`) must come BEFORE `-e`, or they silently become excludes and the guest panics at boot (`mount --move /proc failed`). The Dockerfile fails fast on this.
- **Arch has `/sbin/agetty`, not `/sbin/getty`.** The old busybox path crashes the getty in a restart loop.
- **No `set -e` in guest boot scripts.** Best-effort steps (module loads, sysctl) fail on some devices; with `set -eu` the first failure aborts the whole unit. Use `set -u` only.
- **`/etc/hosts` is a read-only bind-mount during `docker build`.** Stage it to `/etc/hosts.ardroid` in the image and install it at guest boot (`podroid-bootstrap`).
- **box64's `post_install` calls `systemctl`.** The AUR package's install hook restarts `systemd-binfmt`; during the image build a fake `systemctl` (exit 0) is on PATH. `makepkg --packagelist` (not a glob) locates the built package - the filename isn't always what you expect.
- **`CONFIG_DEVTMPFS_MOUNT=y` pre-mounts `/dev` before `/init` runs.** `init-podroid` must use `mount ... || true` for the devtmpfs line — the kernel's pre-populated `/dev` is sufficient and a second `mount(2)` returns EBUSY. Also: `size=` is not valid for devtmpfs in kernels where it is ramfs-backed (causes EINVAL). Either failure exits util-linux with `MNT_EX_FAIL=32`; `set -e` propagates `exit(32)`, encoded as `exitcode=0x00002000` ("Attempted to kill init!"). Always keep the `|| true`.
- **util-linux `mount` stops option parsing at the first non-option argument** when `POSIXLY_CORRECT` is set. Put `-o` flags *before* device and mountpoint (`mount -t proc -o noexec,nosuid,nodev proc /proc`), not after. Options placed after the mountpoint are silently dropped, causing `mount(2)` to be called with `flags=0` and returning EPERM — which util-linux prints as "must be superuser to use mount" even for root.
- **Backend asymmetry is the #1 source of bugs.** QEMU = SLIRP + QMP + virtio-console (TTY); AVF = DHCP + vsock (raw sockets). Test both. The host bridge's `cfmakeraw` on hvc2 (above) is a concrete example.
- **Boot detection** scans a rolling buffer, not per-read chunks (fast devices split markers).
- **Bridge stderr is silenced** (`dup2(/dev/null, STDERR)`): it runs as a `TerminalSession` subprocess whose stderr IS the PTY. Never add `fprintf(stderr, ...)` to `podroid-bridge.c`.
- **`forceUpdateSizeFromView` must not multiply by scaledDensity** - `TerminalView` passes the raw int textSize to `Paint`; mismatched math renders TUI apps in the wrong grid.
- **SLIRP's ICMP works here** - `ping 8.8.8.8` from the guest gets replies (libslirp proxies echo through an unprivileged ICMP socket, which Android grants app UIDs; the `ttl=255` on replies is SLIRP synthesizing them). A `ping: bad address` is therefore a DNS failure, not an ICMP one. SLIRP's DNS forwarder *is* unreliable on Android: `10.0.2.3` resolves upstream by reading the host's `/etc/resolv.conf`, which Android does not have, so the guest is given up to two distinct device IPv4 resolvers in order plus deduplicated public fallbacks (or the original `10.0.2.3`/public list when no valid device resolver is available).
- **Privileged ports**: the app can't bind host ports < 1024 (no `CAP_NET_BIND_SERVICE`), so SSH is on 9922, not 22. Forward to a high host port.
- **Reflection into the vendored Termux fork** (`mTermSession`, `mEmulator`, `mCurrentDecSetFlags`) is kept by `app/proguard-rules.pro`.
- **Persistence is sacred**: DataStore keys and `filesDir` paths survive every release; renames need migration. Updates must install in place (same `applicationId` + signing key, monotonic `versionCode`).

## VM migration / upgrades (how the guest updates without a reset)

The guest system layer updates across app versions with **no VM reset and no data loss**, on both backends. The machinery:

- **Plain overlay (never re-add metacopy/index/redirect).** `init-podroid` mounts the rootfs overlay as `lowerdir=/mnt/lower,upperdir=/mnt/persist/upper,workdir=/mnt/persist/work` only. Plain overlayfs tolerates a swapped lower, so a new squashfs (re-extracted by `PodroidApplication` on every update) goes live on the next boot while the persistent upper is preserved. **Do not re-add `metacopy=on`/`index=on`/`redirect_dir=on`** - they bind the upper to a specific lower and reintroduce the corruption-on-update bug (the whole reason resets used to be needed).
- **Version anchor.** The squashfs ships `/etc/podroid/system-version` (baked from `versionCode`). The last-applied version persists at `/mnt/persist/.podroid/applied-version`.
- **One-time legacy normalization.** `init-podroid` runs `podroid-overlay-normalize` (shipped in the squashfs, invoked via `/mnt/lower`, before the overlay is stacked) once per device (guarded by `/mnt/persist/.podroid/normalized`) to strip pre-existing `metacopy`/`redirect`/`index` state from uppers created by the old metacopy overlay. No-op on fresh/normalized uppers.
- **Imperative hooks.** `podroid-migrate.service` (systemd, runs before `podroid-bootstrap.service`) executes `/etc/podroid/migrations/<v>.sh` for `applied < v <= system-version` in order, then advances `applied-version` atomically. **To ship a fixup in a new release** (e.g. enable a newly-added service): add `build-rootfs/files/etc/podroid/migrations/<versionCode>.sh`, idempotent, install it in `build-rootfs.sh`. Pure file additions/changes need NO script - the overlay union surfaces them.
- **Reliability:** the marker advances only after migration completes (crash -> idempotent re-run); nothing auto-wipes `/mnt/persist`; `init-podroid` keeps its `FATAL -> exec sh` recovery shell.

## Common tasks

- **Kotlin/UI change** → push to `main`, run the cloud workflow (or locally `./gradlew assembleDebug && ./gradlew installDebug` if you have the assets).
- **systemd unit / package list / guest CLI change** → edit under `build-rootfs/`, push, run the cloud workflow. New/changed system files go live on the **next VM boot** with no reset (the plain-overlay union surfaces them; see "VM migration / upgrades"). The exception is a path the user already modified - it lives in the persistent upper and keeps the user's version until removed, so use a `/etc/podroid/migrations/<v>.sh` script for that case.
- **`init-podroid` change** → note it lives in the **prebuilt initramfs** - changing the repo file alone does nothing until the initramfs is rebuilt and re-embedded (currently not part of the cloud pipeline).
- **New boot stage** → emit the marker in the right systemd unit + match it in `BootStageDetector`.
- **New setting** → add a DataStore key + Flow in `SettingsRepository`, UI in `SettingsScreen`, setter in `SettingsViewModel`, and plumb into `VmConfig`/`buildCommand()` if it affects the VM.
- **New user-facing string** → add to `res/values` AND `res/values-zh`, use `stringResource`.
- **Verify before "done"**: the owner (سليمان) tests on his physical phone and expects a **verified build first** - never ask him to install an APK you haven't inspected yourself. For visual changes, build a test APK from the branch and let him verify on his phone BEFORE merging. Confirm before irreversible moves (merges, branch deletions).

## Proving a change on a device

Unit tests cover pure logic only. Anything touching VM behavior, the engine boundary, or a user-visible flow is unproven until it runs on hardware, and **the two backends need two different devices**:

| Backend | Device requirement | Extra setup |
|---|---|---|
| QEMU | any arm64 Android 8+ device | none; this is the default path |
| AVF | a device reporting `android.software.virtualization_framework` (Pixel-class) | `pm grant` both `MANAGE_VIRTUAL_MACHINE` and `USE_CUSTOM_VIRTUAL_MACHINE`, then force-stop the app |

Check AVF capability before assuming a device can exercise it:

```bash
adb shell pm list features | grep virtualization
```

A device without that feature can *never* run `AvfEngine`, no matter the `EngineSelection` setting. `EngineHolder.pick()` re-evaluates only at process start, so a fresh `pm grant` does not take effect until the app is force-stopped and relaunched.

**A change that touches both backends is unproven until it has been installed and walked on both.** Backend asymmetry is the #1 source of bugs (see Quirks & gotchas), and `AvfEngine.kt` is the most-churned file in the repository, so a QEMU-only test is the easiest way to ship a regression.

### Driving the app from adb

`engine/control/ControlProvider.kt` answers `adb shell content call`, so a device test does not have to tap through the UI. It ships in both build types, because release is where R8 bugs show up. Each call returns one line, `ok ...` or `error ...`.

```bash
C="adb shell content call --uri content://com.excp.podroid.control --method"   # debug: com.excp.podroid.debug.control
$C state                              # vm, backend, selection, boot stage, forwards, versionCode
$C set-backend --arg qemu             # auto | avf | qemu; force-stop and relaunch to re-pick
$C forward-add --arg tcp:8080:80      # goes through PortForwardRepository, so EngineHolder applies it live
$C forward-remove --arg tcp:8080:80
$C backups                            # archive names the app sees
$C navigate --arg container_backup    # home | terminal | settings | status | container_backup
adb shell am broadcast -a com.excp.podroid.action.START_VM -n com.excp.podroid/.service.VmControlReceiver   # and STOP_VM
```

The framework does **not** permission-check `ContentProvider.call()`, so the manifest `android:permission` is only defense in depth. The real gate is `isCallerAllowed()` in `call()`: uid 0, uid 2000 (shell), or a caller holding `DUMP`. Keep that check first in `call()`; without it any installed app could open a LAN-facing port forward. New methods must go through the same repositories the UI uses, never straight to an engine.

Reading the VM console depends on build type: `run-as` works on debug, but **release builds are not `run-as`-able**, so use `su` or **Settings → Diagnostics → Export Log** there.

```bash
adb shell run-as com.excp.podroid.debug cat files/console.log   # debug only
```
