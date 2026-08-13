#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/common.sh"

device_ok || exit 0

for slot in _a _b; do
  label="$(slot_label "$slot")"
  block="$(find_dtbo_block_for_slot "$slot")" || continue
  stock_sha="$(stock_sha_for_slot "$slot")"
  stock="$(stock_image_for_slot "$slot")"
  cur="$(block_hash "$block")" || continue
  profile="$(detect_profile_for_hash "$slot" "$cur")"

  case "$profile" in
    pps33|pps55)
      echo "[*] Uninstall: restoring slot-$label from $profile to stock DTBO..."
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
