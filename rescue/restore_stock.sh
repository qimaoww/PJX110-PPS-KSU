#!/system/bin/sh

# Standalone recovery-side DTBO restore tool. This file is copied outside the
# KernelSU module before any modified DTBO is written, so it remains available
# if the module directory is disabled or deleted.

set -u

ACTION="${1:-check}"
REQUESTED_SLOT="${2:-last}"
case "$ACTION" in check|restore) ;; *) echo "usage: $0 check|restore [last|auto|a|b]"; exit 2 ;; esac

RESCUE_ROOT="${0%/*}"
[ -n "$RESCUE_ROOT" ] || RESCUE_ROOT="."
LOCK_DIR="/tmp/PJX110_PPS_RESCUE.lock"
if [ -d /data/adb/PJX110_PPS_KSU ] && [ -w /data/adb/PJX110_PPS_KSU ]; then
  LOCK_DIR="/data/adb/PJX110_PPS_KSU/toggle.lock"
fi

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v busybox >/dev/null 2>&1; then
    busybox sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

is_sha256() {
  case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "$(printf '%s' "$1" | wc -c | tr -d ' ')" -eq 64 ]
}

normalize_slot() {
  value="$(printf '%s' "$1" | sed "s/[[:space:]\"']//g")"
  case "$value" in _a|a|A|0) echo _a ;; _b|b|B|1) echo _b ;; *) return 1 ;; esac
}

bootconfig_slot() {
  [ -r /proc/bootconfig ] || return 1
  value="$(awk '$1 == "androidboot.slot_suffix" { sub(/^[^=]*=[[:space:]]*/, "", $0); gsub(/[[:space:]\"]/, "", $0); print; exit }' /proc/bootconfig 2>/dev/null)"
  normalize_slot "$value"
}

cmdline_slot() {
  [ -r /proc/cmdline ] || return 1
  value="$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | awk -F= '$1 == "androidboot.slot_suffix" { print substr($0, index($0, "=") + 1); exit }')"
  normalize_slot "$value"
}

bootctl_slot() {
  command -v bootctl >/dev/null 2>&1 || return 1
  normalize_slot "$(bootctl get-current-slot 2>/dev/null | head -n 1)"
}

auto_slot() {
  first=""
  for fn in bootconfig_slot cmdline_slot bootctl_slot; do
    value="$($fn 2>/dev/null)"
    case "$value" in _a|_b) ;; *) continue ;; esac
    if [ -z "$first" ]; then
      first="$value"
    elif [ "$value" != "$first" ]; then
      echo "[!] Trusted slot sources disagree; specify a or b explicitly." >&2
      return 1
    fi
  done
  [ -n "$first" ] || {
    echo "[!] Recovery exposes no trusted slot source; specify a or b explicitly." >&2
    return 1
  }
  echo "$first"
}

manifest_value() {
  file="$1"; key="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file" 2>/dev/null
}

manifest_shape_valid() {
  file="$1"
  [ -r "$file" ] || return 1
  awk -F= '
    NF != 2 { bad = 1; exit }
    $1 !~ /^(format|slot_suffix|stock_sha|stock_size|patcher_sha)$/ { bad = 1; exit }
    seen[$1]++ { bad = 1; exit }
    END {
      if (bad || seen["format"] != 1 || seen["slot_suffix"] != 1 ||
          seen["stock_sha"] != 1 || seen["stock_size"] != 1 ||
          seen["patcher_sha"] != 1) exit 1
    }
  ' "$file" >/dev/null 2>&1
}

last_written_slot() {
  journal="$RESCUE_ROOT/last_write"
  [ -r "$journal" ] || return 1
  awk -F= '
    NF != 2 { bad = 1; exit }
    $1 !~ /^(format|slot_suffix|stock_sha|target_sha)$/ { bad = 1; exit }
    seen[$1]++ { bad = 1; exit }
    END {
      if (bad || seen["format"] != 1 || seen["slot_suffix"] != 1 ||
          seen["stock_sha"] != 1 || seen["target_sha"] != 1) exit 1
    }
  ' "$journal" >/dev/null 2>&1 || return 1
  [ "$(manifest_value "$journal" format)" = 1 ] || return 1
  slot="$(normalize_slot "$(manifest_value "$journal" slot_suffix)")" || return 1
  stock_sha="$(manifest_value "$journal" stock_sha)"
  target_sha="$(manifest_value "$journal" target_sha)"
  is_sha256 "$stock_sha" && is_sha256 "$target_sha" || return 1
  echo "$slot"
}

clear_matching_journal() {
  [ -r "$RESCUE_ROOT/last_write" ] || return 0
  [ "$(last_written_slot)" = "$SLOT" ] || return 0
  [ "$(manifest_value "$RESCUE_ROOT/last_write" stock_sha)" = "$STOCK_SHA" ] || return 0
  rm -f "$RESCUE_ROOT/last_write" 2>/dev/null || return 1
}

