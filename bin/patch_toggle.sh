#!/system/bin/sh
BINDIR="$(dirname "$0")"
MODDIR="$(dirname "$BINDIR")"
. "$MODDIR/common.sh"

TARGET="$1"
case "$TARGET" in stock|pps33|pps55) ;; *) echo "usage: $0 stock|pps33|pps55"; exit 2 ;; esac
runtime_assets_ok=0
runtime_patch_assets_compatible && runtime_assets_ok=1
[ "$TARGET" = "stock" ] || [ "$runtime_assets_ok" = "1" ] || { echo "[!] Bundled DTBO patcher/template integrity check failed."; exit 10; }

LOCK_DIR="$STATE_DIR/toggle.lock"
WORK_DIR="/data/local/tmp/PJX110_PPS_DYNAMIC_PATCH_$$"
WORK_CREATED=0
PATCHER="$MODDIR/bin/dtbo-profile-patcher"
TEMPLATE="$MODDIR/templates/pps33-template.dtbo"

acquire_lock() {
  acquire_dtbo_lock "$LOCK_DIR" || { echo "[!] Another DTBO operation is active."; return 1; }
}

cleanup() {
  [ "$WORK_CREATED" != "1" ] || rm -rf "$WORK_DIR" 2>/dev/null
  release_dtbo_lock "$LOCK_DIR"
}

device_ok || { echo "[!] Not PJX110/corvette."; exit 10; }
[ "$TARGET" = "stock" ] || pps_driver_compatible >/dev/null || { echo "[!] PPS driver ABI marker is missing or unsupported."; exit 10; }
trusted_slot_conflict && { echo "[!] Trusted slot sources disagree."; exit 11; }
trusted_slot="$(trusted_slot_suffix)"
[ -n "$trusted_slot" ] || { echo "[!] No trusted kernel/bootloader slot source."; exit 12; }
slot="$(slot_suffix)"
[ -n "$slot" ] || { echo "[!] Cannot determine active slot."; exit 12; }
[ "$slot" = "$trusted_slot" ] || { echo "[!] Selected slot is not trusted."; exit 12; }
dynamic_manifest_valid "$slot" || { echo "[!] Valid dynamic manifest not found."; exit 13; }
[ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
  echo "[!] Patch Mode is not active. Full Partition Mode cannot use this command."
  exit 14
}
block="$(find_dtbo_block_for_slot "$slot")" || { echo "[!] Active DTBO block not found."; exit 15; }
cur="$(block_hash "$block")" || exit 15
CURRENT="$(dynamic_profile_for_hash "$slot" "$cur")"
[ "$CURRENT" != "unknown" ] || { echo "[!] Current hash does not match Patch Mode manifest."; exit 16; }
[ "$CURRENT" != "$TARGET" ] || { echo "[+] Already on requested profile."; exit 0; }

acquire_lock || exit 9
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir "$WORK_DIR" || exit 9
WORK_CREATED=1
chmod 0700 "$WORK_DIR" || exit 9

# Re-read after taking the lock.  Without this check a second writer (or an
# external recovery tool) could change the partition between the first probe
# and our write, causing us to write a profile selected from stale state.
dynamic_manifest_valid "$slot" && [ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
  echo "[!] Patch Mode manifest changed while waiting for the operation lock."
  exit 16
}
locked_cur="$(block_hash "$block")" || { echo "[!] Failed to re-read DTBO after locking."; exit 16; }
[ "$locked_cur" = "$cur" ] || {
  echo "[!] DTBO changed while waiting for the operation lock; refusing write."
  exit 16
}
locked_profile="$(dynamic_profile_for_hash "$slot" "$locked_cur")"
[ "$locked_profile" = "$CURRENT" ] || {
  echo "[!] Patch Mode endpoint mapping changed while waiting for the operation lock."
  exit 16
}

stock_sha="$(dynamic_sha_for_profile "$slot" stock)"
pps33_sha="$(dynamic_sha_for_profile "$slot" pps33)"
pps55_sha="$(dynamic_sha_for_profile "$slot" pps55)"
stock_img="$(dynamic_image_for_profile "$slot" stock)"
if [ "$TARGET" = "stock" ]; then
  stock_img="$(dynamic_stock_image_for_recovery "$slot")" || {
    echo "[!] No exact registered stock image is available in either backup location."
    exit 17
  }
else
  dynamic_assets_valid "$slot" patch || {
    echo "[!] Primary Patch Mode assets are incomplete; only stock restoration is allowed."
    exit 17
  }
fi
[ -f "$stock_img" ] && [ "$(hash_file "$stock_img")" = "$stock_sha" ] || {
  echo "[!] Exact stock backup is missing or corrupted."
  exit 17
}
if [ "$runtime_assets_ok" = "1" ]; then
  verify_dtbo_profile "$stock_img" stock || {
    echo "[!] Stock backup structure verification failed."
    exit 17
  }
