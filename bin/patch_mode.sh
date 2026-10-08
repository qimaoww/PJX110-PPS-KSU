#!/system/bin/sh
BINDIR="$(dirname "$0")"
MODDIR="$(dirname "$BINDIR")"
. "$MODDIR/common.sh"

ACTION="${1:-probe}"
case "$ACTION" in probe|enable|recheck) ;; *) echo "usage: $0 probe|enable|recheck"; exit 2 ;; esac

clean() { printf '%s' "$1" | tr '\r\n=' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
kv() { key="$1"; shift; printf '%s=%s\n' "$key" "$(clean "$*")"; }

LOCK_DIR="$STATE_DIR/toggle.lock"
WORK_DIR="/data/local/tmp/PJX110_PPS_PATCH_PROBE_$$"
WORK_CREATED=0
PATCHER="$MODDIR/bin/dtbo-profile-patcher"
TEMPLATE="$MODDIR/templates/pps33-template.dtbo"

acquire_lock() {
  acquire_dtbo_lock "$LOCK_DIR" || {
    kv state error
    kv message "Another DTBO operation is active"
    return 1
  }
}

cleanup() {
  [ "$WORK_CREATED" != "1" ] || rm -rf "$WORK_DIR" 2>/dev/null
  release_dtbo_lock "$LOCK_DIR"
}

device_ok || { kv state incompatible; kv message "Not PJX110/corvette"; exit 10; }
trusted_slot_conflict && { kv state error; kv message "Trusted slot sources disagree"; exit 11; }
trusted_slot="$(trusted_slot_suffix)"
[ -n "$trusted_slot" ] || { kv state error; kv message "No trusted kernel/bootloader slot source"; exit 12; }
driver_module="$(pps_driver_compatible)" || {
  kv state incompatible
  kv message "PPS driver ABI marker is missing or unsupported"
  exit 10
}
runtime_patch_assets_compatible || {
  kv state incompatible
  kv message "Bundled DTBO patcher/template integrity check failed"
  exit 10
}
slot="$(slot_suffix)"
[ -n "$slot" ] || { kv state error; kv message "Cannot determine active slot"; exit 12; }
[ "$slot" = "$trusted_slot" ] || { kv state error; kv message "Selected slot is not trusted"; exit 12; }
block="$(find_dtbo_block_for_slot "$slot")" || { kv state error; kv message "Active DTBO block not found"; exit 13; }
cur="$(block_hash "$block")" || { kv state error; kv message "Failed to hash DTBO"; exit 14; }

static_family="$(dtbo_family_for_hash "$cur" 2>/dev/null)"
ota_transition=0
ota_patch_transition_allowed "$slot" "$cur" && ota_transition=1
registered_patch=0
if [ "$(dynamic_mode_for_slot "$slot" 2>/dev/null)" = "patch" ] && dynamic_profile_for_hash "$slot" "$cur" >/dev/null; then
  registered_patch=1
fi
if [ "$static_family" != "unknown" ] && [ -n "$static_family" ] &&
  [ "$ota_transition" != "1" ] && [ "$registered_patch" != "1" ]; then
  kv state full
  kv message "Built-in Full Partition Mode cannot use Patch Mode"
  kv sha256 "$cur"
  exit 15
fi

manifest_path="$(dynamic_manifest_for_slot "$slot")"
if [ "$ACTION" = "recheck" ]; then
  dynamic_manifest_valid "$slot" && [ "$(dynamic_mode_for_slot "$slot")" = "patch" ] || {
    kv state error
    kv message "Manual recheck is available only for an existing valid Patch Mode registration"
    exit 16
  }
fi
if [ "$ota_transition" != "1" ] && [ -r "$manifest_path" ] && grep -Fqx 'mode=full' "$manifest_path" 2>/dev/null; then
  kv state full
  kv message "Full Partition Mode registration is permanent; refusing Patch Mode"
  kv sha256 "$cur"
  exit 15
fi

stale_patch_manifest=0
if dynamic_manifest_valid "$slot"; then
  mode="$(dynamic_mode_for_slot "$slot")"
  if [ "$mode" = "full" ] && [ "$ota_transition" != "1" ]; then
    kv state full
    kv message "Dynamic Full Partition Mode cannot return to Patch Mode"
    kv sha256 "$cur"
    exit 15
  fi
  profile="$(dynamic_profile_for_hash "$slot" "$cur")"
  if [ "$ACTION" = "recheck" ] && [ "$profile" != "stock" ]; then
    kv state error
    kv message "Restore the exact stock DTBO before manually rechecking Patch Mode"
    exit 16
  fi
  if [ "$profile" != "unknown" ]; then
    if dynamic_assets_valid "$slot" patch && [ "$ACTION" != "recheck" ]; then
      # This fast path is read-only. Clearing a journal without the shared
      # lock could erase another writer's already-persisted recovery intent.
      kv state enabled
      kv profile "$profile"
      kv sha256 "$cur"
      kv slot_suffix "$slot"
      exit 0
    fi
    [ "$profile" = "stock" ] || {
      kv state error
      kv message "Patch Mode stock backup is unavailable while a PPS profile is active"
      exit 16
    }
  fi
  # OTA can replace the stock DTBO in the same physical slot while leaving
  # the old per-slot manifest behind. Re-registration still requires a fresh
  # stock-only structural probe below.
  stale_patch_manifest=1
fi

if [ "$ota_transition" != "1" ] && [ -e "$manifest_path" ] && [ "$stale_patch_manifest" -ne 1 ]; then
  manifest_mode="$(manifest_value "$manifest_path" mode 2>/dev/null)"
  [ "$manifest_mode" = "patch" ] || {
    kv state error
    kv message "Dynamic manifest exists but is invalid or permanently full; refusing overwrite"
    exit 16
  }
  # A malformed patch manifest can be replaced only after the current image
  # passes the same stock-only probe used for first-time enablement.
  stale_patch_manifest=1
fi

acquire_lock || exit 9
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir "$WORK_DIR" || exit 9
WORK_CREATED=1
chmod 0700 "$WORK_DIR" || exit 9

locked_cur="$(block_hash "$block")" || { kv state error; kv message "Failed to re-read DTBO after locking"; exit 16; }
[ "$locked_cur" = "$cur" ] || {
  kv state error
  kv message "DTBO changed while waiting for the operation lock"
  exit 16
}
if [ "$ota_transition" = "1" ]; then
  ota_patch_transition_allowed "$slot" "$locked_cur" || {
    kv state error
    kv message "OTA Patch Mode eligibility changed while waiting for the operation lock"
    exit 16
  }
elif [ "$registered_patch" = "1" ]; then
  [ "$(dynamic_mode_for_slot "$slot" 2>/dev/null)" = "patch" ] && dynamic_profile_for_hash "$slot" "$locked_cur" >/dev/null || {
    kv state error
    kv message "Patch Mode registration changed while waiting for the operation lock"
    exit 16
  }
fi

if dynamic_manifest_valid "$slot"; then
  locked_mode="$(dynamic_mode_for_slot "$slot")"
  [ "$locked_mode" = "patch" ] || { [ "$ota_transition" = "1" ] && ota_patch_transition_allowed "$slot" "$locked_cur"; } || {
    kv state full
    kv message "Dynamic Full Partition Mode cannot return to Patch Mode"
    exit 15
  }
  locked_profile="$(dynamic_profile_for_hash "$slot" "$locked_cur")"
  if [ "$ACTION" = "recheck" ] && [ "$locked_profile" != "stock" ]; then
    kv state error
    kv message "Patch Mode recheck requires the registered stock endpoint"
    exit 16
  fi
  if [ "$locked_profile" != "unknown" ]; then
    if dynamic_assets_valid "$slot" patch && [ "$ACTION" != "recheck" ]; then
      if [ "$ACTION" = "enable" ] && [ "$locked_profile" = "stock" ]; then
        clear_rescue_write_intent_for_verified_stock "$slot" || true
      fi
      kv state enabled
      kv profile "$locked_profile"
      kv sha256 "$cur"
      kv slot_suffix "$slot"
      exit 0
    fi
    [ "$locked_profile" = "stock" ] || {
      kv state error
      kv message "Patch Mode stock backup is unavailable while a PPS profile is active"
      exit 16
    }
  fi
else
  locked_manifest_path="$(dynamic_manifest_for_slot "$slot")"
  if [ -e "$locked_manifest_path" ] && [ "$(manifest_value "$locked_manifest_path" mode 2>/dev/null)" != "patch" ]; then
    kv state error
    kv message "Dynamic manifest changed while waiting for the operation lock"
    exit 16
  fi
fi
[ -e "$manifest_path" ] && stale_patch_manifest=1

source_img="$WORK_DIR/source.img"
dump_block "$block" "$source_img" || { kv state error; kv message "Failed to dump DTBO"; exit 16; }
[ "$(hash_file "$source_img")" = "$cur" ] || {
  kv state error
  kv message "DTBO changed while reading"
  exit 16
}

probe_output="$("$PATCHER" probe "$source_img" 2>&1)"
probe_rc=$?
probe_state="$(printf '%s\n' "$probe_output" | sed -n 's/^state=//p' | head -n 1)"
probe_profile="$(printf '%s\n' "$probe_output" | sed -n 's/^profile=//p' | head -n 1)"
if [ "$probe_rc" -ne 0 ] || [ "$probe_state" != "compatible" ] || [ "$probe_profile" != "stock" ]; then
  kv state incompatible
  kv message "$probe_output"
  exit 17
fi

kv state compatible
kv profile stock
kv sha256 "$cur"
kv slot_suffix "$slot"
kv entries "$(printf '%s\n' "$probe_output" | sed -n 's/^entries=//p' | head -n 1)"
kv driver_module "$driver_module"

[ "$ACTION" != "probe" ] || exit 0

# A quick probe validates the shared layout anchors. Before committing Patch
# Mode, also prove that both supported outputs can actually be reconstructed
# and parsed with this stock image and the bundled template.
for test_profile in pps33 pps55; do
  test_img="$WORK_DIR/$test_profile.img"
  build_output="$("$PATCHER" build "$source_img" "$TEMPLATE" "$test_profile" "$test_img" 2>&1)" || {
    kv state incompatible
    kv message "$build_output"
    exit 17
  }
  test_sha="$(printf '%s\n' "$build_output" | sed -n 's/^output_sha256=//p' | head -n 1)"
  is_sha256 "$test_sha" && [ "$(hash_file "$test_img")" = "$test_sha" ] || {
    kv state error
    kv message "Dry-run $test_profile hash verification failed"
    exit 17
  }
  verify_dtbo_profile "$test_img" "$test_profile" || {
    kv state error
    kv message "Dry-run $test_profile structure verification failed"
    exit 17
  }
  case "$test_profile" in
    pps33) tested_pps33_sha="$test_sha" ;;
    pps55) tested_pps55_sha="$test_sha" ;;
  esac
