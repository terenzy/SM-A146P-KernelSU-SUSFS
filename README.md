# SM-A146P KernelSU-Next + SUSFS — Full-Stack Zero-Leak Stealth (One UI 7 / Android 15 — Binary L)

Automated GitHub Actions kernel & companion module builder for **Samsung Galaxy A14 5G (`SM-A146P`)** powered by MediaTek Dimensity 700 (`mt6833` / `a14xm`), targeting **One UI 7 / Android 15 Binary L (`A146PXXULEZJ3`)** with kernel **6.6.127-android15-8**.

## Specifications

| Item | Detail |
|------|--------|
| **Device** | Samsung Galaxy A14 5G (`SM-A146P`, MediaTek Dimensity 700 / `mt6833`) |
| **Firmware** | One UI 7 / Android 15 — Binary L (`A146PXXULEZJ3`) |
| **Kernel Base** | `6.6.127-android15-8-abA146PXXULEZJ3-4k` (exact stock Samsung `user@host` & `uname -v` timestamp, no `-dirty`, no `-Wild`) |
| **LTO** | Default (`CONFIG_LTO_NONE=y`) |
| **Toolchain** | `clang-18` (`r510928`) & Kleaf Bazel from `WildKernels/Samsung_Kernels` (`SM-A146P-Oneui7-Mediatek`) |
| **Build Mode** | `QUICK_BUILD=1` (`//kernel_device_modules-6.6:mgk_64_k66_kernel_aarch64.user`) |

## Zero-Leak Kernel Stealth Layers (7 Layers)

All kernel stealth patches are designed for **zero kernel panic risk** (lock-balanced, RCU-safe, zero heap allocation in procfs paths, and strictly CI-verified against real `.config`, `System.map`, scrubbed IKCONFIG, and binary string hygiene):

1. **Surgical `PRIORITY_UID_FILTER` (`fs/susfs.c`)** — Automatically hides KernelSU Manager & KSU root-allowlisted app UIDs (100% lockless/RCU-safe) with a self-UID guard across `getpriority`, `setpriority`, `ioprio_get`, and `ioprio_set`, combined with SUSFS v2.4.0's dynamic bitmap synced from HMA-OSS (keeping normal visible apps natural).
2. **NoMount Cloaking (`security/keys/key.c`, `NoMount`, `kernel/kallsyms.c`)** — Closes the `add_key("nomount")` / `request_key` oracle by returning `-ENOKEY`/`-ENODEV` for non-`CAP_SYS_ADMIN` callers (indistinguishable from a nonexistent key type), silences all `NoMount:` `dmesg` logs & modinfo, and hides `nomount_*` / `nm_*` symbols in `/proc/kallsyms`.
3. **Baseband-guard Cloaking (`Baseband-guard`, `security/security.c`, `kernel/kallsyms.c`)** — Keeps block-partition write protection 100% enforcing while stripping Telegram/Chinese banner & modinfo strings, hiding `baseband_guard` from `/sys/kernel/security/lsm` and boot logs, and hiding `bbg_*`/`baseband_guard*` symbols in `/proc/kallsyms`.
4. **Scrubbed `/proc/config.gz` (`kernel/Makefile`)** — Strips all `CONFIG_KSU*`, `CONFIG_SUSFS*`, `CONFIG_NOMOUNT*`, `CONFIG_BBG*`, `CONFIG_KPM*`, and `baseband_guard` entries from `config_data`, displaying stock-like `CONFIG_SECURITY_DEFEX=y` and `CONFIG_IP6_NF_NAT=n`.
5. **Non-Root `/proc/cmdline` & `/proc/bootconfig` Sanitization (`fs/proc/stealth_boot.h`)** — Zero-allocation streaming sanitization (`verifiedbootstate=green`, `flash.locked=1`, `vbmeta.device_state=locked`, `warranty_bit=0`, `veritymode=enforcing`) strictly for ordinary app UIDs (`>= 10000`), leaving `init`/`system_server`/`root` untouched and preserving SUSFS bootconfig overrides.
6. **Exact Stock Samsung Build Identity (`scripts/mkcompile_h`, `init/Makefile`)** — Automatically extracts `user@host` and `UTS_VERSION` timestamp from stock `boot.img.lz4` so `uname -a`, `uname -v`, and `/proc/version` match stock `A146PXXULEZJ3`.
7. **Hardening & 2026 Security CVEs** — Disables `CONFIG_KSU_SUSFS_ENABLE_LOG` & dead `CONFIG_KPM`, enforces `CONFIG_SECURITY_DMESG_RESTRICT=y`, includes Unicode bypass fix (`CVE-2024-43093`), and verifies/applies `CVE-2026-43499`, `CVE-2026-64560`, and `CVE-2026-98260` fixes.

## Included WildKernels Features