else
  echo "[!] Patcher/template integrity is unavailable; proceeding with hash-pinned stock restore only."
fi

if [ "$runtime_assets_ok" = "1" ]; then
  prepare_rescue_bundle "$slot" "$stock_img" "$stock_sha" || {
    if [ "$TARGET" != "stock" ]; then
      echo "[!] Independent Recovery rescue bundle creation/verification failed."
      echo "[!] Refusing DTBO write. No partition was modified."
      exit 17
    fi
    echo "[!] Rescue package is unavailable; retaining exact hash/AVB-verified stock restoration."
  }
else
  if rescue_bundle_valid "$slot" "$stock_sha"; then
    :
  elif [ "$TARGET" = "stock" ] && [ -f "$stock_img" ] && [ "$(hash_file "$stock_img")" = "$stock_sha" ] && dtbo_avb_footer_valid "$stock_img"; then
    echo "[!] Using the exact registered stock image as the emergency restore path."
  else
    echo "[!] Patcher is unavailable and no intact independent stock rescue bundle exists."
    echo "[!] Refusing DTBO write. No partition was modified."
    exit 17
  fi
fi

if [ "$TARGET" = "stock" ]; then
  target_img="$stock_img"
  target_sha="$stock_sha"
else
  target_img="$WORK_DIR/$TARGET.img"
  output="$("$PATCHER" build "$stock_img" "$TEMPLATE" "$TARGET" "$target_img" 2>&1)" || {
    echo "$output"
    echo "[!] Dynamic DTBO reconstruction failed."
    exit 18
  }
  target_sha="$(printf '%s\n' "$output" | sed -n 's/^output_sha256=//p' | head -n 1)"
  is_sha256 "$target_sha" || { echo "[!] Patcher returned an invalid target hash."; exit 18; }
  [ "$(hash_file "$target_img")" = "$target_sha" ] || { echo "[!] Target hash verification failed."; exit 18; }
  verify_dtbo_profile "$target_img" "$TARGET" || { echo "[!] Target profile verification failed."; exit 18; }
  registered_sha="$(dynamic_sha_for_profile "$slot" "$TARGET")"
  [ -z "$registered_sha" ] || [ "$registered_sha" = "$target_sha" ] || {
    echo "[!] Rebuilt PPS hash differs from the registered dry-run endpoint."
    echo "[!] Refusing PPS write; restore stock before re-registering compatibility."
    exit 18
  }
fi

echo "[*] Mode: dynamic Patch Mode"
echo "[*] Current profile: $CURRENT"
echo "[*] Requested profile: $TARGET"
echo "[+] Reconstructed target SHA256: $target_sha"

case "$TARGET" in
  pps33) pps33_sha="$target_sha" ;;
  pps55) pps55_sha="$target_sha" ;;
esac
prewrite_cur="$(block_hash "$block")" || { echo "[!] Failed to re-read DTBO before write."; exit 16; }
[ "$prewrite_cur" = "$cur" ] || {
  echo "[!] DTBO changed during target reconstruction; refusing write."
  exit 16
}
dynamic_manifest_valid "$slot" && [ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
  echo "[!] Patch Mode manifest changed during target reconstruction; refusing write."
  exit 16
}
write_dynamic_manifest "$slot" patch "$stock_sha" "$pps33_sha" "$pps55_sha" || {
  echo "[!] Refusing DTBO write because Patch Mode manifest update failed."
  exit 19
}
sync

record_rescue_write_intent "$slot" "$stock_sha" "$target_sha" || {
  if [ "$TARGET" != "stock" ]; then
    echo "[!] Failed to persist the recovery write-intent journal."
    echo "[!] Refusing DTBO write. No partition was modified."
    exit 19
  fi
  echo "[!] Recovery journal unavailable; proceeding with exact stock restoration only."
}

if [ "$TARGET" = "stock" ]; then
  write_verify "$target_img" "$target_sha" "$block" "$target_img" "$target_sha" "$slot" "$cur" || exit 20
else
  write_verify "$target_img" "$target_sha" "$block" "$stock_img" "$stock_sha" "$slot" "$cur" || exit 20
fi

if [ "$TARGET" = "stock" ]; then
  clear_rescue_write_intent "$slot" "$stock_sha" || {
    echo "[!] Stock is restored, but the stale rescue journal could not be cleared."
  }
fi

echo "[+] Patch Mode profile '$TARGET' written and readback verified."
if rescue_bundle_valid "$slot" "$stock_sha"; then
  echo "[+] Independent Recovery rescue snapshot: $RESCUE_DIR/restore_stock.sh"
fi
echo "[+] Reboot is required."
