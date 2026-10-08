#!/system/bin/sh
BINDIR="$(dirname "$0")"
MODDIR="$(dirname "$BINDIR")"
. "$MODDIR/common.sh"

LOCK_DIR="$STATE_DIR/toggle.lock"
WORK_DIR="/data/local/tmp/PJX110_PPS_PROMOTE_FULL_$$"
WORK_CREATED=0
PATCHER="$MODDIR/bin/dtbo-profile-patcher"
TEMPLATE="$MODDIR/templates/pps33-template.dtbo"

runtime_patch_assets_compatible || { echo "[!] Bundled DTBO patcher/template integrity check failed."; exit 10; }

cleanup() {
  [ "$WORK_CREATED" != "1" ] || rm -rf "$WORK_DIR" 2>/dev/null
  release_dtbo_lock "$LOCK_DIR"
}

device_ok || { echo "[!] Not PJX110/corvette."; exit 10; }
pps_driver_compatible >/dev/null || { echo "[!] PPS driver ABI marker is missing or unsupported."; exit 10; }
trusted_slot_conflict && { echo "[!] Trusted slot sources disagree."; exit 11; }
trusted_slot="$(trusted_slot_suffix)"
[ -n "$trusted_slot" ] || { echo "[!] No trusted kernel/bootloader slot source."; exit 12; }
slot="$(slot_suffix)"
[ -n "$slot" ] || { echo "[!] Cannot determine active slot."; exit 12; }
[ "$slot" = "$trusted_slot" ] || { echo "[!] Selected slot is not trusted."; exit 12; }
dynamic_manifest_valid "$slot" || { echo "[!] Valid dynamic manifest not found."; exit 13; }
[ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
  echo "[!] Only Patch Mode can be manually switched to Full Partition Mode."
  exit 14
}
block="$(find_dtbo_block_for_slot "$slot")" || exit 15
cur="$(block_hash "$block")" || exit 15
CURRENT="$(dynamic_profile_for_hash "$slot" "$cur")"
[ "$CURRENT" != "unknown" ] || { echo "[!] Current hash does not match Patch Mode manifest."; exit 16; }

acquire_dtbo_lock "$LOCK_DIR" || { echo "[!] Another DTBO operation is active."; exit 9; }
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir "$WORK_DIR" || exit 9
WORK_CREATED=1
chmod 0700 "$WORK_DIR" || exit 9

dynamic_manifest_valid "$slot" && [ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
  echo "[!] Patch Mode manifest changed while waiting for the operation lock."
  exit 16
}
locked_cur="$(block_hash "$block")" || { echo "[!] Failed to re-read DTBO after locking."; exit 16; }
[ "$locked_cur" = "$cur" ] || {
  echo "[!] DTBO changed while waiting for the operation lock; refusing promotion."
  exit 16
}
locked_profile="$(dynamic_profile_for_hash "$slot" "$locked_cur")"
[ "$locked_profile" = "$CURRENT" ] || {
  echo "[!] Patch Mode endpoint mapping changed while waiting for the operation lock."
  exit 16
}

stock_img="$(dynamic_image_for_profile "$slot" stock)"
stock_sha="$(dynamic_sha_for_profile "$slot" stock)"
[ -f "$stock_img" ] && [ "$(hash_file "$stock_img")" = "$stock_sha" ] || {
  echo "[!] Stock backup hash verification failed."
  exit 17
}
verify_dtbo_profile "$stock_img" stock || {
  echo "[!] Stock backup DTBO/AVB verification failed."
  exit 17
}
prepare_rescue_bundle "$slot" "$stock_img" "$stock_sha" || {
  echo "[!] Independent Recovery rescue bundle verification failed."
  echo "[!] Patch Mode remains active."
  exit 17
}

for profile in pps33 pps55; do
  temp="$WORK_DIR/$profile.img"
  output="$("$PATCHER" build "$stock_img" "$TEMPLATE" "$profile" "$temp" 2>&1)" || {
    echo "$output"
    echo "[!] Failed to build $profile full image."
    exit 18
  }
  generated_sha="$(printf '%s\n' "$output" | sed -n 's/^output_sha256=//p' | head -n 1)"
  is_sha256 "$generated_sha" && [ "$(hash_file "$temp")" = "$generated_sha" ] || {
    echo "[!] $profile full image hash verification failed."
    exit 18
  }
  verify_dtbo_profile "$temp" "$profile" || {
    echo "[!] $profile full image structure verification failed."
    exit 18
  }
  persistent="$(dynamic_image_for_profile "$slot" "$profile")"
  atomic_dtbo_copy "$temp" "$persistent" "$generated_sha" || exit 18
  [ "$(hash_file "$persistent")" = "$generated_sha" ] || {
    echo "[!] $profile persistent copy verification failed."
    exit 18
  }
  case "$profile" in
    pps33) pps33_sha="$generated_sha" ;;
    pps55) pps55_sha="$generated_sha" ;;
  esac
done

case "$CURRENT" in
  stock) expected_current="$stock_sha" ;;
  pps33) expected_current="$pps33_sha" ;;
  pps55) expected_current="$pps55_sha" ;;
esac
commit_cur="$(block_hash "$block")" || { echo "[!] Failed to re-read DTBO before Full Mode commit."; exit 19; }
[ "$commit_cur" = "$cur" ] && [ "$commit_cur" = "$expected_current" ] || {
  echo "[!] Current partition does not match the regenerated Full Mode endpoint."
  echo "[!] Patch Mode remains active."
  exit 19
}
dynamic_manifest_valid "$slot" && [ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
  echo "[!] Patch Mode manifest changed during Full Mode generation."
  echo "[!] Refusing one-way mode commit."
  exit 19
}

write_dynamic_manifest "$slot" full "$stock_sha" "$pps33_sha" "$pps55_sha" || {
  echo "[!] Full Mode manifest commit failed; Patch Mode remains active."
  exit 20
}
sync

echo "[+] Manual switch to Full Partition Mode completed."
echo "[+] stock SHA256: $stock_sha"
echo "[+] pps33 SHA256: $pps33_sha"
echo "[+] pps55 SHA256: $pps55_sha"
echo "[!] This DTBO generation's Full Partition Mode cannot return to Patch Mode."
