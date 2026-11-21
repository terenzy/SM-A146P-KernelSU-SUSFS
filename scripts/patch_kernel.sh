#!/usr/bin/env bash
# ==============================================================================
# Patch script for Samsung Galaxy A14 5G (SM-A146P / mt6833 / a14xm)
# Firmware: One UI 7 / Android 15 / Binary L (A146PXXULEZJ3) / Kernel 6.6.127
# Feature set: Full WildKernels (KSUN v3.4.2 + SUSFS v2.4.0 + BBG + NoMount +
#              BBRv3/CAKE/PIE + NTSync + Droidspaces + IP-Set/IPv6 NAT/TTL +
#              Unicode fix + all 23 WildKernels optimization patches)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KERNEL_ROOT="${KERNEL_ROOT:?KERNEL_ROOT must be set (path to combined toolchain + Binary L tree)}"
KERNEL_PATCHES="${KERNEL_PATCHES:?KERNEL_PATCHES must be set (path to WildKernels/kernel_patches)}"
SUSFS_DIR="${SUSFS_DIR:-$(dirname "$KERNEL_ROOT")/susfs4ksu}"
META_ENV_FILE="${META_ENV_FILE:-}"

COMMON="$KERNEL_ROOT/kernel-6.6"
GKI_DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
MTK_DEFCONFIG="$KERNEL_ROOT/kernel/kernel_device_modules-6.6/arch/arm64/configs/mediatek-bazel_defconfig"
CONFIG_TOOL="$COMMON/scripts/config"

retry() {
  local n=0
  until [ "$n" -ge 5 ]; do
    "$@" && return 0
    n=$((n + 1))
    echo "[retry $n/5] Retrying: $*" >&2
    sleep 5
  done
  return 1
}

record_meta() {
  local key="$1"
  local val="$2"
  if [ -n "$META_ENV_FILE" ]; then
    echo "${key}=${val}" >> "$META_ENV_FILE"
  fi
}

apply_patch() {
  local patch_file="$1"
  local label="${2:-$(basename "$patch_file")}"
  echo "[PATCH] Applying ${label}..."
  if ! patch -p1 --no-backup-if-mismatch < "$patch_file"; then
    echo "::error::Patch failed: ${label}"
    find "$COMMON" -type f -name '*.rej' -print -exec cat {} +
    exit 1
  fi
}

echo "============================================================"
echo " Preparing Samsung Binary L 6.6.127 kernel source"
echo " COMMON       = $COMMON"
echo " GKI_DEFCONFIG= $GKI_DEFCONFIG"
echo " MTK_DEFCONFIG= $MTK_DEFCONFIG"
echo "============================================================"

test -d "$COMMON" || { echo "ERROR: Missing $COMMON"; exit 1; }
test -f "$GKI_DEFCONFIG" || { echo "ERROR: Missing $GKI_DEFCONFIG"; exit 1; }
test -f "$MTK_DEFCONFIG" || { echo "ERROR: Missing $MTK_DEFCONFIG"; exit 1; }
test -x "$CONFIG_TOOL" || chmod +x "$CONFIG_TOOL"

# Ensure source tree is writable (Samsung Opensource archives can have 0444 files)
chmod -R u+w "$COMMON" "$KERNEL_ROOT/kernel/kernel_device_modules-6.6"

cd "$COMMON"

# ------------------------------------------------------------------------------
# 1. Pre-SUSFS Samsung source preparation (guarantees 0 rejects on SUSFS v2.4.0)
# ------------------------------------------------------------------------------
echo ">>> [1/13] Preparing Samsung source for clean SUSFS patching..."

# Relocate #ifdef CONFIG_PROC_STLOG / #include <linux/fslog.h> / #endif
# immediately after #include <linux/security.h> in fs/namespace.c
python3 - <<'PY'
from pathlib import Path

ns_path = Path("fs/namespace.c")
text = ns_path.read_text()
block = "#ifdef CONFIG_PROC_STLOG\n#include <linux/fslog.h>\n#endif\n"
anchor = "#include <linux/security.h>\n"

assert anchor in text, "Anchor '#include <linux/security.h>' not found in fs/namespace.c"

if anchor + block in text:
    print("fs/namespace.c already has CONFIG_PROC_STLOG block after linux/security.h")
