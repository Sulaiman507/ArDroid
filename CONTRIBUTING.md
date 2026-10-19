# Contributing to ArDroid

Thanks for considering a contribution. Bug reports, feature requests, and pull requests are all welcome.

Before you start, please skim [`AGENTS.md`](AGENTS.md). It documents the VM-engine abstraction and both backends, the boot pipeline, every native binary, and the design quirks you need to know to make changes that don't regress.

## Getting started

```sh
git clone https://github.com/Sulaiman507/ArDroid.git
cd ArDroid
```

You will need:

- **Android SDK** with platform 36 + build-tools (for the APK)
- **Docker 20.10+** with ARM emulation (for the Arch rootfs build - normally done via CI)
- An **arm64 Android device** running **Android 8.0+ (API 26)** for testing

## Build pipeline

Builds run in the cloud via GitHub Actions (`.github/workflows/build-apk.yml`, workflow_dispatch): the workflow reuses Podroid's prebuilt kernel/initramfs/QEMU, builds only the Arch rootfs via Docker, then Gradle `assembleDebug`. See `AGENTS.md` for details.

Component versions are pinned in one place each, so read the pin rather than trusting a number written in prose:

| Component | Pinned in |
|---|---|
| Linux kernel | prebuilt `vmlinuz-virt` (reused from Podroid; repo kernel configs are inert) |
| QEMU | prebuilt `.so` (reused from Podroid) |
| Arch Linux ARM | upstream tarball URL in `build-rootfs/Dockerfile.rootfs` |

Or, for the common case where you only changed Kotlin / UI code:

```sh
./gradlew installDebug
```

## Reporting bugs

Please open an issue using the **Bug Report** template. The most useful single thing you can attach is the diagnostic log:

`Settings → Diagnostics → Export Log`

It bundles app version, device model + Android version, settings, and full logcat in one file. If the bug is VM-side, also include the VM console:

```sh
adb shell run-as com.excp.podroid.debug cat files/console.log
```

Note that `run-as` works on debug builds only. Release builds are not `run-as`-able, so use the in-app export there.

## Submitting changes

1. Fork the repository and create a topic branch (`fix/issue-42`, `feature/whatever`).
2. Keep pull requests focused: one fix or one feature per PR.
3. Work through the checklist below before opening the PR.
4. Match the existing code style of the file you are editing.

### Before you open a PR

**Run the unit tests.** Use the `:app:` form; the bare task name does not behave the same way.

```sh
./gradlew :app:testDebugUnitTest
```

**Test on a real arm64 device.** Emulators do not exercise the QEMU and native-binary path the way real hardware does. Unit tests cover pure logic only, so anything touching VM behaviour, the engine boundary, or a user-visible flow is unproven until it runs on hardware.

If your change touches the engine boundary or AVF, note that the two backends need two different devices: only a device reporting `android.software.virtualization_framework` can exercise AVF at all.

```sh
adb shell pm list features | grep virtualization
```

See [Proving a change on a device](AGENTS.md#proving-a-change-on-a-device) for the grant sequence and which backend needs which device. **Say in the PR which backends you actually tested on.** Backend asymmetry is the most common source of bugs here, so a QEMU-only test is the easiest way to ship a regression.

**Add both translations for any user-facing string.** Every string needs an entry in `app/src/main/res/values/strings.xml` and `app/src/main/res/values-zh/strings.xml`, and must be referenced with `stringResource`. Do not hardcode user-facing text.

**Never rename a DataStore key without a migration.** Saved user state has to survive every release, since updates install in place. The Kotlin identifier is free to change, but the string literal is an on-disk contract: renaming it orphans the stored value and the setting silently reverts to its default on the user's next launch. `DataStoreKeyContractTest` will fail if you change one. If the rename is deliberate, ship a migration that reads the old key and writes the new one, and update the expectation in the same commit.

**Update the docs your change affects.** If it is user-facing, update [`README.md`](README.md). If it changes the architecture, boot pipeline, terminal layer, or kernel options, update [`AGENTS.md`](AGENTS.md) too.

### Commit messages

This repository uses [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, all lowercase.

```
fix(avf): distinguish an absent GPU API from a failed declaration
docs(site): explain how to reach the desktop from another computer
test(data): pin the persisted DataStore key literals
```

The body should explain **why** the change is needed, not restate what the diff does. A reader six months from now needs the reasoning, not a summary they could get from `git show`.

Avoid `fixes #N` or `closes #N` unless you intend the issue to close when the commit lands, since those keywords close issues automatically. Use `for #N` or `addresses #N` to reference without closing.

## Code style

- Kotlin: follow the [official conventions](https://kotlinlang.org/docs/coding-conventions.html).
- Keep it simple. No premature abstractions.
- Match the surrounding file's style. Consistency beats personal preference.
- Comments explain *why*, not *what*. Self-documenting names go further than prose.
- No emoji, and no em dashes, in code, comments, commit messages, or documentation. Use hyphens, commas, colons, or restructure the sentence.

## Project layout

```
ArDroid/
├── app/                                  Android application (Jetpack Compose, Hilt)
│   └── src/main/
│       ├── java/com/excp/podroid/
│       │   ├── engine/                   VmEngine interface + both backends
│       │   │   ├── VmEngine.kt           the backend contract
│       │   │   ├── EngineHolder.kt       Hilt binding; picks and routes to a backend
│       │   │   ├── QemuEngine.kt         QEMU/TCG backend, buildCommand()
│       │   │   ├── QmpClient.kt          QMP: port forwards + USB
│       │   │   ├── avf/                  AVF/pKVM backend (reflection, vsock, 9p)
│       │   │   ├── hostbridge/           guest to Android bridge
│       │   │   └── usb/                  USB passthrough (QEMU only)
│       │   ├── service/                  Foreground service owning the VM lifecycle
│       │   ├── data/repository/          DataStore-backed settings, port forwards,
│       │   │                             updates, language, backups, container stats
│       │   ├── util/                     Network, shell quoting, host metrics
│       │   ├── x11/                      X11/VNC viewer engine
│       │   └── ui/                       Compose screens + theme
│       ├── res/values, res/values-zh/    strings (English + Chinese, keep in sync)
│       ├── jniLibs/arm64-v8a/            QEMU, podroid-bridge, podroid-launcher, libslirp
│       └── assets/                       kernel, initramfs, squashfs, fonts, themes
├── terminal-view/, terminal-emulator/    vendored Termux fork (local Gradle modules)
├── init-podroid                          initramfs bootstrap (prebuilt; repo copy is reference only)
├── podroid-bridge.c                      Native PTY <-> virtio-console relay
├── podroid-launcher.c                    exec wrapper tying QEMU's lifetime to the app
├── build-rootfs/                         Arch Linux ARM squashfs build pipeline
│   ├── Dockerfile.rootfs
│   ├── build-rootfs.sh                   (includes box64 AUR build)
│   ├── vsock-agent/                      AVF control/forward agent
│   ├── host-bridge/                      guest to Android bridge daemon
│   └── files/                            systemd units + helpers baked into the squashfs
│       ├── etc/systemd/system/           12 podroid-*.service units
│       └── usr/local/bin/                podroid-getty, podroid-login, ...
├── .github/workflows/build-apk.yml      Cloud build: rootfs via Docker + assembleDebug
└── docs/                                 GitHub Pages site (upstream Podroid docs)
```

## License

By contributing, you agree that your work will be licensed under the **GNU General Public License v2.0**, the same license as the project.
