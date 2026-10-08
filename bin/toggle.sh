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
  acquire_dtbo_lock "$LOCK_DIR" || {
    echo "[!] Another DTBO operation is already running."
    return 1
  }
}

release_toggle_lock() {
  release_dtbo_lock "$LOCK_DIR"
}

acquire_toggle_lock || exit 9
trap 'release_toggle_lock' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "========================================"
echo " Ace 3 Pro PPS profile switch"
echo " Target: $TARGET"
echo "========================================"

device_ok || { echo "[!] Not PJX110/corvette."; exit 10; }

if trusted_slot_conflict; then
  echo "[!] Cannot reliably locate the active DTBO partition: trusted slot sources disagree."
  echo "[!] Image selection is hash-only, but the write target must still be unambiguous."
  exit 11
fi

trusted_slot="$(trusted_slot_suffix)"
[ -n "$trusted_slot" ] || {
  echo "[!] No trusted kernel/bootloader slot source is available."
  echo "[!] Refusing to choose a DTBO write target from Android properties alone."
  exit 12
}

slot="$(slot_suffix)"
[ -n "$slot" ] || { echo "[!] Cannot determine active slot."; exit 12; }
[ "$slot" = "$trusted_slot" ] || { echo "[!] Selected slot is not trusted."; exit 12; }
label="$(slot_label "$slot")"
block="$(find_dtbo_block_for_slot "$slot")" || { echo "[!] Active DTBO block not found."; exit 13; }

cur="$(block_hash "$block")" || { echo "[!] Failed to hash DTBO."; exit 14; }
family="$(dtbo_family_for_hash "$cur")"
CURRENT="$(detect_profile_for_hash "$cur")"
management_mode="full_static"
family_label="$(dtbo_family_label "$family")"

if dynamic_profile_for_hash "$slot" "$cur" >/dev/null; then
  dynamic_mode="$(dynamic_mode_for_slot "$slot")"
  if [ "$dynamic_mode" = "patch" ]; then
    echo "[!] This slot is still in Patch Mode."
    echo "[!] Use Patch Mode controls or manually switch to Full Partition Mode first."
    exit 15
  fi
  [ "$dynamic_mode" = "full" ] || { echo "[!] Invalid dynamic management mode."; exit 15; }
  CURRENT="$(dynamic_profile_for_hash "$slot" "$cur")"
  management_mode="full_dynamic"
  family_label="dynamic / $(system_firmware_version)"
fi

echo "[*] Active slot: $label (source: $(slot_source))"
echo "[*] A/B is used only to locate the active DTBO partition; image selection is hash-only."
echo "[*] Current SHA256: $cur"
echo "[*] Management mode: $management_mode"
echo "[*] DTBO firmware family: $family_label"
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

if [ "$management_mode" = "full_static" ] && [ "$TARGET" != "stock" ]; then
  bundled_family_assets_valid "$family" || {
    echo "[!] This firmware's image triplet is not installed or is damaged."
    echo "[!] Reinstall the module to extract the matching set. Refusing PPS write."
    exit 17
  }
fi

if [ "$management_mode" = "full_dynamic" ]; then
  dynamic_runtime_ok=0
  runtime_patch_assets_compatible && dynamic_runtime_ok=1
  [ "$TARGET" = "stock" ] || pps_driver_compatible >/dev/null || {
    echo "[!] PPS driver ABI marker is missing or unsupported. Only stock restore is allowed."
    exit 17
  }
  [ "$TARGET" = "stock" ] || [ "$dynamic_runtime_ok" = "1" ] || {
    echo "[!] Bundled DTBO patcher/template integrity check failed."
    exit 17
  }
  profiles_to_verify="stock pps33 pps55"
  if [ "$TARGET" = "stock" ]; then
    profiles_to_verify="stock"
    if [ "$dynamic_runtime_ok" != "1" ]; then
      echo "[!] Patcher/template integrity is unavailable; proceeding with hash-pinned stock restore only."
    fi
  fi
  for profile in $profiles_to_verify; do
    image="$(dynamic_image_for_profile "$slot" "$profile")" || exit 17
    if [ "$profile" = "stock" ] && [ "$TARGET" = "stock" ]; then
      image="$(dynamic_stock_image_for_recovery "$slot")" || exit 17
    fi
    expected="$(dynamic_sha_for_profile "$slot" "$profile")" || exit 17
    is_sha256 "$expected" && [ -f "$image" ] && [ "$(hash_file "$image")" = "$expected" ] || {
      echo "[!] Dynamic Full Mode $profile image verification failed."
      exit 17
    }
    if [ "$dynamic_runtime_ok" = "1" ]; then
      verify_dtbo_profile "$image" "$profile" || {
        echo "[!] Dynamic Full Mode $profile structure verification failed."
        exit 17
      }
    fi
  done
  stock="$(dynamic_image_for_profile "$slot" stock)"
  stock_sha="$(dynamic_sha_for_profile "$slot" stock)"
  target_img="$(dynamic_image_for_profile "$slot" "$TARGET")"
  target_sha="$(dynamic_sha_for_profile "$slot" "$TARGET")"
  if [ "$TARGET" = "stock" ]; then
    stock="$(dynamic_stock_image_for_recovery "$slot")" || exit 17
    target_img="$stock"
  fi
