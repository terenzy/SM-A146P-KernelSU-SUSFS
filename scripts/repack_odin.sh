#!/usr/bin/env bash
# ==============================================================================
# Repack script for Samsung Galaxy A14 5G (SM-A146P / Binary L A146PXXULEZJ3)
# Produces:
#   1. boot_and_vbmeta.tar  - Odin AP first-time flash (boot.img + vbmeta.img flags=3)
#   2. boot.tar             - Odin AP subsequent kernel update (boot.img only)
#   3. vbmeta_disabled.tar  - Stock vbmeta.img patched with AVB flags=3 at offset 120
#   4. AnyKernel3.zip       - Recovery backup flasher (WildKernels/AnyKernel3 gki-2.0)
# ==============================================================================
set -euo pipefail

KERNEL_IMAGE="${KERNEL_IMAGE:?KERNEL_IMAGE must be set (path to built uncompressed Image)}"
KERNEL_IMAGE_GZ="${KERNEL_IMAGE_GZ:-}"
STOCK_BOOT_LZ4="${STOCK_BOOT_LZ4:?STOCK_BOOT_LZ4 must be set (path to stock boot.img.lz4)}"
STOCK_VBMETA_LZ4="${STOCK_VBMETA_LZ4:?STOCK_VBMETA_LZ4 must be set (path to stock vbmeta.img.lz4)}"
MAGISKBOOT="${MAGISKBOOT:?MAGISKBOOT must be set (path to magiskboot-x86_64 binary)}"
ANYKERNEL3_DIR="${ANYKERNEL3_DIR:?ANYKERNEL3_DIR must be set (path to AnyKernel3 repo)}"
OUT_DIR="${OUT_DIR:?OUT_DIR must be set (output directory for deliverables)}"

for req in "$KERNEL_IMAGE" "$STOCK_BOOT_LZ4" "$STOCK_VBMETA_LZ4" "$MAGISKBOOT"; do
  test -f "$req" || { echo "ERROR: Required file not found: $req" >&2; exit 1; }
done
test -d "$ANYKERNEL3_DIR" || { echo "ERROR: AnyKernel3 directory not found: $ANYKERNEL3_DIR" >&2; exit 1; }
chmod +x "$MAGISKBOOT"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

STAGE_DIR="$WORK_DIR/stage"
REPACK_DIR="$WORK_DIR/repack"
VERIFY_DIR="$WORK_DIR/verify"
AK3_WORK="$WORK_DIR/AnyKernel3"

mkdir -p "$OUT_DIR" "$STAGE_DIR" "$REPACK_DIR" "$VERIFY_DIR"

# ------------------------------------------------------------------------------
# 1. Decompress stock boot.img.lz4 and vbmeta.img.lz4
# ------------------------------------------------------------------------------
echo ">>> [1/5] Decompressing stock boot.img.lz4 and vbmeta.img.lz4..."
unlz4 -f "$STOCK_BOOT_LZ4" "$WORK_DIR/stock_boot.img"
unlz4 -f "$STOCK_VBMETA_LZ4" "$WORK_DIR/stock_vbmeta.img"

STOCK_BOOT_SIZE=$(stat -c%s "$WORK_DIR/stock_boot.img")
STOCK_VBMETA_SIZE=$(stat -c%s "$WORK_DIR/stock_vbmeta.img")
echo "Stock boot.img size:   ${STOCK_BOOT_SIZE} bytes"
echo "Stock vbmeta.img size: ${STOCK_VBMETA_SIZE} bytes"

# ------------------------------------------------------------------------------
# 2. Repack boot.img using magiskboot (preserves header v4, gzip fmt, AVB/Samsung metadata)
# ------------------------------------------------------------------------------
echo ">>> [2/5] Repacking boot.img with newly built kernel Image..."
(
  cd "$REPACK_DIR"
  "$MAGISKBOOT" unpack "$WORK_DIR/stock_boot.img"
  cp -f "$KERNEL_IMAGE" kernel
  "$MAGISKBOOT" repack "$WORK_DIR/stock_boot.img" "$STAGE_DIR/boot.img"
)

NEW_BOOT_SIZE=$(stat -c%s "$STAGE_DIR/boot.img")
echo "Repacked boot.img size: ${NEW_BOOT_SIZE} bytes"
if [ "$NEW_BOOT_SIZE" -gt "$STOCK_BOOT_SIZE" ]; then
  echo "ERROR: Repacked boot.img (${NEW_BOOT_SIZE}) exceeds stock boot.img partition size (${STOCK_BOOT_SIZE})!" >&2
  exit 1
fi

echo "Verifying repacked boot.img..."
(
  cd "$VERIFY_DIR"
  "$MAGISKBOOT" unpack "$STAGE_DIR/boot.img"
  echo "Kernel banner inside repacked boot.img:"
  strings kernel | grep -m 2 -E "^Linux version 6\.6" || true
)

# ------------------------------------------------------------------------------
# 3. Patch stock vbmeta.img (set AVB flags = 3 at offset 120, big-endian uint32)
#    flags=3: AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED (1) |
#             AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED (2)
# ------------------------------------------------------------------------------
echo ">>> [3/5] Patching stock vbmeta.img flags=3 at offset 120..."
cp -f "$WORK_DIR/stock_vbmeta.img" "$STAGE_DIR/vbmeta.img"

