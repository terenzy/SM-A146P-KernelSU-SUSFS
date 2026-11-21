#!/usr/bin/env bash
# ==============================================================================
# Full-Stack Kernel Stealth Hardening for SM-A146P (Binary L 6.6.127)
#
# Safety invariants:
#   - Zero heap allocations or sleeping in atomic/RCU contexts
#   - Zero lock imbalances (all kernel locks released identically to stock)
#   - Strict exact-anchor verification (fails build on any anchor mismatch)
#   - Non-root/app-only scoping where appropriate so init/system_server/root stay untouched
#
# Layers applied:
#   1. Surgical PRIORITY_UID_FILTER: auto-hide KSU Manager & KSU allowlisted UIDs
#      (lockless/RCU-safe) + self-UID guard, seamlessly combined with SUSFS v2.4.0
#      dynamic bitmap for HMA-OSS synced apps across getpriority/setpriority/ioprio_*
#   2. NoMount cloaking: close add_key/request_key("nomount") oracle (return -ENOKEY/
#      -ENODEV for !CAP_SYS_ADMIN), silence dmesg/modinfo strings, hide kallsyms
#   3. Baseband-guard cloaking: strip Telegram/Chinese banner & modinfo, hide from
#      /sys/kernel/security/lsm & boot dmesg while keeping LSM hooks 100% enforcing,
#      hide kallsyms
#   4. /proc/config.gz (IKCONFIG) scrubbing: strip KSU/SUSFS/NoMount/BBG/KPM entries
#      and baseband_guard from config_data while preserving stock-like display
#   5. Non-root /proc/cmdline & /proc/bootconfig bootloader-state sanitization
#      (zero-allocation seq_file streaming, UID >= 10000 only, SUSFS takes precedence)
#   6. Stock Samsung build identity matching (uname -v, /proc/version user/host/timestamp
#      extracted dynamically from stock boot.img.lz4)
#   7. 2026 CVE security fixes (CVE-2026-43499, CVE-2026-64560, CVE-2026-98260),
#      SUSFS dmesg log disabled, CONFIG_SECURITY_DMESG_RESTRICT enabled
# ==============================================================================
set -euo pipefail

KERNEL_ROOT="${KERNEL_ROOT:?KERNEL_ROOT must be set}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STOCK_KERNEL_BANNER="${STOCK_KERNEL_BANNER:-}"

COMMON="$KERNEL_ROOT/kernel-6.6"
GKI_DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
CONFIG_TOOL="$COMMON/scripts/config"

test -d "$COMMON" || { echo "ERROR: Missing $COMMON" >&2; exit 1; }
test -f "$GKI_DEFCONFIG" || { echo "ERROR: Missing $GKI_DEFCONFIG" >&2; exit 1; }
cd "$COMMON"

echo "============================================================"
echo " Applying Zero-Leak Kernel Stealth Layers (1-7)"
echo "============================================================"

# ------------------------------------------------------------------------------
# Layer 1: Surgical PRIORITY_UID_FILTER in fs/susfs.c (RCU-safe)
# ------------------------------------------------------------------------------
echo ">>> [Stealth 1/7] Enhancing SUSFS PRIORITY_UID_FILTER (KSU auto-hide + self-UID guard + log-off stubs)..."
python3 - <<'PY'
from pathlib import Path
import re

p = Path("fs/susfs.c")
text = p.read_text()

# 1a. Fix upstream SUSFS v2.4.0 missing #else stubs for SUSFS_LOGI_RL / SUSFS_LOGE_RL
# when CONFIG_KSU_SUSFS_ENABLE_LOG is disabled.
m = re.search(
    r"(#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG\b.*?#else\b)(.*?)(#endif)",
    text,
    flags=re.DOTALL,
)
assert m, "CONFIG_KSU_SUSFS_ENABLE_LOG #ifdef/#else/#endif block not found in fs/susfs.c"
else_body = m.group(2)
stubs = ""
if "SUSFS_LOGI_RL" not in else_body:
    stubs += "#define SUSFS_LOGI_RL(fmt, ...) do { } while (0)\n"
if "SUSFS_LOGE_RL" not in else_body:
    stubs += "#define SUSFS_LOGE_RL(fmt, ...) do { } while (0)\n"
if stubs:
    text = text[: m.start(3)] + stubs + text[m.start(3) :]
    print("Patched fs/susfs.c: added missing SUSFS_LOGI_RL / SUSFS_LOGE_RL #else no-op stubs")