case "$REQUESTED_SLOT" in
  last)
    SLOT="$(last_written_slot)" || {
      echo "[!] Last-write journal is missing or invalid; refusing to guess a target slot."
      echo "[!] Use check a/b only after confirming which physical DTBO slot was modified."
      exit 10
    }
    ;;
  auto) SLOT="$(auto_slot)" || exit 10 ;;
  a|A|_a|0|b|B|_b|1) SLOT="$(normalize_slot "$REQUESTED_SLOT")" || exit 10 ;;
  *) echo "[!] Invalid slot '$REQUESTED_SLOT'; use last, auto, a, or b."; exit 2 ;;
esac

case "$SLOT" in _a) SLOT_KEY=a ;; _b) SLOT_KEY=b ;; *) exit 10 ;; esac
SLOT_DIR="$RESCUE_ROOT/slot_$SLOT_KEY"
ACTIVE_FILE="$SLOT_DIR/active"
[ -r "$ACTIVE_FILE" ] || { echo "[!] No rescue snapshot registered for slot $SLOT_KEY."; exit 11; }
ACTIVE_SHA="$(tr -d '\r\n ' < "$ACTIVE_FILE" 2>/dev/null)"
is_sha256 "$ACTIVE_SHA" || { echo "[!] Rescue active pointer is invalid."; exit 11; }

GEN_DIR="$SLOT_DIR/$ACTIVE_SHA"
MANIFEST="$GEN_DIR/manifest"
STOCK_IMG="$GEN_DIR/stock.img"
PATCHER="$GEN_DIR/dtbo-profile-patcher"
manifest_shape_valid "$MANIFEST" || { echo "[!] Rescue manifest is missing or malformed."; exit 12; }
[ "$(manifest_value "$MANIFEST" format)" = 1 ] || { echo "[!] Unsupported rescue format."; exit 12; }
[ "$(manifest_value "$MANIFEST" slot_suffix)" = "$SLOT" ] || { echo "[!] Rescue manifest slot mismatch."; exit 12; }
STOCK_SHA="$(manifest_value "$MANIFEST" stock_sha)"
STOCK_SIZE="$(manifest_value "$MANIFEST" stock_size)"
PATCHER_SHA="$(manifest_value "$MANIFEST" patcher_sha)"
is_sha256 "$STOCK_SHA" && is_sha256 "$PATCHER_SHA" || { echo "[!] Rescue manifest hashes are invalid."; exit 12; }
[ "$STOCK_SHA" = "$ACTIVE_SHA" ] || { echo "[!] Rescue generation/hash mismatch."; exit 12; }
if [ "$REQUESTED_SLOT" = last ] && [ -r "$RESCUE_ROOT/last_write" ]; then
  JOURNAL_STOCK_SHA="$(manifest_value "$RESCUE_ROOT/last_write" stock_sha)"
  [ "$JOURNAL_STOCK_SHA" = "$STOCK_SHA" ] || {
    echo "[!] Last-write journal belongs to an older stock generation."
    echo "[!] Re-run with the explicitly verified slot a or b; refusing automatic restore."
    exit 12
  }
fi
case "$STOCK_SIZE" in ''|*[!0-9]*) echo "[!] Rescue image size is invalid."; exit 12 ;; esac
[ -f "$STOCK_IMG" ] || { echo "[!] Exact stock rescue image is missing."; exit 13; }
[ "$(wc -c < "$STOCK_IMG" 2>/dev/null | tr -d ' ')" = "$STOCK_SIZE" ] || { echo "[!] Rescue image size verification failed."; exit 13; }
[ "$(hash_file "$STOCK_IMG")" = "$STOCK_SHA" ] || { echo "[!] Rescue image SHA256 verification failed."; exit 13; }

MAGIC="$(tail -c 64 "$STOCK_IMG" 2>/dev/null | od -An -tx1 -N4 2>/dev/null | tr -d ' \r\n' | tr '[:upper:]' '[:lower:]')"
[ "$MAGIC" = 41564266 ] || { echo "[!] Rescue image has no valid AVBf footer; refusing write."; exit 14; }

if [ -f "$PATCHER" ] && [ "$(hash_file "$PATCHER")" = "$PATCHER_SHA" ]; then
  VERIFY_BIN="/tmp/PJX110-dtbo-profile-patcher.$$"
  cp -f "$PATCHER" "$VERIFY_BIN" || { echo "[!] Cannot stage DTBO verifier."; exit 14; }
  chmod 0700 "$VERIFY_BIN" 2>/dev/null
  VERIFY_OUTPUT="$($VERIFY_BIN verify "$STOCK_IMG" 2>&1)"
  VERIFY_RC=$?
  rm -f "$VERIFY_BIN"
  [ "$VERIFY_RC" -eq 0 ] && printf '%s\n' "$VERIFY_OUTPUT" | grep -q '^profile=stock$' || {
    echo "[!] Full DTBO/VBMeta/AVB verification failed; refusing write."
    exit 14
  }
  VERIFY_MODE="full DTBO/VBMeta/AVB + SHA256"