elif block in text:
    # Remove old location along with its trailing blank line so exactly one
    # blank line remains between <trace/hooks/fs.h> and sysctl_mount_max.
    if block + "\n" in text:
        text = text.replace(block + "\n", "", 1)
    elif "\n" + block in text:
        text = text.replace("\n" + block, "", 1)
    else:
        text = text.replace(block, "", 1)
    text = text.replace(anchor, anchor + block, 1)
    ns_path.write_text(text)
    print("Relocated CONFIG_PROC_STLOG / linux/fslog.h after linux/security.h in fs/namespace.c")
else:
    print("WARNING: CONFIG_PROC_STLOG block not found in fs/namespace.c; continuing")
PY

# Remove Samsung DEFEX inline blocks in fs/open.c so SUSFS hooks apply cleanly
sed -i '/#ifdef CONFIG_SECURITY_DEFEX/,/^#endif/d' fs/open.c

# Strip CONFIG_KDP_NS guard in fs/namespace.c if present (no-op on Binary L)
sed -i '/copy_flags = CL_COPY_UNBINDABLE | CL_EXPIRE;/,/#endif/ {
  /#ifdef CONFIG_KDP_NS/,/#endif/ {
    /#else/,/#endif/!d
    /#else/d
    /#endif/d
  }
}' fs/namespace.c

# Ensure linux/dma-buf.h is present in fs/proc/base.c (already in 6.6.127, guard anyway)
if ! grep -q '#include <linux/dma-buf.h>' fs/proc/base.c; then
  sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux/dma-buf.h>' fs/proc/base.c
  echo "Added #include <linux/dma-buf.h> to fs/proc/base.c"
fi

# ------------------------------------------------------------------------------
# 2. KernelSU-Next v3.4.2 (pershoot/KernelSU-Next branch dev-susfs)
# ------------------------------------------------------------------------------
echo ">>> [2/13] Integrating KernelSU-Next (pershoot/KernelSU-Next @ dev-susfs)..."
retry bash -c 'curl -fsSL --retry 5 "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s dev-susfs'

"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_KSU
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable CONFIG_KSU_SAMSUNG_KDP
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable CONFIG_KSU_SAMSUNG_RKP
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable CONFIG_KSU_SAMSUNG_DEFEX
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable CONFIG_KSU_SAMSUNG_NO_PATCH_TEXT

# Inject real version info into Kbuild because Bazel sandbox strips .git
(
  cd "$COMMON/KernelSU-Next"
  git fetch origin dev 2>/dev/null || true
  KSU_GIT_VERSION=$(git rev-list --count refs/remotes/origin/dev 2>/dev/null || git rev-list --count HEAD)
  KSU_GIT_TAG=$(git describe --tags --abbrev=0 refs/remotes/origin/dev 2>/dev/null || git describe --tags --abbrev=0 2>/dev/null || echo "v3.4.2")
  KSU_COMMIT=$(git rev-parse --short HEAD)
  KSU_FULL_COMMIT=$(git rev-parse HEAD)
  KSU_VERSION=$((30000 + KSU_GIT_VERSION))

  sed -i "s/^KSU_VERSION_FALLBACK := 1$/KSU_VERSION_FALLBACK := ${KSU_VERSION}/" kernel/Kbuild
  sed -i "s/^KSU_VERSION_TAG_FALLBACK := v0.0.1$/KSU_VERSION_TAG_FALLBACK := ${KSU_GIT_TAG}/" kernel/Kbuild

  echo "KernelSU-Next: tag=${KSU_GIT_TAG}, version=${KSU_VERSION}, commit=${KSU_COMMIT}"
  record_meta "KSU_GIT_TAG" "$KSU_GIT_TAG"
  record_meta "KSU_VERSION" "$KSU_VERSION"
  record_meta "KSU_COMMIT" "$KSU_FULL_COMMIT"
)

# ------------------------------------------------------------------------------
# 3. SUSFS v2.4.0 (simonpunk/susfs4ksu gki-android15-6.6 + 2 commits pershoot)
# ------------------------------------------------------------------------------
echo ">>> [3/13] Integrating SUSFS v2.4.0..."
rm -rf "$SUSFS_DIR"
retry git clone --depth 1 -b gki-android15-6.6 --single-branch \
  https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS_DIR"

