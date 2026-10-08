#!/system/bin/sh
MODDIR="${0%/*}"
. "$MODDIR/common.sh"

device_ok || exit 0

if trusted_slot_conflict; then
  echo "[!] Uninstall: trusted slot sources disagree; refusing any DTBO write."
  exit 0
fi

trusted_slot="$(trusted_slot_suffix)"
[ -n "$trusted_slot" ] || {
  echo "[!] Uninstall: no trusted kernel/bootloader slot source; refusing any DTBO write."
  exit 0
}

LOCK_DIR="$STATE_DIR/toggle.lock"
acquire_dtbo_lock "$LOCK_DIR" || {
  echo "[!] Uninstall: another DTBO operation is active; refusing any DTBO write."
  exit 0
}
cleanup_uninstall() { release_dtbo_lock "$LOCK_DIR"; }
trap 'cleanup_uninstall' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

slot="$(slot_suffix)"
[ -n "$slot" ] || {
  echo "[!] Uninstall: active slot unavailable; refusing any DTBO write."
  exit 0
}
[ "$slot" = "$trusted_slot" ] || {
  echo "[!] Uninstall: selected slot is not trusted; refusing any DTBO write."
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
management_mode="full_static"

if dynamic_profile_for_hash "$slot" "$cur" >/dev/null; then
  profile="$(dynamic_profile_for_hash "$slot" "$cur")"
  if [ "$profile" != "unknown" ]; then
    management_mode="$(dynamic_mode_for_slot "$slot")"
    stock_sha="$(dynamic_sha_for_profile "$slot" stock)"
    stock="$(dynamic_stock_image_for_recovery "$slot")" || exit 0
  fi
fi

case "$profile" in
  pps33|pps55)
    if [ "$management_mode" = "full_static" ]; then
      stock_sha="$(stock_sha_for_family "$family")" || exit 0
      stock="$(stock_image_for_family "$family")" || exit 0
      source_label="$(dtbo_family_label "$family")"
    else
      source_label="dynamic $management_mode / $(system_firmware_version)"
      [ -f "$stock" ] && [ "$(hash_file "$stock")" = "$stock_sha" ] || exit 0
      if runtime_patch_assets_compatible; then
        verify_dtbo_profile "$stock" stock || exit 0
      else
        echo "[!] Uninstall: patcher integrity unavailable; using the hash-pinned stock backup."
      fi
    fi
    prewrite_cur="$(block_hash "$block")" || exit 0
    [ "$prewrite_cur" = "$cur" ] || {
      echo "[!] Uninstall: DTBO changed during validation; refusing overwrite."
      exit 0
    }
    rescue_ready=0
    if runtime_patch_assets_compatible && prepare_rescue_bundle "$slot" "$stock" "$stock_sha"; then
      rescue_ready=1
    elif rescue_bundle_valid "$slot" "$stock_sha"; then
      rescue_ready=1
    fi
    if [ "$rescue_ready" = "1" ]; then
      record_rescue_write_intent "$slot" "$stock_sha" "$stock_sha" || rescue_ready=0
    fi
    echo "[*] Uninstall: restoring active slot-$label from $profile using $source_label..."
    if write_verify "$stock" "$stock_sha" "$block" "$stock" "$stock_sha" "$slot" "$cur"; then
      [ "$rescue_ready" != "1" ] || clear_rescue_write_intent "$slot" "$stock_sha" || true
    else
      echo "[!] Uninstall: exact stock DTBO restore failed; the independent rescue snapshot was retained."
    fi
    ;;
  stock)
    echo "[*] Uninstall: active slot-$label is already stock."
    ;;
  *)
    echo "[!] Uninstall: active DTBO hash unknown; refusing overwrite."
    ;;
esac
