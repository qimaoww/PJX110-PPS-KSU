#!/system/bin/sh
MODDIR="${0%/*}"
MODDIR="${MODDIR%/bin}"
PPS_STATE_READ_ONLY=1
. "$MODDIR/common.sh"

clean() { printf '%s' "$1" | tr '\r\n=' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
kv() { k="$1"; shift; printf '%s=%s\n' "$k" "$(clean "$*")"; }

# Snapshot each source once. Never cache a slot or a partition hash on disk.
bc_slot="$(slot_from_bootconfig)"
cl_slot="$(slot_from_cmdline)"
ctl_slot="$(slot_from_bootctl)"
prop_slot="$(slot_from_getprop)"
slot=""
source="unknown"
trusted_slot=""
trusted_conflict=0
for entry in "bootconfig:$bc_slot" "cmdline:$cl_slot" "bootctl:$ctl_slot"; do
  candidate="${entry#*:}"
  case "$candidate" in _a|_b) ;; *) continue ;; esac
  if [ -z "$trusted_slot" ]; then
    trusted_slot="$candidate"
    slot="$candidate"
    source="${entry%%:*}"
  elif [ "$trusted_slot" != "$candidate" ]; then
    trusted_conflict=1
  fi
done
if [ -z "$slot" ]; then
  slot="$prop_slot"
  [ -z "$slot" ] || source="getprop"
fi
trusted_available=0
[ -n "$trusted_slot" ] && trusted_available=1
prop_conflict=0
[ -n "$prop_slot" ] && [ -n "$slot" ] && [ "$prop_slot" != "$slot" ] && prop_conflict=1
firmware="$(system_firmware_version)"

[ -n "$slot" ] || { kv state error; kv message "Cannot determine A/B slot"; exit 1; }
label="$(slot_label "$slot")"
block="$(find_dtbo_block_for_slot "$slot")" || { kv state error; kv message "DTBO block not found"; exit 1; }
cur="$(block_hash "$block")" || { kv state error; kv message "Failed to read DTBO"; exit 1; }
is_sha256 "$cur" || { kv state error; kv message "Invalid DTBO readback hash"; exit 1; }

family="$(dtbo_family_for_hash "$cur")"
state="$(detect_profile_for_hash "$cur")"
registered_profile="$(dynamic_profile_for_hash "$slot" "$cur")"
management_mode="none"
patch_can_enable=0
patch_can_promote=0
patch_can_recheck=0
ota_patch_available=0
ota_candidate=0
ota_patch_transition_allowed "$slot" "$cur" && ota_candidate=1
driver_compatible=0
# Scan the ABI only when dynamic controls can apply, including a manual OTA
# registration. A matching per-slot generation takes priority over static SHA.
if [ "$family" = "unknown" ] || [ "$registered_profile" != "unknown" ] || [ "$ota_candidate" = "1" ]; then
  pps_driver_compatible >/dev/null 2>&1 && driver_compatible=1
fi
runtime_assets_compatible=0
runtime_patch_assets_compatible && runtime_assets_compatible=1
dynamic_assets_complete=1
static_assets_complete=0
static_stock_available=0
family_text="$(dtbo_family_label "$family")"
stock_sha="$(stock_sha_for_family "$family")"
pps33_sha="$(pps33_sha_for_family "$family")"
pps55_sha="$(pps55_sha_for_family "$family")"

if [ "$family" != "unknown" ] && [ "$state" != "unknown" ] && [ "$registered_profile" = "unknown" ]; then
  management_mode="full_static"
  bundled_stock_asset_valid "$family" && static_stock_available=1
  bundled_family_assets_valid "$family" && static_assets_complete=1
  if [ "$ota_candidate" = "1" ] && [ "$driver_compatible" = "1" ] && [ "$runtime_assets_compatible" = "1" ]; then
    ota_patch_available=1
    patch_can_enable=1
  fi
