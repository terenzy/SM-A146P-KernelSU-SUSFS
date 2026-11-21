#!/system/bin/sh
# ==============================================================================
# SM-A146P Stealth Companion — KernelSU-Next Action (Re-Sync + Live Self-Audit)
# ==============================================================================
MODDIR="${0%/*}"
SYNC_BIN="$MODDIR/bin/stealth_sync.sh"

echo "=================================================="
echo "  SM-A146P Full-Stack Stealth Companion Audit"
echo "=================================================="
echo ""

# 1. Run immediate full sync
sh "$SYNC_BIN" --verbose

echo ""
echo "--- Kernel Surface Verification ---"

# 2. Kernel identity
echo "[Kernel] uname -r: $(uname -r)"
echo "[Kernel] uname -v: $(uname -v)"

# 3. LSM visibility (/sys/kernel/security/lsm)
if [ -r /sys/kernel/security/lsm ]; then
  lsm_val="$(cat /sys/kernel/security/lsm 2>/dev/null)"
  case "$lsm_val" in
    *baseband_guard*)
      echo "[WARN]   /sys/kernel/security/lsm exposes baseband_guard: $lsm_val"
      ;;
    *)
      echo "[OK]     /sys/kernel/security/lsm clean: $lsm_val"
      ;;
  esac
else
  echo "[INFO]   /sys/kernel/security/lsm not readable"
fi

# 4. /proc/config.gz scrub verification
if [ -r /proc/config.gz ] && command -v gzip >/dev/null 2>&1; then
  leaks="$(gzip -dc /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(KSU|SUSFS|NOMOUNT|BBG|KPM)|baseband_guard' | head -n 5)"
  if [ -n "$leaks" ]; then
    echo "[WARN]   /proc/config.gz still exposes custom configs:"
    echo "$leaks"
  else
    echo "[OK]     /proc/config.gz 100% scrubbed (0 KSU/SUSFS/NoMount/BBG leaks)"
  fi
else
  echo "[INFO]   /proc/config.gz unavailable or gzip missing"
fi

# 5. dmesg banner/telegram leak verification
if command -v dmesg >/dev/null 2>&1; then
  dmesg_leaks="$(dmesg 2>/dev/null | grep -iE 'qdykernel|t\.me/|NoMount:|susfs:' | head -n 5)"
  if [ -n "$dmesg_leaks" ]; then
    echo "[WARN]   dmesg contains identifiable lines:"
    echo "$dmesg_leaks"
  else
    echo "[OK]     dmesg clean (0 Telegram / NoMount / SUSFS lines)"
  fi
fi

# 6. Userspace hygiene warnings
echo ""
echo "--- Userspace Module Hygiene ---"
cert_warn=0
for d in /data/adb/modules/*; do
  [ -d "$d" ] || continue
  [ -f "$d/disable" ] && continue
  [ -f "$d/remove" ] && continue
  if [ -f "$d/module.prop" ] && grep -qiE 'trust user cert|movecert|cacert' "$d/module.prop"; then
    mod_name="$(grep '^name=' "$d/module.prop" | head -n 1 | cut -d= -f2-)"
    echo "[WARN]   Active user-CA module detected: ${mod_name:-$(basename "$d")}"
    echo "         Banking/anti-cheat apps often flag injected system CA certs."
    cert_warn=1
  fi
done
[ "$cert_warn" -eq 0 ] && echo "[OK]     No active user-CA certificate injection module found"

echo ""
echo "=================================================="
echo "  Audit & Sync Complete"
echo "=================================================="