(
  cd "$SUSFS_DIR"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  SUSFS_BASE_COMMIT=$(git rev-parse HEAD)
  record_meta "SUSFS_BASE_COMMIT" "$SUSFS_BASE_COMMIT"

  retry git fetch https://gitlab.com/pershoot/susfs4ksu.git gki-android14-6.1-dev
  echo "Top 2 commits from pershoot/susfs4ksu (gki-android14-6.1-dev) to cherry-pick:"
  git log ..FETCH_HEAD --oneline -n 2
  mapfile -t PERSHOOT_COMMITS < <(git log ..FETCH_HEAD --format=%H -n 2 | tac)
  for c in "${PERSHOOT_COMMITS[@]}"; do
    echo "Cherry-picking pershoot commit: $c"
    git cherry-pick "$c"
  done
  record_meta "SUSFS_PERSHOOT_COMMITS" "${PERSHOOT_COMMITS[*]}"
)

cp -f "$SUSFS_DIR/kernel_patches/fs/"* "$COMMON/fs/"
cp -f "$SUSFS_DIR/kernel_patches/include/linux/"* "$COMMON/include/linux/"
apply_patch "$SUSFS_DIR/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch" "50_add_susfs_in_gki-android15-6.6.patch"

# Guard macros if an older sublevel lacks page-size-migration headers (no-op on 6.6.127)
if grep -q 'VMA_PAD_START(' fs/proc/task_mmu.c && ! grep -qE '#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START' fs/proc/task_mmu.c; then
  sed -i '1a #ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif' fs/proc/task_mmu.c
fi
if grep -q '__fold_filemap_fixup_entry' fs/proc/task_mmu.c && ! grep -q '#include <linux/page_size_compat.h>' fs/proc/task_mmu.c; then
  sed -i '/#include <linux\/pkeys.h>/a #include <linux/page_size_compat.h>' fs/proc/task_mmu.c
fi

"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_KSU_SUSFS

# ------------------------------------------------------------------------------
# 4. NoMount (maxsteeel/nomount @ dev)
# ------------------------------------------------------------------------------
echo ">>> [4/13] Integrating NoMount..."
retry bash -c 'curl -fsSL --retry 5 "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s dev'
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_NOMOUNT
record_meta "NOMOUNT_COMMIT" "$(git -C "$COMMON/NoMount" rev-parse HEAD)"

# ------------------------------------------------------------------------------
# 5. Baseband-guard (BBG)
# ------------------------------------------------------------------------------
echo ">>> [5/13] Integrating Baseband-guard (BBG)..."
retry bash -c 'curl -fsSL --retry 5 "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash'
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_BBG

# Append baseband_guard to LSM default order in security/Kconfig
sed -i '/^config LSM$/,/[[:space:]]*help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
if grep -q '^CONFIG_LSM=' "$GKI_DEFCONFIG"; then
  sed -i '/^CONFIG_LSM=/ { /baseband_guard/! s/"$/,baseband_guard"/ }' "$GKI_DEFCONFIG"
fi
record_meta "BBG_COMMIT" "$(git -C "$COMMON/Baseband-guard" rev-parse HEAD)"

# ------------------------------------------------------------------------------
# 6. Unicode Bypass Fix
# ------------------------------------------------------------------------------
echo ">>> [6/13] Applying Unicode Bypass Fix (6.1+)..."
apply_patch "$KERNEL_PATCHES/common/unicode_bypass_fix_6.1+.patch"

# ------------------------------------------------------------------------------
# 7. Droidspaces Support
# ------------------------------------------------------------------------------
echo ">>> [7/13] Applying Droidspaces patch & configs..."
apply_patch "$KERNEL_PATCHES/common/droidspaces/fix_sysvipc_kabi_6_7_8.patch"

for cfg in \
  CONFIG_SYSVIPC \
  CONFIG_POSIX_MQUEUE \
  CONFIG_IPC_NS \
  CONFIG_PID_NS \
  CONFIG_USER_NS \
  CONFIG_DEVTMPFS \
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
  CONFIG_NETFILTER_XT_TARGET_REJECT \
  CONFIG_NETFILTER_XT_TARGET_LOG \
  CONFIG_NETFILTER_XT_MATCH_RECENT \
  CONFIG_IP_SET \
  CONFIG_IP_SET_HASH_IP \
  CONFIG_IP_SET_HASH_NET \
  CONFIG_NETFILTER_XT_SET; do
  "$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable "$cfg"
done

# ------------------------------------------------------------------------------
# 8. NTSync Support
# ------------------------------------------------------------------------------
echo ">>> [8/13] Applying NTSync patches & config..."
apply_patch "$KERNEL_PATCHES/common/ntsync/ntsync_base.patch"
apply_patch "$KERNEL_PATCHES/common/ntsync/ntsync_compat_android15-6.6.patch"
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_NTSYNC

