#!/system/bin/sh
# ==============================================================================
# SM-A146P Stealth Companion — SUSFS v2.4.0 + HMA-OSS + NoMount Auto-Sync
# Pure POSIX sh + POSIX awk (zero Python/jq dependencies)
# ==============================================================================
MODE="${1:---quiet}"
SCRIPT_DIR="${0%/*}"
MODDIR="${SCRIPT_DIR%/*}"
LOG_FILE="${LOG_FILE:-/data/adb/a146p_stealth_companion.log}"
PACKAGES_LIST="${PACKAGES_LIST:-/data/system/packages.list}"
HMA_SEARCH_BASE="${HMA_SEARCH_BASE:-/data/misc}"

log_out() {
  msg="$1"
  if [ "$MODE" = "--verbose" ]; then
    echo "$msg"
  fi
  if [ -d "${LOG_FILE%/*}" ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

# Keep log file bounded
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 200 ]; then
  tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 1. Locate ksu_susfs & NoMount nm binaries
# ------------------------------------------------------------------------------
find_ksu_susfs() {
  for p in /data/adb/ksu/bin/ksu_susfs "$MODDIR/bin/ksu_susfs" /data/adb/modules/susfs4ksu/ksu_susfs; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

find_nm() {
  for p in /data/adb/modules/nomount/bin/nm /data/adb/ksu/bin/nm /data/adb/ap/bin/nm; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

KSU_SUSFS="$(find_ksu_susfs 2>/dev/null || true)"
NM_BIN="$(find_nm 2>/dev/null || true)"

# ------------------------------------------------------------------------------
# 2. Activate SUSFS v2.4.0 runtime protections
# ------------------------------------------------------------------------------
if [ -n "$KSU_SUSFS" ]; then
  susfs_ver="$("$KSU_SUSFS" show version 2>/dev/null | head -n 1 || true)"
  log_out "[SUSFS]  Binary: $KSU_SUSFS | Kernel: ${susfs_ver:-unknown}"

  "$KSU_SUSFS" hide_sus_mnts_for_non_su_procs 1 >/dev/null 2>&1 \
    && log_out "[SUSFS]  hide_sus_mnts_for_non_su_procs = 1" \
    || log_out "[SUSFS]  hide_sus_mnts_for_non_su_procs skipped"

  "$KSU_SUSFS" enable_avc_log_spoofing 1 >/dev/null 2>&1 \
    && log_out "[SUSFS]  enable_avc_log_spoofing = 1" \
    || log_out "[SUSFS]  enable_avc_log_spoofing skipped"

  # Safe no-op if CONFIG_KSU_SUSFS_ENABLE_LOG is compiled out
  "$KSU_SUSFS" enable_log 0 >/dev/null 2>&1 || true

  # Hide common residual root/recovery paths if they exist on disk
  for sus_p in \
    /sdcard/TWRP \
    /sdcard/Fox \
    /sdcard/OrangeFox \
    /data/local/tmp/ksud \
    /data/local/tmp/temp_su \
    /data/local/tmp/ksu-helper \
    /data/local/tmp/ksu-payload; do
    if [ -e "$sus_p" ]; then
      "$KSU_SUSFS" add_sus_path "$sus_p" >/dev/null 2>&1 || true
    fi
  done
else
  log_out "[WARN]   ksu_susfs binary not found!"
fi

# ------------------------------------------------------------------------------
# 3. Parse HMA-OSS config.json + preset_cache_v2.json (pure POSIX awk)
#    Emits lines prefixed with:
#      SCOPE <package_name>   (apps targeted by HMA-OSS: detectors, banks, games)
#      HIDDEN <package_name>  (apps hidden by HMA-OSS templates/presets/extras)
# ------------------------------------------------------------------------------
HMA_DIR=""
for d in "$HMA_SEARCH_BASE"/hide_my_applist*; do
  if [ -d "$d" ] && [ -f "$d/config.json" ]; then
    HMA_DIR="$d"
    break
  fi
done

parse_hma_config() {
  cfg="$1"
  pcache="$2"
  awk -v PCACHE="$pcache" '
  function tokenize(src, toks,    n, i, len, c, s, esc, j) {
    n = 0
    len = length(src)
    i = 1
    while (i <= len) {
      c = substr(src, i, 1)
      if (c == " " || c == "\t" || c == "\r" || c == "\n") {
        i++
      } else if (c == "{" || c == "}" || c == "[" || c == "]" || c == ":" || c == ",") {
        toks[++n] = c
        i++
      } else if (c == "\"") {
        s = ""
        i++
        esc = 0
        while (i <= len) {
          c = substr(src, i, 1)
          if (esc) {
            s = s c
            esc = 0
            i++
          } else if (c == "\\") {
            esc = 1
            i++
          } else if (c == "\"") {
            i++
            break
          } else {
            s = s c
            i++
          }
        }
        toks[++n] = "S:" s
      } else {
        j = i
        while (i <= len) {
          c = substr(src, i, 1)
          if (c == " " || c == "\t" || c == "\r" || c == "\n" || c == "," || c == "}" || c == "]" || c == ":")
            break
          i++
        }
        toks[++n] = "V:" substr(src, j, i - j)
      }
    }
    return n
  }

  function skip_val(toks, pos, n,    depth, t) {
    t = toks[pos]
    if (t == "{" || t == "[") {
      depth = 1
      pos++
      while (pos <= n && depth > 0) {
        if (toks[pos] == "{" || toks[pos] == "[") depth++
        else if (toks[pos] == "}" || toks[pos] == "]") depth--
        pos++
      }
      return pos
    }
    return pos + 1
  }

  function read_str_array(toks, pos, n, out_arr, prefix,    t, val) {
    if (toks[pos] != "[") return skip_val(toks, pos, n)
    pos++
    while (pos <= n && toks[pos] != "]") {
      t = toks[pos]
      if (substr(t, 1, 2) == "S:") {
        val = substr(t, 3)
        if (val != "") out_arr[prefix val] = 1
      }
      pos++
      if (pos <= n && toks[pos] == ",") pos++
    }
    if (pos <= n && toks[pos] == "]") pos++
    return pos
  }

  function parse_preset_cache(path,    line, raw, toks, n, pos, k, pkey, t) {
    if (path == "") return
    raw = ""
    while ((getline line < path) > 0) raw = raw "\n" line
    close(path)
    if (raw == "") return
    n = tokenize(raw, toks)
    pos = 1
    if (toks[pos] != "{") return
    pos++
    while (pos <= n && toks[pos] != "}") {
      t = toks[pos]
      if (substr(t, 1, 2) != "S:") { pos++; continue }
      k = substr(t, 3)
      pos++
      if (pos <= n && toks[pos] == ":") pos++
      if (k == "cache" && toks[pos] == "{") {
        pos++
        while (pos <= n && toks[pos] != "}") {
          if (substr(toks[pos], 1, 2) == "S:") {
            pkey = substr(toks[pos], 3)
            pos++
            if (pos <= n && toks[pos] == ":") pos++
            pos = read_str_array(toks, pos, n, preset_apps, pkey SUBSEP)
          } else {
            pos++
          }
          if (pos <= n && toks[pos] == ",") pos++
        }
        if (pos <= n && toks[pos] == "}") pos++
      } else if (k == "riskyPackageCache") {
        pos = read_str_array(toks, pos, n, risky_pkgs, "")
      } else {
        pos = skip_val(toks, pos, n)
      }
      if (pos <= n && toks[pos] == ",") pos++
    }
  }

  function parse_app_config(toks, pos, n, scope_key,    f, t, is_wl) {
    if (toks[pos] != "{") return skip_val(toks, pos, n)
    pos++
    is_wl = 0
    while (pos <= n && toks[pos] != "}") {
      if (substr(toks[pos], 1, 2) != "S:") { pos++; continue }
      f = substr(toks[pos], 3)
      pos++
      if (pos <= n && toks[pos] == ":") pos++
      if (f == "useWhitelist") {
        if (toks[pos] == "V:true") is_wl = 1
        pos++
      } else if (f == "applyTemplates") {
        pos = read_str_array(toks, pos, n, sc_tpl, scope_key SUBSEP)
      } else if (f == "applyPresets") {
        pos = read_str_array(toks, pos, n, sc_pre, scope_key SUBSEP)
      } else if (f == "extraAppList") {
        pos = read_str_array(toks, pos, n, sc_ext, scope_key SUBSEP)
      } else if (f == "extraOppositeAppList") {
        pos = read_str_array(toks, pos, n, sc_opp, scope_key SUBSEP)
      } else {
        pos = skip_val(toks, pos, n)
      }
      if (pos <= n && toks[pos] == ",") pos++
    }
    if (pos <= n && toks[pos] == "}") pos++
    sc_wl[scope_key] = is_wl
    return pos
  }

  BEGIN {
    raw_cfg = ""
  }
  {
    raw_cfg = raw_cfg "\n" $0
  }
  END {
    parse_preset_cache(PCACHE)
    n = tokenize(raw_cfg, toks)
    pos = 1
    if (toks[pos] != "{") exit 0
    pos++
    while (pos <= n && toks[pos] != "}") {
      if (substr(toks[pos], 1, 2) != "S:") { pos++; continue }
      top = substr(toks[pos], 3)
      pos++
      if (pos <= n && toks[pos] == ":") pos++
      if (top == "ignoredPackagesForPresets") {
        pos = read_str_array(toks, pos, n, ignored_pre, "")
      } else if (top == "templates" && toks[pos] == "{") {
        pos++
        while (pos <= n && toks[pos] != "}") {
          if (substr(toks[pos], 1, 2) == "S:") {
            tname = substr(toks[pos], 3)
            pos++
            if (pos <= n && toks[pos] == ":") pos++
            if (toks[pos] == "{") {
              pos++
              tpl_wl[tname] = 0
              while (pos <= n && toks[pos] != "}") {
                if (substr(toks[pos], 1, 2) == "S:") {
                  tf = substr(toks[pos], 3)
                  pos++
                  if (pos <= n && toks[pos] == ":") pos++
                  if (tf == "isWhitelist") {
                    if (toks[pos] == "V:true") tpl_wl[tname] = 1
                    pos++
                  } else if (tf == "appList") {
                    pos = read_str_array(toks, pos, n, tpl_apps, tname SUBSEP)
                  } else {
                    pos = skip_val(toks, pos, n)
                  }
                } else {
                  pos++
                }
                if (pos <= n && toks[pos] == ",") pos++
              }
              if (pos <= n && toks[pos] == "}") pos++
            } else {
              pos = skip_val(toks, pos, n)
            }
          } else {
            pos++
          }
          if (pos <= n && toks[pos] == ",") pos++
        }
        if (pos <= n && toks[pos] == "}") pos++
      } else if (top == "scope" && toks[pos] == "{") {
        pos++
        while (pos <= n && toks[pos] != "}") {
          if (substr(toks[pos], 1, 2) == "S:") {
            spkg = substr(toks[pos], 3)
            scopes[spkg] = 1
            pos++
            if (pos <= n && toks[pos] == ":") pos++
            pos = parse_app_config(toks, pos, n, spkg)
          } else {
            pos++
          }
          if (pos <= n && toks[pos] == ",") pos++
        }
        if (pos <= n && toks[pos] == "}") pos++
      } else if (top == "defaultConfig" && toks[pos] == "{") {
        has_default = 1
        pos = parse_app_config(toks, pos, n, "__DEFAULT__")
      } else {
        pos = skip_val(toks, pos, n)
      }
      if (pos <= n && toks[pos] == ",") pos++
    }

    # Emit SCOPE packages (every app protected by HMA-OSS)
    for (spkg in scopes) {
      print "SCOPE " spkg
    }

    # Resolve HIDDEN packages per scope
    if (has_default) scopes["__DEFAULT__"] = 1
    for (spkg in scopes) {
      delete local_hide
      if (sc_wl[spkg] == 1) {
        # Whitelist scope: only explicitly hidden extras + riskyPresetCache
        for (k in sc_opp) {
          split(k, parts, SUBSEP)
          if (parts[1] == spkg) local_hide[parts[2]] = 1
        }
        for (rp in risky_pkgs) {
          if (!(rp in ignored_pre)) local_hide[rp] = 1
        }
      } else {
        # Blacklist scope: templates (non-whitelist) + presets + extraAppList - extraOppositeAppList
        for (k in sc_tpl) {
          split(k, parts, SUBSEP)
          if (parts[1] == spkg) {
            tn = parts[2]
            if (tpl_wl[tn] == 0) {
              for (ak in tpl_apps) {
                split(ak, ap, SUBSEP)
                if (ap[1] == tn) local_hide[ap[2]] = 1
              }
            }
          }
        }
        for (k in sc_pre) {
          split(k, parts, SUBSEP)
          if (parts[1] == spkg) {
            pn = parts[2]
            for (pk in preset_apps) {
              split(pk, pp, SUBSEP)
              if (pp[1] == pn && !(pp[2] in ignored_pre)) local_hide[pp[2]] = 1
            }
          }
        }
        for (k in sc_ext) {
          split(k, parts, SUBSEP)
          if (parts[1] == spkg) local_hide[parts[2]] = 1
        }
        for (k in sc_opp) {
          split(k, parts, SUBSEP)
          if (parts[1] == spkg) delete local_hide[parts[2]]
        }
      }
      for (h in local_hide) {
        if (h != "" && h != spkg) global_hide[h] = 1
      }
    }

    for (h in global_hide) {
      print "HIDDEN " h
    }
  }
  ' "$cfg"
}

TMP_DIR="${TMPDIR:-/data/local/tmp}"
[ -d "$TMP_DIR" ] || TMP_DIR="/tmp"
PARSED_FILE="$TMP_DIR/.a146p_stealth_parsed.$$"
HIDDEN_FILE="$TMP_DIR/.a146p_stealth_hidden.$$"
SCOPE_FILE="$TMP_DIR/.a146p_stealth_scope.$$"
trap 'rm -f "$PARSED_FILE" "$HIDDEN_FILE" "$SCOPE_FILE"' EXIT

: > "$PARSED_FILE"
if [ -n "$HMA_DIR" ]; then
  PCACHE_PATH=""
  [ -f "$HMA_DIR/preset_cache_v2.json" ] && PCACHE_PATH="$HMA_DIR/preset_cache_v2.json"
  parse_hma_config "$HMA_DIR/config.json" "$PCACHE_PATH" > "$PARSED_FILE" 2>/dev/null || true
  log_out "[HMA]    Loaded config from $HMA_DIR"
else
  log_out "[HMA]    No HMA-OSS config directory found under $HMA_SEARCH_BASE (using baseline managers only)"
fi

# Curated baseline of root/hiding/hook managers (only kept if actually installed in packages.list)
{
  awk '$1 == "HIDDEN" { print $2 }' "$PARSED_FILE"
  cat <<'EOF'
com.rifsxd.ksunext
me.weishu.kernelsu
org.frknkrc44.hma_oss
com.tsng.hidemyapplist
com.tsng.pzyhrx.hma
org.lsposed.manager
io.github.a13e300.fusefixer
io.github.a13e300.ksuwebui
com.sukisu.ultra
com.resukisu.resukisu
me.bmax.apatch
com.topjohnwu.magisk
io.github.vvb2060.magisk
EOF
} | sort -u > "$HIDDEN_FILE"

awk '$1 == "SCOPE" { print $2 }' "$PARSED_FILE" | sort -u > "$SCOPE_FILE"

# ------------------------------------------------------------------------------
# 4. Sync installed hidden apps -> SUSFS set_priority_uid_filter
# ------------------------------------------------------------------------------
if [ -n "$KSU_SUSFS" ] && [ -r "$PACKAGES_LIST" ]; then
  # Keep only packages installed in packages.list with ordinary app UID (10000..19999)
  CSV_LIST="$(awk '
    NR == FNR {
      uid = $2 + 0
      appid = uid % 100000
      if (appid >= 10000 && appid <= 19999) installed[$1] = uid
      next
    }
    ($1 in installed) {
      if (length(out) + length($1) + 2 < 60000) {
        out = (out == "" ? $1 : out "," $1)
        cnt++
      }
    }
    END {
      if (cnt > 0) print cnt "|" out
    }
  ' "$PACKAGES_LIST" "$HIDDEN_FILE")"

  if [ -n "$CSV_LIST" ]; then
    HIDE_COUNT="${CSV_LIST%%|*}"
    HIDE_CSV="${CSV_LIST#*|}"
    if "$KSU_SUSFS" set_priority_uid_filter "$HIDE_CSV" >/dev/null 2>&1; then
      log_out "[SUSFS]  priority_uid_filter synced: ${HIDE_COUNT} installed package(s)"
      if [ "$MODE" = "--verbose" ]; then
        echo "         Packages: $HIDE_CSV"
      fi
    else
      log_out "[WARN]   ksu_susfs set_priority_uid_filter failed"
    fi
  else
    log_out "[SUSFS]  priority_uid_filter: 0 matching installed packages"
  fi
fi

# ------------------------------------------------------------------------------
# 5. Sync HMA-OSS target scopes -> NoMount UID isolation + block_isolated on
# ------------------------------------------------------------------------------
if [ -n "$NM_BIN" ]; then
  nm_ver="$("$NM_BIN" version 2>/dev/null | head -n 1 || true)"
  if [ -n "$nm_ver" ]; then
    log_out "[NoMount] Driver protocol: $nm_ver"

    # Always block isolated processes from observing NoMount VFS redirections
    "$NM_BIN" uid block_isolated on >/dev/null 2>&1 || true
    mkdir -p /data/adb/nomount 2>/dev/null || true
    : > /data/adb/nomount/.block_isolated_uids 2>/dev/null || true
    log_out "[NoMount] block_isolated = on"

    # Add every HMA-OSS protected target app (detectors, banks, anti-cheats) to NoMount UID exclusions
    if [ -r "$PACKAGES_LIST" ] && [ -s "$SCOPE_FILE" ]; then
      SCOPE_UIDS="$(awk '
        NR == FNR {
          uid = $2 + 0
          appid = uid % 100000
          if (appid >= 10000 && appid <= 19999) installed[$1] = uid
          next
        }
        ($1 in installed) { print installed[$1] }
      ' "$PACKAGES_LIST" "$SCOPE_FILE" | sort -nu)"

      added=0
      for u in $SCOPE_UIDS; do
        "$NM_BIN" uid add "$u" >/dev/null 2>&1 && added=$((added + 1)) || true
      done
      log_out "[NoMount] Synced ${added} HMA-scoped app UID(s) to NoMount exclusions"
    else
      log_out "[NoMount] No HMA-scoped target apps to exclude"
    fi
  else
    log_out "[WARN]   NoMount CLI present at $NM_BIN but driver did not respond"
  fi
else
  log_out "[INFO]   NoMount module not installed; skipping NoMount UID isolation"
fi
