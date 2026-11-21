#!/system/bin/sh
PID_FILE="/data/adb/a146p_stealth_companion.pid"
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    pkill -P "$old_pid" 2>/dev/null || true
    kill "$old_pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi
if [ -L /data/adb/ksu/bin/ksu_susfs ]; then
  target="$(readlink /data/adb/ksu/bin/ksu_susfs 2>/dev/null)"
  case "$target" in
    *a146p_stealth_companion*) rm -f /data/adb/ksu/bin/ksu_susfs ;;
  esac
fi
rm -f /data/adb/a146p_stealth_companion.log
