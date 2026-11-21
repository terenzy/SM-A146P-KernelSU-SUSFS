#!/system/bin/sh
# ==============================================================================
# SM-A146P Stealth Companion — KernelSU Module Installer
# ==============================================================================
SKIPUNZIP=0

ui_print "- Installing SM-A146P Stealth Companion..."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/bin/stealth_sync.sh" 0 0 0755

if [ -f "$MODPATH/bin/ksu_susfs" ]; then
  set_perm "$MODPATH/bin/ksu_susfs" 0 0 0755
  # Only symlink into /data/adb/ksu/bin if susfs4ksu-module hasn't installed one
  if [ -d /data/adb/ksu/bin ] && [ ! -e /data/adb/ksu/bin/ksu_susfs ]; then
    ln -sf "/data/adb/modules/a146p_stealth_companion/bin/ksu_susfs" /data/adb/ksu/bin/ksu_susfs
    ui_print "- Linked ksu_susfs -> /data/adb/ksu/bin/ksu_susfs"
  fi
fi

# Clean up any legacy watcher pidfile
rm -f /data/adb/a146p_stealth_companion.pid

ui_print "- Features:"
ui_print "  * SUSFS v2.4.0 runtime activation (AVC spoof + mount hide + sus_path)"
ui_print "  * Real-time HMA-OSS -> SUSFS priority_uid_filter sync"
ui_print "  * Real-time HMA-OSS target scopes -> NoMount UID isolation + block_isolated"
ui_print "  * Action button: instant re-sync + full kernel/userspace stealth self-audit"
ui_print "- Reboot to activate background watcher, or tap Action to sync immediately."