python3 - "$STAGE_DIR/vbmeta.img" "$STOCK_VBMETA_SIZE" <<'PY'
import os
import struct
import sys

path = sys.argv[1]
expected_size = int(sys.argv[2])

with open(path, "r+b") as f:
    magic = f.read(4)
    assert magic == b"AVB0", f"Invalid vbmeta magic: {magic!r}"
    f.seek(120)
    old_flags = struct.unpack(">I", f.read(4))[0]
    f.seek(120)
    f.write(struct.pack(">I", 3))
    f.flush()
    f.seek(120)
    raw = f.read(4)
    new_flags = struct.unpack(">I", raw)[0]
    assert new_flags == 3 and raw == b"\x00\x00\x00\x03", f"Unexpected flags bytes: {raw.hex()}"

actual_size = os.path.getsize(path)
assert actual_size == expected_size, f"Size changed: {actual_size} != {expected_size}"
print(f"Verified vbmeta.img: magic=AVB0, offset 120 flags {old_flags} -> {new_flags} (0x{raw.hex()}), size={actual_size} bytes")
PY

# ------------------------------------------------------------------------------
# 4. Pack Odin .tar archives (ustar format, flat entries at archive root)
# ------------------------------------------------------------------------------
echo ">>> [4/5] Building Odin AP .tar archives..."
tar -C "$STAGE_DIR" --format=ustar -cf "$OUT_DIR/boot_and_vbmeta.tar" boot.img vbmeta.img
tar -C "$STAGE_DIR" --format=ustar -cf "$OUT_DIR/boot.tar" boot.img
tar -C "$STAGE_DIR" --format=ustar -cf "$OUT_DIR/vbmeta_disabled.tar" vbmeta.img

for t in boot_and_vbmeta.tar boot.tar vbmeta_disabled.tar; do
  echo "--- Contents of $t ---"
  tar -tvf "$OUT_DIR/$t"
done

# ------------------------------------------------------------------------------
# 5. Pack AnyKernel3.zip (from WildKernels/AnyKernel3 branch gki-2.0)
# ------------------------------------------------------------------------------
echo ">>> [5/5] Building AnyKernel3.zip..."
cp -a "$ANYKERNEL3_DIR" "$AK3_WORK"
rm -rf "$AK3_WORK/.git" "$AK3_WORK/.github" "$AK3_WORK/README.md"

if [ -n "$KERNEL_IMAGE_GZ" ] && [ -f "$KERNEL_IMAGE_GZ" ]; then
  cp -f "$KERNEL_IMAGE_GZ" "$AK3_WORK/Image.gz"
else
  gzip -9c "$KERNEL_IMAGE" > "$AK3_WORK/Image.gz"
fi

sed -i 's/^kernel\.string=.*/kernel.string=SM-A146P Binary L (A146PXXULEZJ3) 6.6.127 KernelSU-Next + SUSFS/' "$AK3_WORK/anykernel.sh"

rm -f "$OUT_DIR/AnyKernel3.zip"
(
  cd "$AK3_WORK"
  zip -r -9 "$OUT_DIR/AnyKernel3.zip" .
)

# ------------------------------------------------------------------------------
# 6. Pack a146p_stealth_companion.zip (KernelSU Companion Module + ksu_susfs)
# ------------------------------------------------------------------------------
COMPANION_DIR="${COMPANION_DIR:-}"
KSU_SUSFS_BIN="${KSU_SUSFS_BIN:-}"
CHECKSUM_FILES=(boot_and_vbmeta.tar boot.tar vbmeta_disabled.tar AnyKernel3.zip)

if [ -n "$COMPANION_DIR" ] && [ -d "$COMPANION_DIR" ]; then
  echo ">>> [6/6] Building a146p_stealth_companion.zip..."
  COMP_WORK="$WORK_DIR/companion"
  cp -a "$COMPANION_DIR" "$COMP_WORK"
  mkdir -p "$COMP_WORK/bin"
  if [ -n "$KSU_SUSFS_BIN" ] && [ -f "$KSU_SUSFS_BIN" ]; then
    cp -f "$KSU_SUSFS_BIN" "$COMP_WORK/bin/ksu_susfs"
    chmod 0755 "$COMP_WORK/bin/ksu_susfs"
  else
    echo "ERROR: KSU_SUSFS_BIN must point to ksu_susfs_arm64 binary when COMPANION_DIR is set" >&2
    exit 1
  fi
  chmod 0755 "$COMP_WORK/customize.sh" "$COMP_WORK/service.sh" "$COMP_WORK/action.sh" "$COMP_WORK/uninstall.sh" "$COMP_WORK/bin/stealth_sync.sh"
  rm -f "$OUT_DIR/a146p_stealth_companion.zip"
  (
    cd "$COMP_WORK"
    zip -r -9 "$OUT_DIR/a146p_stealth_companion.zip" .
  )
  CHECKSUM_FILES+=(a146p_stealth_companion.zip)
fi

# Generate checksums
(
  cd "$OUT_DIR"
  sha256sum "${CHECKSUM_FILES[@]}" > SHA256SUMS.txt
)

echo "============================================================"
echo " Deliverables ready in $OUT_DIR:"
ls -lh "$OUT_DIR"
echo "------------------------------------------------------------"
cat "$OUT_DIR/SHA256SUMS.txt"
echo "============================================================"
