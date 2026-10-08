#!/usr/bin/env bash
# Installer simulation: only fixture files and native host patcher, no device IO.
set -u
REPO="$(pwd -P)"
SIM="$(mktemp -d "$REPO/investigation/install-images.XXXXXX")" || exit 1
cleanup_test() { case "$SIM" in "$REPO"/investigation/install-images.*) rm -rf "$SIM" ;; *) exit 99 ;; esac; }
trap cleanup_test EXIT
PPS_STATE_READ_ONLY=1
. "$REPO/common.sh"
STATE_DIR="$SIM/state"; BACKUP_DIR="$STATE_DIR/backup"; LOG_DIR="$STATE_DIR/logs"; DYNAMIC_DIR="$STATE_DIR/dynamic"; RESCUE_DIR="$STATE_DIR/rescue"
mkdir -p "$STATE_DIR" "$RESCUE_DIR"
device_ok() { return 0; }
trusted_slot_conflict() { [ "$CONFLICT" = 1 ]; }
trusted_slot_suffix() { echo _a; }
find_dtbo_block_for_slot() { echo "$BLOCK"; }
dtbo_block_device_valid() { [ -f "$1" ]; }
runtime_patch_assets_compatible() { return 0; }
sync() { :; }
# Exercise the same unzip -p interface used by the Android installer.
unzip() { command unzip "$@"; }
BLOCK="$SIM/dtbo_a.img"; CONFLICT=0
fail() { echo "FAIL: $*"; cat "$SIM/output" 2>/dev/null; exit 1; }
run_install() {
  key="$1"; source="$2"
  MODDIR="$SIM/module-$key"
  mkdir -p "$MODDIR/bin" "$MODDIR/templates" "$MODDIR/image_sets"
  cp "$REPO/dist/image-sets/"*.zip "$MODDIR/image_sets/" || return 1
  cp "$REPO/investigation/dtbo-profile-patcher-windows-amd64.exe" "$MODDIR/bin/profile-patcher-host.exe"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$MODDIR/bin/profile-patcher-host.exe" > "$MODDIR/bin/dtbo-profile-patcher"
  chmod 0755 "$MODDIR/bin/dtbo-profile-patcher"
  cp "$REPO/templates/pps33-template.dtbo" "$MODDIR/templates/pps33-template.dtbo"
  cp "$source" "$BLOCK"
  before="$(hash_file "$BLOCK")"
  body="$SIM/install-body.sh"
  sed '1,5d' "$REPO/bin/install_images.sh" > "$body"
  ( . "$body" ) > "$SIM/output" 2>&1 || return 1
  [ "$(hash_file "$BLOCK")" = "$before" ] || fail installer-wrote-dtbo
  [ ! -e "$MODDIR/image_sets" ] || fail compressed-sets-left
  if [ "$key" = unknown ] || [ "$key" = conflict ]; then
    [ ! -e "$MODDIR/images" ] || fail unexpected-images
    [ ! -e "$MODDIR/installed_images.conf" ] || fail unexpected-install-record
  else
    [ "$(manifest_value "$MODDIR/installed_images.conf" family)" = "$key" ] || fail install-record-family
    [ "$(manifest_value "$MODDIR/installed_images.conf" firmware)" = "$(dtbo_family_label "$key")" ] || fail install-record-firmware
    [ "$(find "$MODDIR/images" -name '*.img' -type f | wc -l | tr -d ' ')" = 3 ] || fail triplet-count
    for profile in stock pps33 pps55; do
      [ "$(hash_file "$MODDIR/images/dtbo_${key}_$profile.img")" = "$(profile_sha_for_family "$key" "$profile")" ] || fail profile-hash
    done
  fi
  echo "PASS install $key: selected triplet only / no partition writes / archives cleaned"
}
run_install 400 "$REPO/images/dtbo_400_pps33.img" || fail install-400-pps
run_install 15_500 "$REPO/images/dtbo_15_500_stock.img" || fail install-15-500
run_install 16_500 "$REPO/images/dtbo_16_500_stock.img" || fail install-16-500
run_install unknown "$REPO/investigation/sim_unknown_stock.img" || fail install-unknown
CONFLICT=1
run_install conflict "$REPO/images/dtbo_15_500_stock.img" || fail install-conflicting-slots
echo 'installation image-set simulation OK'