else
  state=unknown
  if dynamic_manifest_valid "$slot"; then
    dynamic_mode="$(dynamic_mode_for_slot "$slot")"
    dynamic_profile="$(dynamic_profile_for_hash "$slot" "$cur")"
    dynamic_state_usable=0
    if [ "$dynamic_profile" != "unknown" ]; then
      case "$dynamic_mode" in
        patch)
          if dynamic_stock_asset_valid "$slot"; then
            dynamic_state_usable=1
            dynamic_assets_valid "$slot" patch || dynamic_assets_complete=0
          fi
          ;;
        full)
          if dynamic_stock_asset_valid "$slot"; then
            dynamic_state_usable=1
            dynamic_assets_valid "$slot" full || dynamic_assets_complete=0
          fi
          ;;
      esac
    fi
    if [ "$dynamic_state_usable" = "1" ]; then
      state="$dynamic_profile"
      family_text="动态生成 / $firmware"
      stock_sha="$(dynamic_sha_for_profile "$slot" stock)"
      pps33_sha="$(dynamic_sha_for_profile "$slot" pps33)"
      pps55_sha="$(dynamic_sha_for_profile "$slot" pps55)"
      case "$dynamic_mode" in
        patch)
          management_mode="patch"
          [ "$state" = "stock" ] && [ "$driver_compatible" = "1" ] && [ "$runtime_assets_compatible" = "1" ] && patch_can_recheck=1
          [ "$driver_compatible" = "1" ] && [ "$runtime_assets_compatible" = "1" ] && [ "$dynamic_assets_complete" = "1" ] && patch_can_promote=1
          ;;
        full)
          management_mode="full_dynamic"
          ;;
      esac
    elif { [ "$dynamic_profile" = "unknown" ] || [ "$dynamic_profile" = "stock" ]; } && [ "$dynamic_mode" = "patch" ]; then
      # The same physical slot may have received a new stock DTBO during OTA.
      # Expose a safe re-detection action; patch_mode.sh will probe the image
      # and replace the per-slot registration only after that succeeds.
      management_mode="none"
      [ "$runtime_assets_compatible" = "1" ] && [ "$driver_compatible" = "1" ] && patch_can_enable=1
      family_text="动态检测待重新注册/修复 / $firmware"
    else
      management_mode="error"
    fi
  else
    manifest_path="$(dynamic_manifest_for_slot "$slot")"
    manifest_mode="$(manifest_value "$manifest_path" mode 2>/dev/null)"
    manifest_has_full=0
    [ -r "$manifest_path" ] && grep -Fqx 'mode=full' "$manifest_path" 2>/dev/null && manifest_has_full=1
    if [ "$manifest_mode" = "patch" ] && [ "$manifest_has_full" != "1" ]; then
      management_mode="none"
      [ "$runtime_assets_compatible" = "1" ] && [ "$driver_compatible" = "1" ] && patch_can_enable=1
      family_text="动态检测待重新注册 / $firmware"
    elif [ -e "$manifest_path" ]; then
      management_mode="error"
    else
      [ "$runtime_assets_compatible" = "1" ] && [ "$driver_compatible" = "1" ] && patch_can_enable=1
    fi
  fi
fi

# A conflicting trusted slot source makes the write target ambiguous even if
# the current hash is otherwise recognized. Keep telemetry visible, but make
# every mutating control unavailable until the sources agree again.
if [ "$trusted_conflict" = "1" ] || [ "$trusted_available" != "1" ] || [ "$slot" != "$trusted_slot" ]; then
  management_mode="error"
  patch_can_enable=0
  ota_patch_available=0
  patch_can_promote=0
  patch_can_recheck=0
fi

case "$state" in
  stock) text="原厂 DTBO" ;;
  pps33) text="PPS 33W DTBO" ;;
  pps55) text="PPS 55W DTBO" ;;
  *) text="未知/不支持的 DTBO"; state=unknown ;;
esac

rescue_ready=0
rescue_path="$RESCUE_DIR/restore_stock.sh"
if is_sha256 "$stock_sha" 2>/dev/null && rescue_bundle_valid "$slot" "$stock_sha"; then
  rescue_ready=1
fi
rescue_last_slot="$(rescue_last_written_slot 2>/dev/null)"
case "$rescue_last_slot" in
  _a) rescue_last_slot=A ;;
  _b) rescue_last_slot=B ;;
  *) rescue_last_slot=none ;;
esac

kv state "$state"
kv label "$text"
kv slot "$label"
kv slot_suffix "$slot"
kv slot_source "$source"
kv trusted_slot_conflict "$trusted_conflict"
kv trusted_slot_available "$trusted_available"
kv prop_slot_conflict "$prop_conflict"
kv block "$block"
kv sha256 "$cur"
kv system_firmware "$firmware"
kv dtbo_family "$family_text"
kv management_mode "$management_mode"
kv patch_can_enable "$patch_can_enable"
kv ota_patch_available "$ota_patch_available"
kv patch_can_promote "$patch_can_promote"
kv patch_can_recheck "$patch_can_recheck"
kv stock_sha "$stock_sha"
kv pps33_sha "$pps33_sha"
kv pps55_sha "$pps55_sha"
kv patch_driver_compatible "$driver_compatible"
kv patch_runtime_assets_compatible "$runtime_assets_compatible"
kv dynamic_assets_complete "$dynamic_assets_complete"
kv static_assets_complete "$static_assets_complete"
kv static_stock_available "$static_stock_available"
kv rescue_ready "$rescue_ready"
kv rescue_path "$rescue_path"
kv rescue_last_written_slot "$rescue_last_slot"
kv ab_supported "A/B"
