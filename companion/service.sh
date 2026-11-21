#!/system/bin/sh
# ==============================================================================
# SM-A146P Stealth Companion — Boot & Real-Time Sync Service
# ==============================================================================
MODDIR="${0%/*}"
SYNC_BIN="$MODDIR/bin/stealth_sync.sh"
PID_FILE="/data/adb/a146p_stealth_companion.pid"

# Wait for Android boot completion so PackageManager, HMA-OSS, and NoMount are ready
waited=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$waited" -lt 120 ]; do
  sleep 2
  waited=$((waited + 2))
done
sleep 3

# Initial sync at boot
sh "$SYNC_BIN" --quiet

# Stop any prior watcher from this module
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    pkill -P "$old_pid" 2>/dev/null || true
    kill "$old_pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi

# Start lightweight real-time inotifyd watcher for HMA-OSS config & packages.list changes
(
  echo "$$" > "$PID_FILE"

  # Wait up to 60s for HMA-OSS directory to appear if installed after boot
  hma_dir=""
  for _ in 1 2 3 4 5 6; do
    for d in /data/misc/hide_my_applist*; do
      if [ -d "$d" ]; then
        hma_dir="$d"
        break
      fi
    done
    [ -n "$hma_dir" ] && break
    sleep 10
  done

  watch_args="/data/system/packages.list:wM"
  if [ -n "$hma_dir" ]; then
    watch_args="$hma_dir:wM $watch_args"
  fi

  if command -v inotifyd >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    inotifyd - $watch_args 2>/dev/null | while read -r _ _ name; do
      case "$name" in
        config.json|preset_cache_v2.json|packages.list|"")
          sleep 2
          sh "$SYNC_BIN" --quiet
          ;;
      esac
    done
  fi
) </dev/null >/dev/null 2>&1 &