# ------------------------------------------------------------------------------
# 9. TCP BBRv3 + CAKE / PIE Qdisc
# ------------------------------------------------------------------------------
echo ">>> [9/13] Applying BBRv3 patch & network scheduler configs..."
apply_patch "$KERNEL_PATCHES/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch"

for cfg in \
  CONFIG_NET_SCH_FQ \
  CONFIG_NET_SCH_FQ_CODEL \
  CONFIG_NET_SCH_CAKE \
  CONFIG_NET_SCH_PIE \
  CONFIG_NET_SCH_FQ_PIE \
  CONFIG_TCP_CONG_ADVANCED \
  CONFIG_TCP_CONG_BBR \
  CONFIG_TCP_CONG_BBR3 \
  CONFIG_TCP_CONG_CUBIC; do
  "$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable "$cfg"
done

for cfg in \
  CONFIG_TCP_CONG_BIC \
  CONFIG_TCP_CONG_WESTWOOD \
  CONFIG_TCP_CONG_HTCP; do
  "$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable "$cfg"
done

# ------------------------------------------------------------------------------
# 10. IP-Set + IPv6 NAT + TTL Support
# ------------------------------------------------------------------------------
echo ">>> [10/13] Applying IP-Set, IPv6 NAT, and TTL support..."
apply_patch "$KERNEL_PATCHES/common/IPv6_NAT_FIX.patch"

"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --set-val CONFIG_IP_SET_MAX 65534
for cfg in \
  CONFIG_IP_SET \
  CONFIG_IP_SET_BITMAP_IP \
  CONFIG_IP_SET_BITMAP_IPMAC \
  CONFIG_IP_SET_BITMAP_PORT \
  CONFIG_IP_SET_HASH_IP \
  CONFIG_IP_SET_HASH_IPMARK \
  CONFIG_IP_SET_HASH_IPPORT \
  CONFIG_IP_SET_HASH_IPPORTIP \
  CONFIG_IP_SET_HASH_IPPORTNET \
  CONFIG_IP_SET_HASH_IPMAC \
  CONFIG_IP_SET_HASH_MAC \
  CONFIG_IP_SET_HASH_NETPORTNET \
  CONFIG_IP_SET_HASH_NET \
  CONFIG_IP_SET_HASH_NETNET \
  CONFIG_IP_SET_HASH_NETPORT \
  CONFIG_IP_SET_HASH_NETIFACE \
  CONFIG_IP_SET_LIST_SET \
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
  CONFIG_NETFILTER_XT_SET \
  CONFIG_IP6_NF_NAT \
  CONFIG_IP6_NF_TARGET_MASQUERADE \
  CONFIG_IP_NF_TARGET_TTL \
  CONFIG_IP6_NF_TARGET_HL \
  CONFIG_IP6_NF_MATCH_HL; do
  "$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable "$cfg"
done

# mediatek-bazel_defconfig is merged AFTER gki_defconfig and explicitly disables IP6_NF_NAT
"$CONFIG_TOOL" --file "$MTK_DEFCONFIG" --enable CONFIG_IP6_NF_NAT
"$CONFIG_TOOL" --file "$MTK_DEFCONFIG" --enable CONFIG_IP6_NF_TARGET_MASQUERADE

# ------------------------------------------------------------------------------
# 11. All 23 WildKernels Optimization Patches + alarmtimer wakeup tuning
# ------------------------------------------------------------------------------
echo ">>> [11/13] Applying all 23 WildKernels optimization patches..."
apply_patch "$KERNEL_PATCHES/common/optimized_mem_operations.patch"
apply_patch "$KERNEL_PATCHES/common/file_struct_8bytes_align.patch"
apply_patch "$KERNEL_PATCHES/common/reduce_cache_pressure.patch"
apply_patch "$KERNEL_PATCHES/common/mem_opt_prefetch.patch"
apply_patch "$KERNEL_PATCHES/common/optimise_memcmp.patch"

# Minimise alarmtimer wakeup time
sed -i 's/pm_wakeup_event(dev, 2 \* MSEC_PER_SEC);/pm_wakeup_event(dev, ktime_to_ms(min) + 1);/' kernel/time/alarmtimer.c

apply_patch "$KERNEL_PATCHES/common/int_sqrt.patch"
apply_patch "$KERNEL_PATCHES/common/reduce_gc_thread_sleep_time.patch"
apply_patch "$KERNEL_PATCHES/common/add_timeout_wakelocks_globally.patch"
apply_patch "$KERNEL_PATCHES/common/f2fs_reduce_congestion.patch"
apply_patch "$KERNEL_PATCHES/common/reduce_freeze_timeout.patch"

