# SM-A146P KernelSU-Next + SUSFS (One UI 7 / Android 15 — Binary L)

Automated GitHub Actions kernel builder for **Samsung Galaxy A14 5G (`SM-A146P`)** powered by MediaTek Dimensity 700 (`mt6833` / `a14xm`), targeting **One UI 7 / Android 15 Binary L (`A146PXXULEZJ3`)** with kernel **6.6.127-android15-8**.

## Specifications

| Item | Detail |
|------|--------|
| **Device** | Samsung Galaxy A14 5G (`SM-A146P`, MediaTek Dimensity 700 / `mt6833`) |
| **Firmware** | One UI 7 / Android 15 — Binary L (`A146PXXULEZJ3`) |
| **Kernel Base** | `6.6.127-android15-8-abA146PXXULEZJ3-4k` (clean stock-like `uname`, no `-dirty`, no `-Wild`) |
| **LTO** | Default (`CONFIG_LTO_NONE=y`) |
| **Toolchain** | `clang-18` (`r510928`) & Kleaf Bazel from `WildKernels/Samsung_Kernels` (`SM-A146P-Oneui7-Mediatek`) |
| **Build Mode** | `QUICK_BUILD=1` (`//kernel_device_modules-6.6:mgk_64_k66_kernel_aarch64.user`) |

## Included Features (Full WildKernels)

- **KernelSU-Next v3.4.2** — `pershoot/KernelSU-Next` (`dev-susfs` branch) with version info injected into Kbuild
- **SUSFS v2.4.0** — `simonpunk/susfs4ksu` (`gki-android15-6.6`) + top 2 commits cherry-picked from `pershoot/susfs4ksu` (`gki-android14-6.1-dev`), 0 rejects
- **Baseband-guard (BBG)** — `vc-teahouse/Baseband-guard` integrated into `CONFIG_LSM`
- **NoMount** — `maxsteeel/nomount` (`dev` branch)
- **Networking** — TCP BBRv3 + CAKE & PIE qdisc, IP-Set, IPv6 NAT + MASQUERADE (`gki_defconfig` & `mediatek-bazel_defconfig`), TTL/HL netfilter targets
- **Compatibility** — NTSync, Droidspaces (`SYSVIPC` KABI fix + namespace/netfilter configs), Mountify (`OVERLAY_FS`, `TMPFS_XATTR`, `TMPFS_POSIX_ACL`), Unicode bypass fix
- **Optimizations** — All 23 WildKernels kernel optimization patches + alarmtimer wakeup tuning
- **Samsung Security** — `CONFIG_SECURITY_DEFEX` & `CONFIG_SECURITY_DEFEX_USER` disabled in `mediatek-bazel_defconfig` (stock `A146PXXULEZJ3` does not use `CONFIG_KDP`)

## Output Files (Artifacts & Releases)

1. **`boot_and_vbmeta.tar`** — Odin **AP** package for **first-time flash** (repacked `boot.img` + stock `vbmeta.img` patched with AVB `flags=3` at offset 120).
2. **`boot.tar`** — Odin **AP** package for **subsequent kernel updates** (repacked `boot.img` only).
3. **`vbmeta_disabled.tar`** — Odin **AP** package containing stock `vbmeta.img` with AVB verification/hashtree disabled (`flags=3` at offset 120).
4. **`AnyKernel3.zip`** — Backup flasher built from `WildKernels/AnyKernel3` (`gki-2.0` branch) for custom recovery.

## Flashing Guide (Odin)

> **Warning:** Ensure your bootloader is unlocked and you have backed up important data. Flashing `vbmeta_disabled` for the first time on Samsung devices requires a factory reset / data wipe if AVB verification was previously active.

### First-Time Flash
1. Boot into Download Mode.
2. Open **Odin** and load **`boot_and_vbmeta.tar`** into the **AP** slot.
3. Click **Start** to flash.
4. If prompted by stock recovery after rebooting due to vbmeta change, perform **Factory data reset**.
5. Install the **KernelSU-Next** manager app after booting into Android.

### Subsequent Kernel Updates
1. Boot into Download Mode.
2. Open **Odin** and load **`boot.tar`** into the **AP** slot.
3. Click **Start** (no data wipe needed).

## Repository Structure

- [`.github/workflows/build.yml`](.github/workflows/build.yml) — End-to-end CI workflow (toolchain setup, Binary L overlay, patching, Kleaf build, IKCONFIG/uname verification, Odin/AK3 packaging, Artifact upload, GitHub Release)
- [`scripts/patch_kernel.sh`](scripts/patch_kernel.sh) — Applies all WildKernels patches, KSU-Next, SUSFS v2.4.0, BBG, NoMount, defconfig changes, and verifies 0 rejects
- [`scripts/repack_odin.sh`](scripts/repack_odin.sh) — Repacks stock `boot.img` via `magiskboot`, patches stock `vbmeta.img` (`flags=3` at offset 120), builds Odin `ustar` `.tar` archives, and creates `AnyKernel3.zip`

## Credits

- [WildKernels](https://github.com/WildKernels) (`Samsung_Kernels`, `Samsung_KernelSU_SUSFS`, `kernel_patches`, `AnyKernel3`, `magiskboot`)
- [pershoot](https://github.com/pershoot) (`KernelSU-Next` `dev-susfs`, `susfs4ksu` fixes)
- [simonpunk](https://gitlab.com/simonpunk/susfs4ksu) (`susfs4ksu`)
- [vc-teahouse](https://github.com/vc-teahouse/Baseband-guard) (`Baseband-guard`)
- [maxsteeel](https://github.com/maxsteeel/nomount) (`NoMount`)
- Samsung Open Source (`SM-A146U1` / `SM-A146P` Binary L `A146PXXULEZJ3`)
