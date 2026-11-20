#!/usr/bin/env bash
# File-only OTA/state-machine regression: production writers, host verifier.
# Only the block predicate and device/driver discovery are replaced. No device IO.
set -u
REPO="$(pwd -P)"
SIM="$(mktemp -d "$REPO/investigation/ota-patch.XXXXXX")" || exit 1
cleanup_test() { case "$SIM" in "$REPO"/investigation/ota-patch.*) rm -rf "$SIM" ;; *) exit 99 ;; esac; }
trap cleanup_test EXIT
PPS_STATE_READ_ONLY=1
MODDIR="$SIM/module"
. "$REPO/common.sh"
STATE_DIR="$SIM/state"; BACKUP_DIR="$STATE_DIR/backup"; LOG_DIR="$STATE_DIR/logs"
DYNAMIC_DIR="$STATE_DIR/dynamic"; RESCUE_DIR="$STATE_DIR/rescue"
BLOCK="$SIM/dtbo_a.img"; CALLS="$SIM/writes"
mkdir -p "$MODDIR/bin" "$MODDIR/templates" "$MODDIR/rescue" "$MODDIR/images" "$SIM/tmp" "$BACKUP_DIR" "$LOG_DIR"
cp "$REPO/investigation/dtbo-profile-patcher-windows-amd64.exe" "$MODDIR/bin/profile-patcher-host.exe"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$MODDIR/bin/profile-patcher-host.exe" > "$MODDIR/bin/dtbo-profile-patcher"
chmod 0755 "$MODDIR/bin/dtbo-profile-patcher"
cp "$REPO/templates/pps33-template.dtbo" "$MODDIR/templates/pps33-template.dtbo"
cp "$REPO/rescue/restore_stock.sh" "$MODDIR/rescue/restore_stock.sh"
cp "$REPO/images/dtbo_400_"*.img "$MODDIR/images/"
cp "$REPO/images/dtbo_1001_stock.img" "$BLOCK"
: > "$CALLS"
PPS_PATCHER_SHA256="$(hash_file "$MODDIR/bin/dtbo-profile-patcher")"
DRIVER_OK=1; ASSETS_OK=1; CONFLICT=0
device_ok() { return 0; }
trusted_slot_conflict() { [ "$CONFLICT" = 1 ]; }
slot_suffix() { echo _a; }
trusted_slot_suffix() { echo _a; }
slot_source() { echo fixture; }
slot_from_bootconfig() { echo _a; }
slot_from_cmdline() { [ "$CONFLICT" = 0 ] && echo _a || echo _b; }
slot_from_bootctl() { echo _a; }
slot_from_getprop() { echo _a; }
system_firmware_version() { echo PJX110_16.0.5.1001; }
pps_driver_compatible() { [ "$DRIVER_OK" = 1 ]; }
runtime_patch_assets_compatible() { [ "$ASSETS_OK" = 1 ]; }
find_dtbo_block_for_slot() { [ "$1" = _a ] || return 1; echo "$BLOCK"; }
dtbo_block_device_valid() { [ "$1" = "$BLOCK" ] && [ -f "$1" ]; }
block_size_bytes() { [ "$1" = "$BLOCK" ] || return 1; file_size_bytes "$1"; }
sync() { :; }
# Preserve the production backup logic, redirect only its Android temp path.
eval "$(declare -f backup_stock | sed "s#/data/local/tmp#$SIM/tmp#g")"
dd() {
  destination=""; for arg in "$@"; do case "$arg" in of=*) destination="${arg#of=}" ;; esac; done
  if [ -n "$destination" ]; then
    if [ "$destination" = "$BLOCK" ]; then
      printf 'write\n' >> "$CALLS"
    else
      case "$destination" in "$SIM"/tmp/*|"$BACKUP_DIR"/*) ;; *) echo "unsafe test output" >&2; return 99 ;; esac
    fi
  fi
  command dd "$@"
}
fail() { echo "FAIL: $*"; cat "$SIM/output" 2>/dev/null; exit 1; }
run_script() {
  script="$1"; shift
  case "$script" in bin/dtbo_state.sh) skip=5 ;; uninstall.sh) skip=3 ;; *) skip=4 ;; esac
  sed "1,${skip}d" "$REPO/$script" | sed "s#/data/local/tmp#$SIM/tmp#g" > "$SIM/body.sh"
  ( set -- "$@"; . "$SIM/body.sh" ) > "$SIM/output" 2>&1
}
field() { sed -n "s/^$1=//p" "$SIM/output" | head -n 1; }
state_field() { [ "$(field "$1")" = "$2" ] || fail "$1 != $2"; }
count() { wc -l < "$CALLS" | tr -d ' '; }
stock_before="$(hash_file "$BLOCK")"
if [ "${1:-}" = --state-read ]; then
  printf 'family=400\nfirmware=PJX110_16.0.2.400\n' > "$MODDIR/installed_images.conf"
  cp "$MODDIR/images/dtbo_400_stock.img" "$BLOCK" || fail fixture
  # Count only the installed stock image, not the active partition snapshot.
  eval "$(declare -f hash_file | sed '1s/hash_file/raw_hash_file/')"
  hash_file() {
    if [ "$1" = "$MODDIR/images/dtbo_400_stock.img" ]; then echo stock >> "$SIM/stock-reads"; fi
    raw_hash_file "$1"
  }
  system_firmware_version() { printf 'test=firmware\npatch_can_enable=9\n'; }
  run_script bin/dtbo_state.sh || fail static-read
  state_field static_full_selectable 1; state_field static_assets_complete 1; state_field static_stock_available 1
  state_field system_firmware 'test firmware patch_can_enable 9'
  [ "$(wc -l < "$SIM/stock-reads")" -eq 1 ] || fail duplicate-stock-read
  mv "$MODDIR/images/dtbo_400_pps55.img" "$SIM/missing-55.img" || fail fixture
  run_script bin/dtbo_state.sh || fail incomplete-read
  state_field static_full_selectable 0; state_field static_assets_complete 0; state_field static_stock_available 1
  [ "$(count)" = 0 ] || fail status-wrote-dtbo
  echo 'PASS read-only state: stock hashed once for a complete set, broken set retains stock only, output sanitized'
  exit 0
fi
manifest="$(dynamic_manifest_for_slot _a)"
run_full_tests() {
  run_script bin/dtbo_state.sh || fail full-state
  state_field management_mode full_dynamic; state_field state stock; state_field full_stock_patch_available 1; state_field patch_can_enable 1
  run_script bin/patch_toggle.sh pps33 && fail full-used-patch-writer
  run_script bin/toggle.sh pps33 || fail full-pps-write
  [ "$(hash_file "$BLOCK")" = "$(dynamic_sha_for_profile _a pps33)" ] || fail full-pps-readback
  run_script bin/patch_mode.sh enable && fail full-pps-enabled-patch
  run_script bin/toggle.sh stock || fail full-stock-restore
  [ "$(hash_file "$BLOCK")" = "$stock_before" ] || fail final-stock
  before="$(count)"
  run_script bin/patch_mode.sh enable || fail restored-full-stock-switch
  [ "$(dynamic_mode_for_slot _a)" = patch ] && [ "$(count)" = "$before" ] && [ "$(hash_file "$BLOCK")" = "$stock_before" ] || fail mode-only-transition
  run_script bin/toggle.sh pps55 && fail patch-owned-full-writer
  echo 'PASS dynamic Full requires exact stock before returning to Patch; registration does not write DTBO'
}
if [ "${1:-}" = --static-400 ]; then
  printf 'family=400\nfirmware=PJX110_16.0.2.400\n' > "$MODDIR/installed_images.conf"
  for profile in pps33 pps55; do
    cp "$MODDIR/images/dtbo_400_$profile.img" "$BLOCK"
    run_script bin/dtbo_state.sh || fail legacy-state
    state_field management_mode restore_only; state_field static_stock_available 1
    run_script bin/toggle.sh pps33 && fail legacy-33
    run_script bin/toggle.sh pps55 && fail legacy-55
    run_script bin/patch_mode.sh enable && fail pps-mode-change
    run_script bin/select_static_full.sh _a "$(hash_file "$BLOCK")" && fail pps-full-selection
  done
  cp "$MODDIR/images/dtbo_400_stock.img" "$BLOCK"
  run_script bin/dtbo_state.sh || fail state-400
  state_field state stock; state_field management_mode stock_idle; state_field full_stock_patch_available 1
  state_field static_full_selectable 1
  for target in pps33 pps55; do
    run_script bin/toggle.sh "$target" && fail neutral-full-writer
    run_script bin/patch_toggle.sh "$target" && fail neutral-patch-writer
  done
  [ "$(count)" = 0 ] && [ "$(hash_file "$BLOCK")" = "$F400_STOCK_SHA" ] || fail no-mode-wrote-dtbo
  run_script bin/select_static_full.sh _b "$F400_STOCK_SHA" && fail wrong-slot-choice
  run_script bin/select_static_full.sh _a "$F1001_STOCK_SHA" && fail stale-ui-choice
  mv "$MODDIR/images/dtbo_400_pps55.img" "$SIM/missing-55.img"
  run_script bin/select_static_full.sh _a "$F400_STOCK_SHA" && fail incomplete-set-choice
  mv "$SIM/missing-55.img" "$MODDIR/images/dtbo_400_pps55.img"
  [ ! -e "$(static_choice_path _a)" ] || fail unexpected-selection
  DRIVER_OK=0
  run_script bin/select_static_full.sh _a "$F400_STOCK_SHA" || fail full-selection
  run_script bin/dtbo_state.sh || fail refresh-selected-full
  state_field state stock; state_field management_mode full_static; state_field static_full_selectable 0; state_field patch_can_enable 0
  static_choice_matches _a "$F1001_STOCK_SHA" && fail ota-inherited-selection
  static_choice_matches _b "$F400_STOCK_SHA" && fail other-slot-inherited-selection
  [ "$(count)" = 0 ] || fail mode-selection-wrote-dtbo
  run_script bin/patch_toggle.sh pps33 && fail full-used-patch-writer
  run_script bin/toggle.sh pps33 || fail selected-full-33
  [ "$(hash_file "$BLOCK")" = "$F400_PPS33_SHA" ] || fail selected-full-33-readback
  run_script bin/toggle.sh pps55 || fail selected-full-55
  [ "$(hash_file "$BLOCK")" = "$F400_PPS55_SHA" ] || fail selected-full-55-readback
  run_script bin/toggle.sh stock || fail selected-full-stock
  full_writes="$(count)"; [ "$full_writes" = 3 ] || fail unexpected-full-writes
  DRIVER_OK=1
  run_script bin/patch_mode.sh enable || fail stock-400-enable
  run_script bin/select_static_full.sh _a "$F400_STOCK_SHA" && fail static-stole-patch
  static_choice_matches _a "$F400_STOCK_SHA" && fail stale-full-choice
  run_script bin/toggle.sh pps55 && fail patch-used-full-writer
  [ "$(dynamic_mode_for_slot _a)" = patch ] && [ "$(count)" = "$full_writes" ] && [ "$(hash_file "$BLOCK")" = "$F400_STOCK_SHA" ] || fail stock-400-registration
  rescue_bundle_valid _a "$F400_STOCK_SHA" || fail stock-400-rescue
  echo 'PASS 400: no mode rejects both writers; selected Full alone writes 33/55 and restores; Patch takes exclusive ownership'
  exit 0
fi
if [ "${1:-}" = --full-only ]; then
  dir="$(dynamic_slot_dir _a)"; mkdir -p "$dir"
  cp "$BLOCK" "$dir/stock.img"
  for profile in pps33 pps55; do
    "$MODDIR/bin/dtbo-profile-patcher" build "$dir/stock.img" "$MODDIR/templates/pps33-template.dtbo" "$profile" "$dir/$profile.img" > "$SIM/output" 2>&1 || fail full-fixture-build
  done
  write_dynamic_manifest _a full "$stock_before" "$(hash_file "$dir/pps33.img")" "$(hash_file "$dir/pps55.img")" || fail full-fixture-manifest
  prepare_rescue_bundle _a "$dir/stock.img" "$stock_before" || fail full-fixture-rescue
  run_full_tests
  echo 'OTA Full regression OK'
  exit 0
fi
if [ "${1:-}" = --patch-upgrade ]; then
  # An installation on previously uncatalogued stock extracts no static set
  # or installed_images.conf. Retain an actual, verified Patch stock backup.
  # Use an unmodified bundled image to represent the previous stock generation;
  # eligibility depends on its registered hash, not the historical whitelist.
  cp "$REPO/images/dtbo_1001_stock.img" "$BLOCK" || fail fixture
  old_sha="$(hash_file "$BLOCK")"
  old_dir="$(dynamic_slot_dir _a)"; mkdir -p "$old_dir"
  "$MODDIR/bin/dtbo-profile-patcher" verify "$BLOCK" > "$SIM/output" || fail old-stock-verify
  cp "$BLOCK" "$old_dir/stock.img"
  write_dynamic_manifest _a patch "$old_sha" '' '' || fail old-registration
  cp "$REPO/images/dtbo_1301_stock.img" "$BLOCK"
  ota_patch_transition_allowed _a "$F1301_STOCK_SHA" || fail patch-history-ota-1301
  ota_patch_transition_allowed _b "$F1301_STOCK_SHA" && fail other-slot-registration
  ota_patch_transition_allowed _a "$F1301_PPS33_SHA" && fail non-stock-target
  printf 'family=invalid\n' > "$MODDIR/installed_images.conf"
  ota_patch_transition_allowed _a "$F1301_STOCK_SHA" && fail invalid-record-fallback
  rm "$MODDIR/installed_images.conf"
  mv "$old_dir/stock.img" "$SIM/old-stock.img"
  ota_patch_transition_allowed _a "$F1301_STOCK_SHA" && fail missing-old-stock
  mv "$SIM/old-stock.img" "$old_dir/stock.img"
  write_dynamic_manifest _a full "$old_sha" "$F400_PPS33_SHA" "$F400_PPS55_SHA" || fail old-full-setup
  ota_patch_transition_allowed _a "$F1301_STOCK_SHA" && fail full-history-without-install-record
  mv "$manifest" "$SIM/old-full-manifest"
  write_dynamic_manifest _a patch "$old_sha" '' '' || fail old-registration
  run_script bin/dtbo_state.sh || fail upgrade-state
  state_field patch_can_enable 1; state_field ota_patch_available 1
  run_script bin/patch_mode.sh enable || fail upgrade-enable
  grep -Fqx 'state=enabled' "$SIM/output" || fail upgrade-not-enabled
  [ "$(dynamic_sha_for_profile _a stock)" = "$F1301_STOCK_SHA" ] || fail new-stock-pin
  rescue_bundle_valid _a "$F1301_STOCK_SHA" || fail upgrade-rescue
  [ "$(count)" = 0 ] && [ "$(hash_file "$BLOCK")" = "$F1301_STOCK_SHA" ] || fail upgrade-registration-wrote-dtbo
  echo 'PASS same-slot Patch history -> 1301 manual stock registration without an install record; no writes'
  exit 0
fi
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" && fail missing-install-record
printf 'family=400\nfirmware=PJX110_16.0.2.400\nfamily=400\n' > "$MODDIR/installed_images.conf"
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" && fail duplicate-install-record
printf 'family=400\nfirmware=wrong\n' > "$MODDIR/installed_images.conf"
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" && fail invalid-install-record
printf 'family=400\nfirmware=PJX110_16.0.2.400\n' > "$MODDIR/installed_images.conf"
ota_patch_transition_allowed _c "$F1001_STOCK_SHA" && fail invalid-slot
ota_patch_transition_allowed _a "$F400_STOCK_SHA" && fail same-install-family
ota_patch_transition_allowed _a "$F1001_PPS33_SHA" && fail pps-not-stock
write_dynamic_manifest _a full "$F1001_STOCK_SHA" "$F1001_PPS33_SHA" "$F1001_PPS55_SHA" || fail same-generation-setup
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" && fail same-generation-full
write_dynamic_manifest _a full "$F400_STOCK_SHA" "$F400_PPS33_SHA" "$F400_PPS55_SHA" || fail previous-generation-setup
cp "$manifest" "$SIM/old-manifest"
printf 'mode=full\n' > "$manifest"
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" && fail malformed-old-manifest
cp "$SIM/old-manifest" "$manifest"
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" || fail genuine-ota-stock
cp "$REPO/images/dtbo_1001_"*.img "$MODDIR/images/"
ota_patch_transition_allowed _a "$F1001_STOCK_SHA" && fail complete-static-set
rm -f "$MODDIR/images/dtbo_1001_"*.img
echo 'PASS OTA offer requires a different exact stock generation, missing set and valid records'
DRIVER_OK=0
run_script bin/dtbo_state.sh || fail state-driver
state_field patch_can_enable 0; state_field ota_patch_available 0
run_script bin/patch_mode.sh enable && fail incompatible-driver-accepted
DRIVER_OK=1; ASSETS_OK=0
run_script bin/dtbo_state.sh || fail state-assets
state_field patch_can_enable 0; state_field ota_patch_available 0
run_script bin/patch_mode.sh enable && fail incompatible-assets-accepted
ASSETS_OK=1; CONFLICT=1
run_script bin/dtbo_state.sh && fail conflicting-state-read
state_field state error
run_script bin/patch_mode.sh enable && fail conflicting-slot-accepted
CONFLICT=0
[ "$(hash_file "$manifest")" = "$(hash_file "$SIM/old-manifest")" ] || fail rejected-actions-changed-manifest
[ "$(count)" = 0 ] || fail rejected-actions-wrote-dtbo
run_script bin/dtbo_state.sh || fail initial-state
state_field management_mode stock_idle; state_field state stock
state_field static_assets_complete 0; state_field ota_patch_available 1; state_field patch_can_enable 1
echo 'PASS OTA stock remains neutral until manual selection; unavailable resources disable it'
run_script bin/patch_mode.sh enable || fail manual-enable
[ "$(dynamic_mode_for_slot _a)" = patch ] || fail patch-registration
[ "$(hash_file "$BLOCK")" = "$stock_before" ] && [ "$(count)" = 0 ] || fail enable-wrote-partition
rescue_bundle_valid _a "$F1001_STOCK_SHA" || fail stock-rescue
run_script bin/dtbo_state.sh || fail patch-state
state_field management_mode patch; state_field state stock
state_field ota_patch_available 0; state_field patch_can_enable 0; state_field patch_can_recheck 1
run_script bin/toggle.sh pps33 && fail full-command-accepted-in-patch
run_script bin/patch_mode.sh recheck || fail known-stock-recheck
[ "$(count)" = 0 ] || fail recheck-wrote-partition
echo 'PASS manual enable/recheck are read-only and known stock routes only to Patch controls'
run_script bin/patch_toggle.sh pps33 || fail patch-write
[ "$(hash_file "$BLOCK")" = "$(dynamic_sha_for_profile _a pps33)" ] || fail pps-readback
run_script bin/dtbo_state.sh || fail patch-pps-state
state_field management_mode patch; state_field state pps33
state_field patch_can_promote 0
run_script bin/promote_full.sh && fail patch-pps-promoted
run_script uninstall.sh || fail uninstall
[ "$(hash_file "$BLOCK")" = "$stock_before" ] || fail uninstall-stock-restore
run_script bin/patch_toggle.sh pps55 || fail patch-55
run_script bin/patch_toggle.sh stock || fail patch-stock-restore
run_script bin/promote_full.sh || fail manual-promotion
[ "$(dynamic_mode_for_slot _a)" = full ] || fail full-registration
run_full_tests
echo 'OTA Patch regression OK'