else
  # The snapshot was created only after full verification. In a damaged rescue
  # environment, the immutable generation name, strict manifest, exact SHA256,
  # image size and raw AVBf check form the permitted stock-only fallback.
  VERIFY_MODE="registered exact-stock SHA256 + AVBf fallback (verifier unavailable)"
fi

find_block() {
  for path in \
    "/dev/block/by-name/dtbo$SLOT" \
    "/dev/block/bootdevice/by-name/dtbo$SLOT" \
    "/dev/block/mapper/dtbo$SLOT"
  do
    [ -e "$path" ] || continue
    readlink -f "$path" 2>/dev/null || echo "$path"
    return 0
  done
  return 1
}

BLOCK="$(find_block)" || { echo "[!] dtbo$SLOT block device not found."; exit 15; }
[ -b "$BLOCK" ] || { echo "[!] Fixed DTBO target is not a block device."; exit 15; }
BLOCK_SIZE=""
if command -v blockdev >/dev/null 2>&1; then
  BLOCK_SIZE="$(blockdev --getsize64 "$BLOCK" 2>/dev/null)"
fi
case "$BLOCK_SIZE" in
  ''|*[!0-9]*)
    BLOCK_NAME="${BLOCK##*/}"
    SECTORS="$(cat "/sys/class/block/$BLOCK_NAME/size" 2>/dev/null)"
    case "$SECTORS" in ''|*[!0-9]*) echo "[!] Cannot determine DTBO partition size."; exit 15 ;; esac
    [ "$SECTORS" -gt 0 ] && [ "$SECTORS" -le 2147483647 ] || exit 15
    BLOCK_SIZE="$((SECTORS * 512))"
    ;;
esac
[ "$BLOCK_SIZE" = "$STOCK_SIZE" ] || {
  echo "[!] Rescue image/partition size mismatch: image=$STOCK_SIZE block=$BLOCK_SIZE"
  exit 15
}

CURRENT_SHA="$(hash_file "$BLOCK")" || { echo "[!] Cannot hash target DTBO partition."; exit 16; }
is_sha256 "$CURRENT_SHA" || { echo "[!] Invalid DTBO partition readback hash."; exit 16; }
echo "[*] Rescue root: $RESCUE_ROOT"
echo "[*] Target slot: $SLOT_KEY ($BLOCK)"
echo "[*] Current SHA256: $CURRENT_SHA"
echo "[*] Stock SHA256:   $STOCK_SHA"
echo "[*] Verification:   $VERIFY_MODE"

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    case "$old_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$old_pid" 2>/dev/null && return 1
    mkdir "$LOCK_DIR/.reclaim" 2>/dev/null || return 1
    check_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ "$check_pid" != "$old_pid" ] || kill -0 "$check_pid" 2>/dev/null; then
      rmdir "$LOCK_DIR/.reclaim" 2>/dev/null
      return 1
    fi
    rm -f "$LOCK_DIR/pid" || return 1
    rmdir "$LOCK_DIR/.reclaim" "$LOCK_DIR" || return 1
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid" || return 1
}
if [ "$ACTION" = restore ]; then
  acquire_lock || { echo "[!] Another DTBO operation is active, or the lock cannot be verified."; exit 17; }
  cleanup() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null || true
  }
  trap 'cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  [ "$(hash_file "$BLOCK")" = "$CURRENT_SHA" ] || {
    echo "[!] DTBO changed while preparing rescue; refusing restore."
    exit 17
  }
fi
if [ "$CURRENT_SHA" = "$STOCK_SHA" ]; then
  echo "[+] Slot $SLOT_KEY already contains the registered stock DTBO."
  if [ "$ACTION" = restore ]; then
    clear_matching_journal || true
    sync
  fi
  exit 0
fi
[ "$ACTION" = restore ] || {
  echo "[+] Rescue preflight passed. Run: sh '$0' restore $SLOT_KEY"
  exit 0
}

echo "[*] Restoring exact registered stock DTBO to slot $SLOT_KEY..."
[ "$(find_block)" = "$BLOCK" ] && [ -b "$BLOCK" ] || {
  echo "[!] Fixed DTBO target changed during validation; refusing restore."
  exit 18
}
[ "$(hash_file "$STOCK_IMG")" = "$STOCK_SHA" ] || { echo "[!] Stock image changed before restore."; exit 18; }
dd if="$STOCK_IMG" of="$BLOCK" bs=4194304 2>/dev/null || { echo "[!] DTBO restore write failed."; exit 18; }
sync
READBACK_SHA="$(hash_file "$BLOCK")" || READBACK_SHA=""
[ "$READBACK_SHA" = "$STOCK_SHA" ] || {
  echo "[!] CRITICAL: DTBO readback verification failed: $READBACK_SHA"
  exit 19
}

clear_matching_journal || true
sync
echo "[+] Stock DTBO restored and full-partition SHA256 readback verified."
echo "[+] Reboot the phone. Do not flash another DTBO before testing boot."
exit 0
