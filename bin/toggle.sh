#!/system/bin/sh
BINDIR="${0%/*}"
MODDIR="${BINDIR%/bin}"
. "$MODDIR/common.sh"

TARGET="${1:-}"
case "$TARGET" in
  stock|pps33|pps55) ;;
  *)
    echo "usage: $0 stock|pps33|pps55"
    exit 2
    ;;
esac

LOCK_DIR="$STATE_DIR/toggle.lock"

acquire_toggle_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    return 0
  fi
  old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  case "$old_pid" in ''|*[!0-9]*) old_pid="" ;; esac
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "[!] Another DTBO operation is already running (pid=$old_pid)."
    return 1
  fi
  echo "[*] Removing stale DTBO operation lock."
  rm -rf "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
}

release_toggle_lock() {
  owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  [ -z "$owner" ] || [ "$owner" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null
}

acquire_toggle_lock || exit 9
trap 'release_toggle_lock' EXIT INT TERM HUP

echo "========================================"
echo " Ace 3 Pro PPS profile switch"
echo " Target: $TARGET"
echo "========================================"

device_ok || { echo "[!] Not PJX110/corvette."; exit 10; }

if trusted_slot_conflict; then
  echo "[!] Trusted slot sources disagree; refusing DTBO write."
  exit 11
fi

slot="$(slot_suffix)"
[ -n "$slot" ] || { echo "[!] Cannot determine active slot."; exit 12; }
label="$(slot_label "$slot")"
block="$(find_dtbo_block_for_slot "$slot")" || { echo "[!] Slot-$label DTBO block not found."; exit 13; }

cur="$(block_hash "$block")" || { echo "[!] Failed to hash DTBO."; exit 14; }
family="$(dtbo_family_for_hash "$cur")"
CURRENT="$(detect_profile_for_hash "$cur")"

echo "[*] Active slot: $label (source: $(slot_source))"
echo "[*] Current SHA256: $cur"
echo "[*] DTBO image family: $(dtbo_family_label "$family")"
echo "[*] Current profile: $CURRENT"
echo "[*] Requested profile: $TARGET"

if [ "$CURRENT" = "unknown" ]; then
  echo "[!] Current DTBO is not one of this module's exact stock/33W/55W images."
  echo "[!] Refusing any write."
  exit 15
fi

if [ "$CURRENT" = "$TARGET" ]; then
  echo "[+] Already on requested profile; no write needed."
  exit 0
fi

stock="$(stock_image_for_family "$family")"
stock_sha="$(stock_sha_for_family "$family")"

# Save an external stock backup whenever the exact stock image is currently active.
if [ "$CURRENT" = "stock" ]; then
  backup_stock "$block" "$slot" "$stock_sha" || {
    echo "[!] Stock backup failed; refusing modified DTBO write."
    exit 16
  }
fi

target_img="$(profile_image_for_family "$family" "$TARGET")" || exit 17
target_sha="$(profile_sha_for_family "$family" "$TARGET")" || exit 17

case "$TARGET" in
  stock) echo "[*] Restoring exact slot-$label stock DTBO..." ;;
  pps33) echo "[*] Switching slot-$label to PPS 33W profile..." ;;
  pps55)
    echo "[*] Switching slot-$label to PPS 55W experimental profile..."
    echo "[!] 55W requires a charger/APDO and cable capable of the requested current."
    ;;
esac

if [ "$TARGET" = "stock" ]; then
  write_verify "$target_img" "$target_sha" "$block" "" "" || exit 18
else
  write_verify "$target_img" "$target_sha" "$block" "$stock" "$stock_sha" || exit 18
fi

echo "[+] Profile '$TARGET' written and readback verified."
echo "[+] Reboot is required."
exit 0