echo "[PATCH] Applying clear_page_16bytes_align.patch (6.6 symbol adjustment)..."
if ! sed -e 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START(__pi_clear_page)/' \
  "$KERNEL_PATCHES/common/clear_page_16bytes_align.patch" | patch -p1 --no-backup-if-mismatch; then
  echo "::error::Patch failed: clear_page_16bytes_align.patch"
  find "$COMMON" -type f -name '*.rej' -print -exec cat {} +
  exit 1
fi

apply_patch "$KERNEL_PATCHES/common/add_limitation_scaling_min_freq.patch"
apply_patch "$KERNEL_PATCHES/common/re_write_limitation_scaling_min_freq.patch"
apply_patch "$KERNEL_PATCHES/common/adjust_cpu_scan_order.patch"
apply_patch "$KERNEL_PATCHES/common/avoid_extra_s2idle_wake_attempts.patch"
apply_patch "$KERNEL_PATCHES/common/disable_cache_hot_buddy.patch"
apply_patch "$KERNEL_PATCHES/common/f2fs_enlarge_min_fsync_blocks.patch"
apply_patch "$KERNEL_PATCHES/common/increase_ext4_default_commit_age.patch"
apply_patch "$KERNEL_PATCHES/common/increase_sk_mem_packets.patch"
apply_patch "$KERNEL_PATCHES/common/reduce_pci_pme_wakeups.patch"
apply_patch "$KERNEL_PATCHES/common/silence_irq_cpu_logspam.patch"
apply_patch "$KERNEL_PATCHES/common/silence_system_logspam.patch"
apply_patch "$KERNEL_PATCHES/common/use_unlikely_wrap_cpufreq.patch"

# ------------------------------------------------------------------------------
# 12. Mountify, Kallsyms, Samsung DEFEX Disable, ABI exports, check_defconfig
# ------------------------------------------------------------------------------
echo ">>> [12/14] Configuring Mountify, Kallsyms, Samsung DEFEX disable, ABI exports..."
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_OVERLAY_FS
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_TMPFS_XATTR
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_TMPFS_POSIX_ACL
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_KALLSYMS
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_KALLSYMS_ALL

# Disable Samsung DEFEX in mediatek-bazel_defconfig (stock Binary L does not use KDP)
"$CONFIG_TOOL" --file "$MTK_DEFCONFIG" --disable CONFIG_SECURITY_DEFEX
"$CONFIG_TOOL" --file "$MTK_DEFCONFIG" --disable CONFIG_SECURITY_DEFEX_USER

# Remove check_defconfig from build.config.gki
sed -i 's/check_defconfig//' "$COMMON/build.config.gki"

# Remove protected ABI exports so vendor modules load without symbol conflicts
rm -rf "$COMMON/android/abi_gki_protected_exports_"*
perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' "$COMMON/BUILD.bazel"

# ------------------------------------------------------------------------------
# 13. Clean Stock-like Kernel Name (NO -Wild, NO -dirty) & Default LTO
# ------------------------------------------------------------------------------
echo ">>> [13/14] Cleaning -dirty from scripts/setlocalversion (keeping stock uname & default LTO)..."
sed -i 's/-dirty//' "$COMMON/scripts/setlocalversion"

# ------------------------------------------------------------------------------
# 14. Zero-Leak Kernel Stealth Layers (1-7)
# ------------------------------------------------------------------------------
echo ">>> [14/14] Applying Zero-Leak Kernel Stealth Layers (apply_stealth.sh)..."
chmod +x "$SCRIPT_DIR/apply_stealth.sh"
KERNEL_ROOT="$KERNEL_ROOT" REPO_ROOT="$REPO_ROOT" "$SCRIPT_DIR/apply_stealth.sh"

# Verify zero patch rejects across the entire source tree
mapfile -t REJS < <(find "$COMMON" -type f -name '*.rej')
if [ "${#REJS[@]}" -gt 0 ]; then
  echo "::error::Found ${#REJS[@]} patch reject file(s):"
  for r in "${REJS[@]}"; do
    echo "=== $r ==="
    cat "$r"
  done
  exit 1
fi

echo "============================================================"
echo " All patches, configs, and stealth layers applied cleanly (0 rejects)!"
echo "============================================================"