done

final_cur="$(block_hash "$block")" || { kv state error; kv message "Failed to re-read DTBO before registration"; exit 16; }
[ "$final_cur" = "$cur" ] || {
  kv state error
  kv message "DTBO changed during compatibility validation; refusing registration"
  exit 16
}
dtbo_write_target_valid "$block" "$slot" && runtime_patch_assets_compatible && pps_driver_compatible >/dev/null || {
  kv state error
  kv message "Trusted DTBO target or patch resources changed during validation"
  exit 16
}
if [ "$ota_transition" = "1" ]; then
  ota_patch_transition_allowed "$slot" "$cur" || {
    kv state error
    kv message "OTA Patch Mode eligibility changed during validation"
    exit 16
  }
fi

commit_manifest="$(dynamic_manifest_for_slot "$slot")"
if [ -e "$commit_manifest" ]; then
  [ "$(manifest_value "$commit_manifest" mode 2>/dev/null)" = "patch" ] || { [ "$ota_transition" = "1" ] && ota_patch_transition_allowed "$slot" "$cur"; } || {
    kv state full
    kv message "Full Mode manifest appeared during validation; refusing Patch Mode commit"
    exit 15
  }
fi

dir="$(dynamic_slot_dir "$slot")" || exit 18
mkdir -p "$dir" || exit 18
stock_img="$(dynamic_image_for_profile "$slot" stock)" || exit 18
atomic_dtbo_copy "$source_img" "$stock_img" "$cur" || exit 18
[ "$(hash_file "$stock_img")" = "$cur" ] || {
  kv state error
  kv message "Persistent stock backup verification failed"
  exit 18
}
prepare_rescue_bundle "$slot" "$stock_img" "$cur" || {
  kv state error
  kv message "Independent Recovery rescue bundle creation/verification failed; Patch Mode was not enabled"
  exit 18
}
rm -f "$(dynamic_image_for_profile "$slot" pps33)" "$(dynamic_image_for_profile "$slot" pps55)"
write_dynamic_manifest "$slot" patch "$cur" "$tested_pps33_sha" "$tested_pps55_sha" || {
  kv state error
  kv message "Failed to create Patch Mode manifest"
  exit 18
}
sync
clear_rescue_write_intent_for_verified_stock "$slot" || true

if [ -d /sdcard ] || [ -e /sdcard ]; then
  mkdir -p /sdcard/Ace3Pro_PPS_Backup 2>/dev/null
  cp -f "$stock_img" "/sdcard/Ace3Pro_PPS_Backup/dtbo$slot-dynamic-stock.img" 2>/dev/null || true
fi

kv state enabled
kv ota_transition "$ota_transition"
kv profile stock
kv rescue_ready 1
kv rescue_path "$RESCUE_DIR/restore_stock.sh"
kv pps33_sha "$tested_pps33_sha"
kv pps55_sha "$tested_pps55_sha"
if [ "$stale_patch_manifest" -eq 1 ]; then
  kv message "Patch Mode re-registered after stock DTBO re-detection; backup verified"
else
  kv message "Patch Mode enabled; stock backup verified"
fi
