#!/system/bin/sh
# Installation-only, file-only extraction. Current DTBO is read, never written.
BINDIR="${0%/*}"
MODDIR="${BINDIR%/bin}"
. "$MODDIR/common.sh"
LOCK_DIR="$STATE_DIR/toggle.lock"
STAGE="$MODDIR/.image-stage.$$"
STAGE_CREATED=0
cleanup() {
  [ "$STAGE_CREATED" != "1" ] || rm -rf "$STAGE"
  release_dtbo_lock "$LOCK_DIR"
}
acquire_dtbo_lock "$LOCK_DIR" || { echo "[!] Another DTBO operation is active; refusing image selection."; exit 9; }
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir "$STAGE" || exit 9
STAGE_CREATED=1
chmod 0700 "$STAGE" || exit 9
runtime_patch_assets_compatible || { echo "[!] Patcher/template integrity check failed."; exit 10; }

extract_image() {
  family="$1"; profile="$2"; destination="$3"
  archive="$MODDIR/image_sets/dtbo_$family.zip"
  expected="$(profile_sha_for_family "$family" "$profile")" || return 1
  [ -f "$archive" ] || return 1
  unzip -p "$archive" "$profile.img" > "$destination" 2>/dev/null || return 1
  [ "$(hash_file "$destination")" = "$expected" ] || return 1
  verify_dtbo_profile "$destination" "$profile" || return 1
  chmod 0600 "$destination" || return 1
}

# Exercise the installed arm64 patcher without retaining a baseline image set.
baseline="$STAGE/selftest-stock.img"
selftest="$STAGE/selftest-pps33.img"
extract_image 400 stock "$baseline" || { echo "[!] Self-test stock extraction/AVB verification failed."; exit 10; }
"$MODDIR/bin/dtbo-profile-patcher" build "$baseline" "$MODDIR/templates/pps33-template.dtbo" pps33 "$selftest" >/dev/null 2>&1 &&
  verify_dtbo_profile "$selftest" pps33 || { echo "[!] Native patcher self-test failed."; exit 10; }
rm -f "$baseline" "$selftest"

selected_family=unknown
selected_slot=""
selected_hash=""
if device_ok && ! trusted_slot_conflict; then
  selected_slot="$(trusted_slot_suffix)"
  case "$selected_slot" in
    _a|_b)
      block="$(find_dtbo_block_for_slot "$selected_slot")" || exit 11
      selected_hash="$(block_hash "$block")" || exit 11
      is_sha256 "$selected_hash" || exit 11
      selected_family="$(dtbo_family_for_hash "$selected_hash" 2>/dev/null)"
      ;;
  esac
fi

if [ "$selected_family" != "unknown" ]; then
  for profile in stock pps33 pps55; do
    extract_image "$selected_family" "$profile" "$STAGE/dtbo_${selected_family}_$profile.img" || {
      echo "[!] $selected_family $profile extraction/hash/AVB verification failed."; exit 12
    }
  done
  dtbo_write_target_valid "$block" "$selected_slot" && [ "$(block_hash "$block")" = "$selected_hash" ] || {
    echo "[!] DTBO slot/hash changed during install; refusing image-set commit."; exit 13
  }
  [ ! -L "$MODDIR/images" ] || exit 14
  rm -rf "$MODDIR/images" || exit 14
  mv "$STAGE" "$MODDIR/images" || exit 14
  STAGE_CREATED=0
  printf 'family=%s\nfirmware=%s\n' "$selected_family" "$(dtbo_family_label "$selected_family")" > "$MODDIR/installed_images.conf" || exit 14
  echo "[+] Installed only $(dtbo_family_label "$selected_family"): stock / 33W / 55W (72 MiB)."
else
  [ ! -L "$MODDIR/images" ] || exit 14
  rm -rf "$MODDIR/images" || exit 14
  rm -f "$MODDIR/installed_images.conf"
  echo "[+] Unknown DTBO or unavailable trusted slot: no static images installed; Patch Mode remains gated."
fi

# Always retain the external stock rescue snapshots. Only installation payload
# archives inside this module are removed after successful extraction.
rm -rf "$MODDIR/image_sets" || exit 15
sync || exit 15
echo "[+] Compressed install image sets removed. No DTBO partition was modified."