- **KernelSU-Next v3.4.2** — `pershoot/KernelSU-Next` (`dev-susfs` branch) with real version injected into Kbuild
- **SUSFS v2.4.0** — `simonpunk/susfs4ksu` (`gki-android15-6.6`) + pershoot cherry-picks, 0 rejects
- **Baseband-guard (BBG)** — `vc-teahouse/Baseband-guard` integrated into `CONFIG_LSM` (cloaked)
- **NoMount** — `maxsteeel/nomount` (`dev` branch, v2.3.1 / protocol 23, cloaked)
- **Networking** — TCP BBRv3 + CAKE & PIE qdisc, IP-Set, IPv6 NAT + MASQUERADE, TTL/HL netfilter targets
- **Compatibility & Optimizations** — NTSync, Droidspaces (`SYSVIPC` KABI fix), Mountify (`OVERLAY_FS`, `TMPFS_XATTR`, `TMPFS_POSIX_ACL`), all 23 WildKernels optimization patches, Samsung DEFEX disabled

## Output Files (Artifacts & Releases)

1. **`boot_and_vbmeta.tar`** — Odin **AP** package for **first-time flash** (repacked `boot.img` + stock `vbmeta.img` patched with AVB `flags=3` at offset 120).
2. **`boot.tar`** — Odin **AP** package for **subsequent kernel updates** (repacked `boot.img` only, no data wipe).
3. **`vbmeta_disabled.tar`** — Odin **AP** package containing stock `vbmeta.img` with AVB disabled (`flags=3` at offset 120).
4. **`AnyKernel3.zip`** — Backup flasher built from `WildKernels/AnyKernel3` (`gki-2.0` branch) for custom recovery.
5. **`a146p_stealth_companion.zip`** — **KernelSU Module** bundling `ksu_susfs` (v2.4.0+ universal binary):
   - Auto-activates SUSFS v2.4.0 runtime protections (`hide_sus_mnts_for_non_su_procs`, `enable_avc_log_spoofing`, residual `sus_path`).
   - Real-time `inotifyd` auto-sync of **HMA-OSS** hidden packages → SUSFS `set_priority_uid_filter`.
   - Real-time sync of **HMA-OSS** protected target scopes (detectors, banking apps, anti-cheats) → **NoMount** UID exclusions + `block_isolated on`.
   - **`Action` (`AKSI`) button** in KernelSU-Next for instant re-sync & live kernel/userspace stealth self-audit.

## Flashing & Setup Guide

### Subsequent Kernel Update (Already on Unlocked Bootloader + `vbmeta_disabled`)
1. Boot into Download Mode and flash **`boot.tar`** in Odin **AP** slot (no data wipe needed).
2. Open **KernelSU-Next → Modules → `+`** and install **`a146p_stealth_companion.zip`**, then reboot.
3. Optional: Tap **Action (`AKSI`)** on **SM-A146P Stealth Companion** in KernelSU-Next to run a live stealth self-audit anytime.
4. Recommended hygiene for banking/anti-cheat apps: uninstall or disable any user-CA system injection module (e.g., *Always Trust User Certificates*) if you don't actively need MitM proxy debugging.

### First-Time Flash
1. Boot into Download Mode, flash **`boot_and_vbmeta.tar`** in Odin **AP** slot.
2. Perform Factory Data Reset if prompted due to first-time `vbmeta` change.
3. Install **KernelSU-Next**, **NoMount**, and **`a146p_stealth_companion.zip`**.

## Repository Structure

- [`.github/workflows/build.yml`](.github/workflows/build.yml) — End-to-end CI workflow (toolchain, Binary L overlay, stock banner extraction, patching, Zero-Leak Stealth, Kleaf build, dual real-`.config` + scrubbed-IKCONFIG + `System.map` + binary hygiene verification, Odin/AK3/Companion packaging, GitHub Release)
- [`scripts/patch_kernel.sh`](scripts/patch_kernel.sh) — Applies WildKernels patches, KSU-Next, SUSFS v2.4.0, BBG, NoMount, defconfig changes, and invokes `apply_stealth.sh`
- [`scripts/apply_stealth.sh`](scripts/apply_stealth.sh) — Applies all 7 Zero-Leak Kernel Stealth Layers & 2026 CVE security fixes
- [`scripts/repack_odin.sh`](scripts/repack_odin.sh) — Repacks `boot.img`, patches `vbmeta.img`, builds Odin `.tar` archives, `AnyKernel3.zip`, and `a146p_stealth_companion.zip`
- [`companion/`](companion/) — Source for `a146p_stealth_companion.zip` KernelSU module (`stealth_sync.sh`, `service.sh`, `action.sh`)
- [`patches/`](patches/) — Pinned 2026 kernel security CVE patches (`CVE-2026-43499`, `CVE-2026-64560`, `CVE-2026-98260`)

## Credits

- [WildKernels](https://github.com/WildKernels) (`Samsung_Kernels`, `kernel_patches`, `AnyKernel3`, `magiskboot`)
- [pershoot](https://github.com/pershoot) (`KernelSU-Next` `dev-susfs`, `susfs4ksu` fixes)
- [simonpunk](https://gitlab.com/simonpunk/susfs4ksu) (`susfs4ksu`)
- [sidex15](https://github.com/sidex15/susfs4ksu-binaries) (`ksu_susfs` universal binary)
- [vc-teahouse](https://github.com/vc-teahouse/Baseband-guard) (`Baseband-guard`)
- [maxsteeel](https://github.com/maxsteeel/nomount) (`NoMount`)
- [midori01](https://github.com/midori01/gki_ksu_workflow) (2026 CVE backport patches)
- Samsung Open Source (`SM-A146U1` / `SM-A146P` Binary L `A146PXXULEZJ3`)