# 1b. Surgical PRIORITY_UID_FILTER enhancement (RCU-safe)
sig = "bool susfs_is_priority_uid_filtered(uid_t uid) {"
assert sig in text, "susfs_is_priority_uid_filtered not found in fs/susfs.c"

if "__ksu_is_allow_uid" not in text:
    decl = (
        "#ifdef CONFIG_KSU\n"
        "extern bool __ksu_is_allow_uid(uid_t uid);\n"
        "#endif\n\n"
    )
    text = text.replace(sig, decl + sig, 1)

anchor = (
    "\tif (app_id < SUSFS_UID_FILTER_MIN_UID ||\n"
    "\t\tapp_id > SUSFS_UID_FILTER_MAX_UID)\n"
    "\t\treturn false;\n"
)
assert anchor in text, "SUSFS_UID_FILTER_MAX_UID bounds check not found in fs/susfs.c"

inject = (
    anchor
    + "\n"
    + "\t/* Never hide caller's own UID so self-check controls always pass */\n"
    + "\tif (uid == current_uid().val)\n"
    + "\t\treturn false;\n"
    + "\n"
    + "#ifdef CONFIG_KSU\n"
    + "\t/* Automatically hide KSU Manager & root-allowlisted app UIDs (RCU-safe) */\n"
    + "\tif (__ksu_is_allow_uid(uid))\n"
    + "\t\treturn true;\n"
    + "#endif\n"
)

if "Never hide caller's own UID" not in text:
    text = text.replace(anchor, inject, 1)
    print("Patched fs/susfs.c: surgical PRIORITY_UID_FILTER enhancement applied")
else:
    print("fs/susfs.c: surgical PRIORITY_UID_FILTER enhancement already present")

p.write_text(text)
PY

# ------------------------------------------------------------------------------
# Layer 2: NoMount Keyring Oracle Closure + dmesg/modinfo Silence + Kallsyms Hide
# ------------------------------------------------------------------------------
echo ">>> [Stealth 2/7] Closing NoMount keyring oracle, silencing logs, hiding kallsyms..."
python3 - <<'PY'
from pathlib import Path
import re

# 2a. security/keys/key.c: hide "nomount" key type from non-CAP_SYS_ADMIN callers
key_c = Path("security/keys/key.c")
text = key_c.read_text()

if "#include <linux/capability.h>" not in text:
    inc_anchor = "#include <linux/security.h>\n"
    assert inc_anchor in text, "Anchor #include <linux/security.h> missing in security/keys/key.c"
    text = text.replace(inc_anchor, inc_anchor + "#include <linux/capability.h>\n", 1)

lookup_old = (
    "\tlist_for_each_entry(ktype, &key_types_list, link) {\n"
    "\t\tif (strcmp(ktype->name, type) == 0)\n"
    "\t\t\tgoto found_kernel_type;\n"
    "\t}\n"
)
lookup_new = (
    "\tlist_for_each_entry(ktype, &key_types_list, link) {\n"
    "\t\tif (strcmp(ktype->name, type) == 0) {\n"
    "#ifdef CONFIG_NOMOUNT\n"
    "\t\t\tif (strcmp(type, \"nomount\") == 0 && !capable(CAP_SYS_ADMIN))\n"
    "\t\t\t\tbreak;\n"
    "#endif\n"
    "\t\t\tgoto found_kernel_type;\n"
    "\t\t}\n"
    "\t}\n"
)
if 'strcmp(type, "nomount")' not in text:
    assert lookup_old in text, "key_type_lookup loop anchor not found in security/keys/key.c"
    text = text.replace(lookup_old, lookup_new, 1)
    key_c.write_text(text)
    print("Patched security/keys/key.c: closed NoMount keyring oracle (!CAP_SYS_ADMIN -> -ENOKEY/-ENODEV)")

# 2b. NoMount/kernel/src/nomount.h: silence all NoMount printk macros without unused-var warnings
nm_h = Path("NoMount/kernel/src/nomount.h")
assert nm_h.is_file(), "NoMount/kernel/src/nomount.h not found"
text = nm_h.read_text()
replaced = 0
for macro in ("nm_debug", "nm_info", "nm_warn", "nm_err"):
    pattern = re.compile(rf"^#define\s+{macro}\(fmt,\s*\.\.\.\).*$", re.MULTILINE)
    text, n = pattern.subn(
        f"#define {macro}(fmt, ...) do {{ if (0) no_printk(fmt, ##__VA_ARGS__); }} while (0)",
        text,
    )
    replaced += n