else
  stock="$(stock_image_for_family "$family")"
  stock_sha="$(stock_sha_for_family "$family")"
  target_img="$(profile_image_for_family "$family" "$TARGET")" || exit 17
  target_sha="$(profile_sha_for_family "$family" "$TARGET")" || exit 17
fi

rescue_ready=0
if runtime_patch_assets_compatible && prepare_rescue_bundle "$slot" "$stock" "$stock_sha"; then
  rescue_ready=1
elif rescue_bundle_valid "$slot" "$stock_sha"; then
  rescue_ready=1
elif [ "$TARGET" = "stock" ] && [ -f "$stock" ] && [ "$(hash_file "$stock")" = "$stock_sha" ] && dtbo_avb_footer_valid "$stock"; then
  # Restoring an exact stock image is the emergency escape hatch. It does not
  # create a new PPS state, and write_verify still enforces DTBO-only target,
  # AVB/footer and full readback verification.
  rescue_ready=1
fi
if [ "$rescue_ready" != "1" ]; then
  echo "[!] Independent Recovery rescue bundle creation/verification failed."
  echo "[!] Refusing DTBO write. No partition was modified."
  exit 17
fi

prewrite_cur="$(block_hash "$block")" || { echo "[!] Failed to re-read DTBO before write."; exit 14; }
[ "$prewrite_cur" = "$cur" ] || {
  echo "[!] DTBO changed during image validation; refusing write."
  exit 15
}
if [ "$management_mode" = "full_dynamic" ]; then
  dynamic_manifest_valid "$slot" && [ "$(dynamic_mode_for_slot "$slot")" = "full" ] || {
    echo "[!] Dynamic Full Mode manifest changed during validation; refusing write."
    exit 17
  }
fi

# Save an external stock backup whenever the exact stock image is currently active.
if [ "$CURRENT" = "stock" ]; then
  backup_stock "$block" "$slot" "$stock_sha" || {
    echo "[!] Stock backup failed; refusing modified DTBO write."
    exit 16
  }
fi

case "$TARGET" in
  stock) echo "[*] Restoring exact slot-$label stock DTBO..." ;;
  pps33) echo "[*] Switching slot-$label to PPS 33W profile..." ;;
  pps55)
    echo "[*] Switching slot-$label to PPS 55W experimental profile..."
    echo "[!] 55W requires a charger/APDO and cable capable of the requested current."
    ;;
esac

record_rescue_write_intent "$slot" "$stock_sha" "$target_sha" || {
  if [ "$TARGET" != "stock" ]; then
    echo "[!] Failed to persist the recovery write-intent journal."
    echo "[!] Refusing DTBO write. No partition was modified."
    exit 17
  fi
  echo "[!] Recovery journal unavailable; proceeding with exact stock restoration only."
}

if [ "$TARGET" = "stock" ]; then
  write_verify "$target_img" "$target_sha" "$block" "$target_img" "$target_sha" "$slot" "$cur" || exit 18
else
  write_verify "$target_img" "$target_sha" "$block" "$stock" "$stock_sha" "$slot" "$cur" || exit 18
fi

if [ "$TARGET" = "stock" ]; then
  clear_rescue_write_intent "$slot" "$stock_sha" || {
    echo "[!] Stock is restored, but the stale rescue journal could not be cleared."
  }
fi

echo "[+] Profile '$TARGET' written and readback verified."
if rescue_bundle_valid "$slot" "$stock_sha"; then
  echo "[+] Independent Recovery rescue snapshot: $RESCUE_DIR/restore_stock.sh"
fi
echo "[+] Reboot is required."
exit 0
