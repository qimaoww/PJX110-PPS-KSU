#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/common.sh"

device_ok || exit 0

for slot in _a _b; do
  label="$(slot_label "$slot")"
  block="$(find_dtbo_block_for_slot "$slot")" || continue
  cur="$(block_hash "$block")" || continue
  family="$(dtbo_family_for_hash "$cur")"
  profile="$(detect_profile_for_hash "$cur")"

  case "$profile" in
    pps33|pps55)
      stock_sha="$(stock_sha_for_family "$family")" || continue
      stock="$(stock_image_for_family "$family")" || continue
      echo "[*] Uninstall: restoring slot-$label family-$(dtbo_family_label "$family") from $profile to stock DTBO..."
      write_verify "$stock" "$stock_sha" "$block" "" "" || true
      ;;
    stock)
      echo "[*] Uninstall: slot-$label is already stock."
      ;;
    *)
      echo "[!] Uninstall: slot-$label hash unknown; refusing overwrite."
      ;;
  esac
done