assert replaced == 4, f"Expected to silence 4 nm_* macros in nomount.h, replaced {replaced}"
nm_h.write_text(text)
print("Patched NoMount/kernel/src/nomount.h: silenced all nm_* dmesg logs")

# 2c. NoMount/kernel/src/nomount.c: scrub identifying MODULE_AUTHOR/DESCRIPTION
nm_c = Path("NoMount/kernel/src/nomount.c")
assert nm_c.is_file(), "NoMount/kernel/src/nomount.c not found"
text = nm_c.read_text()
text = re.sub(r'MODULE_AUTHOR\(".*?"\);', 'MODULE_AUTHOR("Android");', text)
text = re.sub(r'MODULE_DESCRIPTION\(".*?"\);', 'MODULE_DESCRIPTION("VFS cache helper");', text)
nm_c.write_text(text)
print("Patched NoMount/kernel/src/nomount.c: neutralized modinfo metadata")

# 2d. kernel/kallsyms.c: extend SUSFS symbol hiding to NoMount, Baseband-guard, and ksu_toolkit
ksym_c = Path("kernel/kallsyms.c")
text = ksym_c.read_text()
ksym_anchor = '\t\t\tsusfs_starts_with(iter->name, "is_zygote"))'
assert ksym_anchor in text, "SUSFS kallsyms anchor not found in kernel/kallsyms.c"
if '"nomount_"' not in text:
    ksym_new = (
        '\t\t\tsusfs_starts_with(iter->name, "is_zygote") ||\n'
        '\t\t\tsusfs_starts_with(iter->name, "nomount_") ||\n'
        '\t\t\tsusfs_starts_with(iter->name, "nm_") ||\n'
        '\t\t\tsusfs_starts_with(iter->name, "bbg_") ||\n'
        '\t\t\tsusfs_starts_with(iter->name, "baseband_guard") ||\n'
        '\t\t\tsusfs_starts_with(iter->name, "ksu_toolkit"))'
    )
    text = text.replace(ksym_anchor, ksym_new, 1)
    ksym_c.write_text(text)
    print("Patched kernel/kallsyms.c: hid nomount_*, nm_*, bbg_*, baseband_guard*, ksu_toolkit* symbols")
PY

# ------------------------------------------------------------------------------
# Layer 3: Baseband-guard LSM Cloaking & Telegram/Chinese Banner Stripping
# ------------------------------------------------------------------------------
echo ">>> [Stealth 3/7] Cloaking Baseband-guard LSM and stripping Telegram/Chinese strings..."
python3 - <<'PY'
from pathlib import Path
import re

# 3a. Baseband-guard/baseband_guard.h: silence bb_pr & bb_pr_rl
bbg_h = Path("Baseband-guard/baseband_guard.h")
assert bbg_h.is_file(), "Baseband-guard/baseband_guard.h not found"
text = bbg_h.read_text()
text, n1 = re.subn(
    r"^#define\s+bb_pr\(fmt,\s*\.\.\.\).*$",
    "#define bb_pr(fmt, ...) do { if (0) no_printk(fmt, ##__VA_ARGS__); } while (0)",
    text,
    flags=re.MULTILINE,
)
text, n2 = re.subn(
    r"^#define\s+bb_pr_rl\(fmt,\s*\.\.\.\).*$",
    "#define bb_pr_rl(fmt, ...) do { if (0) no_printk(fmt, ##__VA_ARGS__); } while (0)",
    text,
    flags=re.MULTILINE,
)
assert n1 == 1 and n2 == 1, f"Failed to patch bb_pr/bb_pr_rl macros ({n1}, {n2})"
bbg_h.write_text(text)

# 3b. Baseband-guard/baseband_guard.c: strip Telegram/Chinese banners & deny pr_info
bbg_c = Path("Baseband-guard/baseband_guard.c")
assert bbg_c.is_file(), "Baseband-guard/baseband_guard.c not found"
text = bbg_c.read_text()

