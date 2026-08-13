#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/common.sh"

device_ok || exit 0

slot="$(slot_suffix)"
[ -n "$slot" ] || {
  echo "[!] Uninstall: active slot unavailable; refusing any DTBO write."
  exit 0
}
label="$(slot_label "$slot")"
block="$(find_dtbo_block_for_slot "$slot")" || {
  echo "[!] Uninstall: active DTBO block unavailable; refusing any DTBO write."
  exit 0
}
cur="$(block_hash "$block")" || exit 0
family="$(dtbo_family_for_hash "$cur")"
profile="$(detect_profile_for_hash "$cur")"

case "$profile" in
  pps33|pps55)
    stock_sha="$(stock_sha_for_family "$family")" || exit 0
    stock="$(stock_image_for_family "$family")" || exit 0
    echo "[*] Uninstall: restoring active slot-$label from $profile using hash family $(dtbo_family_label "$family")..."
    write_verify "$stock" "$stock_sha" "$block" "" "" || true
    ;;
  stock)
    echo "[*] Uninstall: active slot-$label is already stock."
    ;;
  *)
    echo "[!] Uninstall: active DTBO hash unknown; refusing overwrite."
    ;;
esac