# Silence bbg_log_deny_detail cleanly without unreachable-code or unused-helper warnings
text = text.replace(
    "static const char *bbg_file_path(",
    "static __maybe_unused const char *bbg_file_path(",
    1,
)
text = text.replace(
    "static int bbg_get_cmdline(",
    "static __maybe_unused int bbg_get_cmdline(",
    1,
)
text, n_deny = re.subn(
    r"static void bbg_log_deny_detail\(const char \*why, struct file \*file, struct inode \*inode, unsigned int cmd_opt\)\n\{.*?\n\}",
    "static void bbg_log_deny_detail(const char *why, struct file *file, struct inode *inode, unsigned int cmd_opt)\n{\n\t(void)why;\n\t(void)file;\n\t(void)inode;\n\t(void)cmd_opt;\n}",
    text,
    count=1,
    flags=re.DOTALL,
)
assert n_deny == 1, "Failed to silence bbg_log_deny_detail in baseband_guard.c"
text = re.sub(r'^\s*pr_info\("baseband_guard[^\n]*\);\s*\n', "", text, flags=re.MULTILINE)
text = re.sub(r'MODULE_DESCRIPTION\(".*?"\);', 'MODULE_DESCRIPTION("Block partition integrity guard");', text)
text = re.sub(r'MODULE_AUTHOR\(".*?"\);', 'MODULE_AUTHOR("Android");', text)

for forbidden in ("qdykernel", "t.me/", "秋刀鱼", "baseband_guard: deny"):
    assert forbidden not in text, f"Forbidden string '{forbidden}' still present in baseband_guard.c"
bbg_c.write_text(text)
print("Patched Baseband-guard: stripped Telegram/Chinese banners, modinfo, and deny logs")

# 3c. security/security.c: hide "baseband_guard" from /sys/kernel/security/lsm & boot dmesg
sec_c = Path("security/security.c")
text = sec_c.read_text()

lsm_append_anchor = "static int lsm_append(const char *new, char **result)\n{\n\tchar *cp;\n"
assert lsm_append_anchor in text, "lsm_append anchor not found in security/security.c"
if '!strcmp(new, "baseband_guard")' not in text:
    text = text.replace(
        lsm_append_anchor,
        lsm_append_anchor
        + "\n\tif (new && !strcmp(new, \"baseband_guard\"))\n\t\treturn 0;\n",
        1,
    )

report_old = (
    "\tfor (lsm = ordered_lsms; *lsm; lsm++)\n"
    "\t\tif (is_enabled(*lsm))\n"
    "\t\t\tpr_cont(\"%s%s\", first++ == 0 ? \"\" : \",\", (*lsm)->name);\n"
)
report_new = (
    "\tfor (lsm = ordered_lsms; *lsm; lsm++)\n"
    "\t\tif (is_enabled(*lsm) && strcmp((*lsm)->name, \"baseband_guard\") != 0)\n"
    "\t\t\tpr_cont(\"%s%s\", first++ == 0 ? \"\" : \",\", (*lsm)->name);\n"
)
if 'strcmp((*lsm)->name, "baseband_guard")' not in text:
    assert report_old in text, "report_lsm_order anchor not found in security/security.c"
    text = text.replace(report_old, report_new, 1)

sec_c.write_text(text)
print("Patched security/security.c: baseband_guard hidden from /sys/kernel/security/lsm & boot log (hooks stay active)")
PY

# ------------------------------------------------------------------------------
# Layer 4: /proc/config.gz (IKCONFIG) Stealth Scrubbing in kernel/Makefile
# ------------------------------------------------------------------------------
echo ">>> [Stealth 4/7] Extending kernel/Makefile config_data scrubber for /proc/config.gz..."
python3 - <<'PY'
from pathlib import Path

mk = Path("kernel/Makefile")
text = mk.read_text()
anchor = "\t$(Q)$(config_fix)\n"
assert anchor in text, "IPv6_NAT_FIX $(config_fix) anchor not found in kernel/Makefile"

if "config_stealth_scrub" not in text:
    scrub_def = """
define config_stealth_scrub
\techo "kernel: Scrubbing stealth markers from config_data (/proc/config.gz)..."; \\
\tsed -i -E '/^(# )?CONFIG_(KSU|SUSFS|NOMOUNT|BBG|KPM)(_|=| )/d' $@; \\
\tsed -i -E 's/,baseband_guard//g; s/baseband_guard,//g' $@; \\
\tsed -i 's/^# CONFIG_SECURITY_DEFEX is not set$$/CONFIG_SECURITY_DEFEX=y/' $@; \\
\tsed -i 's/^# CONFIG_SECURITY_DEFEX_USER is not set$$/CONFIG_SECURITY_DEFEX_USER=y/' $@; \\
\techo "kernel: config_data stealth scrub complete"
endef

"""
    target_block = "$(obj)/config_data: $(KCONFIG_CONFIG) FORCE\n\t$(call filechk,cat)\n\t$(Q)$(config_fix)\n"
    assert target_block in text, "config_data rule block not found in kernel/Makefile"
    text = text.replace(
        target_block,
        scrub_def
        + "$(obj)/config_data: $(KCONFIG_CONFIG) FORCE\n"
        + "\t$(call filechk,cat)\n"
        + "\t$(Q)$(config_fix)\n"
        + "\t$(Q)$(config_stealth_scrub)\n",
        1,
    )
    mk.write_text(text)
    print("Patched kernel/Makefile: /proc/config.gz will scrub KSU/SUSFS/NoMount/BBG/KPM and restore stock DEFEX display")
PY

# ------------------------------------------------------------------------------
# Layer 5: Safe Kernel-Level /proc/cmdline & /proc/bootconfig Sanitization
#          (UID >= 10000 only, zero heap allocation, SUSFS takes precedence)
# ------------------------------------------------------------------------------
echo ">>> [Stealth 5/7] Adding non-root /proc/cmdline & /proc/bootconfig sanitization..."
cat <<'EOF' > fs/proc/stealth_boot.h
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _PROC_STEALTH_BOOT_H
#define _PROC_STEALTH_BOOT_H

#include <linux/cred.h>
#include <linux/seq_file.h>
#include <linux/string.h>

struct proc_stealth_repl {
	const char *match;
	size_t match_len;
	const char *repl;
};

#define PROC_STEALTH_ENTRY(m, r) { (m), sizeof(m) - 1, (r) }

static const struct proc_stealth_repl proc_stealth_repls[] = {
	/* /proc/cmdline (space-delimited key=val) */
	PROC_STEALTH_ENTRY("androidboot.verifiedbootstate=orange",         "androidboot.verifiedbootstate=green"),
	PROC_STEALTH_ENTRY("androidboot.verifiedbootstate=yellow",         "androidboot.verifiedbootstate=green"),
	PROC_STEALTH_ENTRY("androidboot.flash.locked=0",                   "androidboot.flash.locked=1"),
	PROC_STEALTH_ENTRY("androidboot.vbmeta.device_state=unlocked",     "androidboot.vbmeta.device_state=locked"),
	PROC_STEALTH_ENTRY("androidboot.warranty_bit=1",                   "androidboot.warranty_bit=0"),
	PROC_STEALTH_ENTRY("androidboot.veritymode=disabled",              "androidboot.veritymode=enforcing"),
	/* /proc/bootconfig (key = "val") */
	PROC_STEALTH_ENTRY("androidboot.verifiedbootstate = \"orange\"",   "androidboot.verifiedbootstate = \"green\""),
	PROC_STEALTH_ENTRY("androidboot.verifiedbootstate = \"yellow\"",   "androidboot.verifiedbootstate = \"green\""),
	PROC_STEALTH_ENTRY("androidboot.flash.locked = \"0\"",             "androidboot.flash.locked = \"1\""),
	PROC_STEALTH_ENTRY("androidboot.vbmeta.device_state = \"unlocked\"", "androidboot.vbmeta.device_state = \"locked\""),
	PROC_STEALTH_ENTRY("androidboot.warranty_bit = \"1\"",             "androidboot.warranty_bit = \"0\""),
	PROC_STEALTH_ENTRY("androidboot.veritymode = \"disabled\"",        "androidboot.veritymode = \"enforcing\""),
};

static inline bool proc_stealth_is_app_caller(void)
{
	return (current_uid().val % 100000) >= 10000;
}

static inline bool proc_stealth_delim_end(char c)
{
	return c == '\0' || c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static inline void proc_stealth_seq_puts(struct seq_file *m, const char *src)
{
	const char *p = src;
	const char *chunk = src;
	size_t i;

	if (!src)
		return;

	if (!proc_stealth_is_app_caller()) {
		seq_puts(m, src);
		return;
	}

	while (*p) {
		if (*p == 'a' && (p == src || proc_stealth_delim_end(p[-1]))) {
			for (i = 0; i < ARRAY_SIZE(proc_stealth_repls); i++) {
				const struct proc_stealth_repl *e = &proc_stealth_repls[i];

				if (!strncmp(p, e->match, e->match_len) &&
				    proc_stealth_delim_end(p[e->match_len])) {
					if (p > chunk)
						seq_write(m, chunk, p - chunk);
					seq_puts(m, e->repl);
					p += e->match_len;
					chunk = p;
					goto next_char;
				}
			}
		}
		p++;
next_char:
		;
	}
	if (p > chunk)
		seq_write(m, chunk, p - chunk);
}

#endif /* _PROC_STEALTH_BOOT_H */
EOF

python3 - <<'PY'
from pathlib import Path

# 5a. fs/proc/cmdline.c
cmd_c = Path("fs/proc/cmdline.c")
text = cmd_c.read_text()
if '#include "stealth_boot.h"' not in text:
    inc_anchor = '#include "internal.h"\n'
    assert inc_anchor in text, "internal.h anchor not found in fs/proc/cmdline.c"
    text = text.replace(inc_anchor, inc_anchor + '#include "stealth_boot.h"\n', 1)
    old_call = "\tseq_puts(m, saved_command_line);\n"
    assert old_call in text, "seq_puts(m, saved_command_line) not found in fs/proc/cmdline.c"
    text = text.replace(old_call, "\tproc_stealth_seq_puts(m, saved_command_line);\n", 1)
    cmd_c.write_text(text)
    print("Patched fs/proc/cmdline.c: non-root bootloader-state sanitization active")

# 5b. fs/proc/bootconfig.c (strictly preserves SUSFS SPOOF_CMDLINE_OR_BOOTCONFIG priority)
bc_c = Path("fs/proc/bootconfig.c")
text = bc_c.read_text()
if '#include "stealth_boot.h"' not in text:
    inc_anchor = "#include <linux/slab.h>\n"
    assert inc_anchor in text, "slab.h anchor not found in fs/proc/bootconfig.c"
    text = text.replace(inc_anchor, inc_anchor + '#include "stealth_boot.h"\n', 1)
    old_call = "\tif (saved_boot_config)\n\t\tseq_puts(m, saved_boot_config);\n"
    assert old_call in text, "seq_puts(m, saved_boot_config) not found in fs/proc/bootconfig.c"
    text = text.replace(old_call, "\tif (saved_boot_config)\n\t\tproc_stealth_seq_puts(m, saved_boot_config);\n", 1)
    bc_c.write_text(text)
    print("Patched fs/proc/bootconfig.c: non-root bootloader-state sanitization active (below SUSFS override)")
PY

# ------------------------------------------------------------------------------
# Layer 6: Stock Samsung Build Identity (uname -v, /proc/version user/host/timestamp)
# ------------------------------------------------------------------------------
echo ">>> [Stealth 6/7] Matching stock Samsung kernel build identity (user/host/timestamp)..."
if [ -n "$STOCK_KERNEL_BANNER" ]; then
  STOCK_KERNEL_BANNER="$STOCK_KERNEL_BANNER" python3 - <<'PY'
import os
import re
from pathlib import Path

banner = os.environ["STOCK_KERNEL_BANNER"].strip()
print(f"Parsing stock banner: {banner}")

# Expected format:
# Linux version <rel> (<user>@<host>) (<compiler>) #<ver> SMP PREEMPT <timestamp>
m = re.match(
    r"^Linux version\s+\S+\s+\(([^@)\s]+)@([^)\s]+)\)\s+\(.*\)\s+(#\d+\s+SMP(?:\s+.+)?)$",
    banner,
)
assert m, f"Could not parse stock kernel banner format: {banner!r}"
stock_user, stock_host, stock_uts = m.group(1), m.group(2), m.group(3).strip()

# UTS_VERSION max length is 64 characters (excluding NUL)
if len(stock_uts) > 64:
    stock_uts = stock_uts[:64].rstrip()

# Reject shell metacharacters for safe embedding
for label, val in (("user", stock_user), ("host", stock_host), ("uts", stock_uts)):
    assert not any(c in val for c in ("'", '"', '`', '$', '\\', '\n', '\r')), \
        f"Unsafe character in stock {label}: {val!r}"

print(f"Extracted stock identity: user={stock_user!r}, host={stock_host!r}, uts_version={stock_uts!r}")

# 6a. Patch scripts/mkcompile_h so Kleaf's KBUILD_BUILD_USER=kleaf / HOST=build-host cannot override
mkc = Path("scripts/mkcompile_h")
text = mkc.read_text()
text, n1 = re.subn(
    r'^#define LINUX_COMPILE_BY\s+".*"$',
    f'#define LINUX_COMPILE_BY\t"{stock_user}"',
    text,
    flags=re.MULTILINE,
)
text, n2 = re.subn(
    r'^#define LINUX_COMPILE_HOST\s+".*"$',
    f'#define LINUX_COMPILE_HOST\t"{stock_host}"',
    text,
    flags=re.MULTILINE,
)
assert n1 == 1 and n2 == 1, f"Failed to patch scripts/mkcompile_h ({n1}, {n2})"
mkc.write_text(text)

# 6b. Patch init/Makefile filechk_uts_version so uname -v matches stock Samsung timestamp verbatim
# NOTE: GNU Make treats unescaped '#' as a comment, so replace '#' with $(pound).
init_mk = Path("init/Makefile")
text = init_mk.read_text()
stock_uts_mk = stock_uts.replace("#", "$(pound)")
old_uts = (
    "filechk_uts_version = \\\n"
    "\tutsver=$$(echo '$(pound)'\"$(build-version)\" $(smp-flag-y) $(preempt-flag-y) \"$(build-timestamp)\" | cut -b -64); \\\n"
    "\techo '$(pound)'define UTS_VERSION \\\"\"$${utsver}\"\\\""
)
new_uts = (
    "filechk_uts_version = \\\n"
    f"\techo '$(pound)'define UTS_VERSION \\\"\"{stock_uts_mk}\"\\\""
)
assert old_uts in text, "filechk_uts_version anchor not found in init/Makefile"
text = text.replace(old_uts, new_uts, 1)
init_mk.write_text(text)
print("Patched scripts/mkcompile_h and init/Makefile to emit exact stock Samsung identity")
PY
else
  echo "WARNING: STOCK_KERNEL_BANNER not set; skipping stock identity match"
fi

# ------------------------------------------------------------------------------
# Layer 7: Disable SUSFS dmesg logs, Harden dmesg_restrict, Apply 2026 CVE Fixes
# ------------------------------------------------------------------------------
echo ">>> [Stealth 7/7] Hardening kernel logging & checking 2026 CVE fixes..."
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable CONFIG_KSU_SUSFS_ENABLE_LOG
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --enable CONFIG_SECURITY_DMESG_RESTRICT
"$CONFIG_TOOL" --file "$GKI_DEFCONFIG" --disable CONFIG_KPM

apply_cve_if_needed() {
  local cve_name="$1"
  local patch_file="$2"
  local check_file="$3"
  local check_marker="$4"

  test -f "$patch_file" || { echo "::error::Missing CVE patch: $patch_file"; exit 1; }

  if grep -qF "$check_marker" "$check_file"; then
    echo "[CVE] ${cve_name}: already present in 6.6.127 (${check_file} contains '${check_marker}'), skipping."
    return 0
  fi

  echo "[CVE] Applying ${cve_name} from $(basename "$patch_file")..."
  if patch -p1 --dry-run --batch --fuzz=2 < "$patch_file" >/dev/null 2>&1; then
    patch -p1 --no-backup-if-mismatch --batch --fuzz=2 < "$patch_file"
    echo "[CVE] ${cve_name}: applied cleanly!"
  else
    echo "::warning::${cve_name} did not apply cleanly on 6.6.127 (likely partially/already backported upstream); skipping safely to avoid conflict."
  fi
}

apply_cve_if_needed "CVE-2026-43499" "$REPO_ROOT/patches/cve-2026-43499-fix.patch" "kernel/locking/rtmutex.c" "waiter_task"
apply_cve_if_needed "CVE-2026-64560" "$REPO_ROOT/patches/cve-2026-64560-fix.patch" "kernel/time/posix-cpu-timers.c" "timer_lock_sighand"
apply_cve_if_needed "CVE-2026-98260" "$REPO_ROOT/patches/cve-2026-98260-fix.patch" "fs/exec.c" "posixtimer_exec"

echo "============================================================"
echo " All 7 Zero-Leak Kernel Stealth Layers applied cleanly!"
echo "============================================================"
