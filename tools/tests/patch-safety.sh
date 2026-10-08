#!/usr/bin/env bash
# File-only fault injection. This never opens or writes a real block device.
set -u
REPO="$(pwd -P)"
TMP="$(mktemp -d "$REPO/investigation/patch-safety.XXXXXX")" || exit 1
cleanup() {
  case "$TMP" in "$REPO"/investigation/patch-safety.*) rm -rf "$TMP" ;; *) exit 99 ;; esac
}
trap cleanup EXIT
PPS_STATE_READ_ONLY=1
MODDIR="$TMP/module"
. "$REPO/common.sh"
STATE_DIR="$TMP/state"; BACKUP_DIR="$STATE_DIR/backup"; LOG_DIR="$STATE_DIR/logs"
DYNAMIC_DIR="$STATE_DIR/dynamic"; RESCUE_DIR="$STATE_DIR/rescue"
mkdir -p "$DYNAMIC_DIR/slot_a" "$RESCUE_DIR" "$MODDIR" "$BACKUP_DIR" "$LOG_DIR"
BLOCK="$TMP/dtbo_a.img"
STOCK="$REPO/images/dtbo_400_stock.img"
P33="$REPO/images/dtbo_400_pps33.img"
P55="$REPO/images/dtbo_400_pps55.img"
S_SHA="$(hash_file "$STOCK")"; P33_SHA="$(hash_file "$P33")"; P55_SHA="$(hash_file "$P55")"
CALLS="$TMP/writes"; : > "$CALLS"
TRUSTED=_a; CONFLICT=0; SIZE_FAIL=0; DD_FAIL_ONCE=0; COPY_BAD=0
trusted_slot_conflict() { [ "$CONFLICT" = 1 ]; }
trusted_slot_suffix() { echo "$TRUSTED"; }
find_dtbo_block_for_slot() { [ "$1" = _a ] || return 1; echo "$BLOCK"; }
# Only this test replaces the production -b predicate with a regular-file check.
dtbo_block_device_valid() { [ -f "$1" ]; }
block_size_bytes() { [ "$SIZE_FAIL" = 0 ] || return 1; wc -c < "$1" | tr -d ' '; }
runtime_patch_assets_compatible() { return 1; }
sync() { :; }
cp() {
  if [ "$COPY_BAD" = 1 ]; then printf 'partial-copy' > "${@: -1}"; return 0; fi
  command cp "$@"
}
dd() {
  output=""; for arg in "$@"; do case "$arg" in of=*) output="${arg#of=}" ;; esac; done
  [ "$output" = "$BLOCK" ] || { echo "unsafe test output" >&2; return 99; }
  printf 'write\n' >> "$CALLS"
  if [ "$DD_FAIL_ONCE" = 1 ]; then DD_FAIL_ONCE=0; printf 'partial' > "$BLOCK"; return 1; fi
  command dd "$@"
}
count() { wc -l < "$CALLS" | tr -d ' '; }
fail() { echo "FAIL: $*"; cat "$TMP/result" 2>/dev/null; exit 1; }
reject_write() {
  before="$(count)"
  if write_verify "$@" > "$TMP/result" 2>&1; then fail "unexpected write accepted"; fi
  [ "$(count)" = "$before" ] || fail "rejected input reached dd"
}
command cp "$STOCK" "$BLOCK"
write_dynamic_manifest _a patch "$S_SHA" "$P33_SHA" "$P55_SHA" || fail manifest
if write_dynamic_manifest _a patch "$S_SHA" "$S_SHA" "$P55_SHA"; then fail duplicate-endpoint; fi
echo 'PASS duplicate endpoint hashes rejected'
write_dynamic_manifest _a full "$S_SHA" "$P33_SHA" "$P55_SHA" || fail full
if write_dynamic_manifest _a patch "$S_SHA" "$P33_SHA" "$P55_SHA"; then fail full-to-patch; fi
[ "$(dynamic_mode_for_slot _a)" = full ] || fail mode
echo 'PASS shared manifest helper rejects Full -> Patch'
# The following section specifically exercises the static writer with no
# dynamic endpoint ownership. Restore the fixture registration for rescue tests.
mv "$DYNAMIC_DIR/slot_a/manifest" "$TMP/full-manifest"

CONFLICT=1; reject_write "$P33" "$P33_SHA" "$BLOCK" "$STOCK" "$S_SHA" _a "$S_SHA"; CONFLICT=0
TRUSTED=_b; reject_write "$P33" "$P33_SHA" "$BLOCK" "$STOCK" "$S_SHA" _a "$S_SHA"; TRUSTED=_a
reject_write "$P33" "$P33_SHA" "$TMP/other_partition.img" "$STOCK" "$S_SHA" _a "$S_SHA"
echo 'PASS fresh trusted-slot conflicts and non-DTBO targets rejected'
if dump_block "$TMP/other_partition.img" "$TMP/dump.img"; then fail non-dtbo-dump; fi
if dump_block "$BLOCK" /dev/block/other_partition; then fail device-dump-output; fi
echo 'PASS dump helper cannot read other partitions or write a device'

reject_write "$REPO/images/dtbo_1001_pps33.img" "$F1001_PPS33_SHA" "$BLOCK" "$REPO/images/dtbo_1001_stock.img" "$F1001_STOCK_SHA" _a "$S_SHA"
echo 'PASS cross-firmware image rejected'
SIZE_FAIL=1; reject_write "$P33" "$P33_SHA" "$BLOCK" "$STOCK" "$S_SHA" _a "$S_SHA"; SIZE_FAIL=0
echo 'PASS unknown partition size rejected'
command cp "$P55" "$BLOCK"
reject_write "$P33" "$P33_SHA" "$BLOCK" "$STOCK" "$S_SHA" _a "$S_SHA"
command cp "$STOCK" "$BLOCK"
echo 'PASS partition changed after preparation rejected'

command cp "$STOCK" "$TMP/corrupt-stock.img"
printf 'BAD!' | command dd of="$TMP/corrupt-stock.img" bs=1 conv=notrunc 2>/dev/null
reject_write "$P33" "$P33_SHA" "$BLOCK" "$TMP/corrupt-stock.img" "$S_SHA" _a "$S_SHA"
echo 'PASS corrupted rollback backup blocks PPS before dd'
DD_FAIL_ONCE=1
if write_verify "$P33" "$P33_SHA" "$BLOCK" "$STOCK" "$S_SHA" _a "$S_SHA" > "$TMP/result" 2>&1; then fail partial-write-status; fi
DD_FAIL_ONCE=0
[ "$(hash_file "$BLOCK")" = "$S_SHA" ] || fail partial-write-rollback
echo 'PASS partial-write failure restores and verifies exact stock'

mv "$TMP/full-manifest" "$DYNAMIC_DIR/slot_a/manifest"
generation="$RESCUE_DIR/slot_a/$S_SHA"; mkdir -p "$generation"
command cp "$STOCK" "$generation/stock.img"
printf 'format=1\nslot_suffix=_a\nstock_sha=%s\nstock_size=%s\npatcher_sha=%s\n' "$S_SHA" "$(file_size_bytes "$STOCK")" "$PPS_PATCHER_SHA256" > "$generation/manifest"
[ "$(dynamic_stock_image_for_recovery _a)" = "$generation/stock.img" ] || fail rescue-mirror
if dynamic_assets_valid _a full; then fail mirror-pps-green-light; fi
echo 'PASS exact rescue mirror restores stock but does not enable PPS'
sed -i 's/slot_suffix=_a/slot_suffix=_b/' "$generation/manifest"
if dynamic_stock_image_for_recovery _a; then fail wrong-slot-mirror; fi
echo 'PASS wrong-slot rescue manifest rejected'

destination="$DYNAMIC_DIR/slot_a/stock.img"
command cp "$STOCK" "$destination"
COPY_BAD=1
if atomic_dtbo_copy "$REPO/images/dtbo_1001_stock.img" "$destination" "$F1001_STOCK_SHA"; then fail bad-copy; fi
COPY_BAD=0
[ "$(hash_file "$destination")" = "$S_SHA" ] || fail atomic-copy-overwrite
echo 'PASS interrupted image copy preserves previous backup'
if atomic_dtbo_copy "$STOCK" "$BLOCK" "$S_SHA"; then fail atomic-block-target; fi
echo 'PASS persistent-copy helper cannot target a partition'

# Exercise only the standalone journal helpers, with fixture directories.
eval "$(sed -n '/^last_written_slot() {$/,/^}$/p' "$REPO/rescue/restore_stock.sh")"
eval "$(sed -n '/^clear_matching_journal() {$/,/^}$/p' "$REPO/rescue/restore_stock.sh")"
RESCUE_ROOT="$RESCUE_DIR"; SLOT=_a; STOCK_SHA="$S_SHA"
printf 'format=1\nslot_suffix=_b\nstock_sha=%s\ntarget_sha=%s\n' "$S_SHA" "$P33_SHA" > "$RESCUE_ROOT/last_write"
clear_matching_journal || fail other-slot-clear
[ -f "$RESCUE_ROOT/last_write" ] || fail other-slot-journal-erased
printf 'format=1\nslot_suffix=_a\nstock_sha=%s\ntarget_sha=%s\n' "$P55_SHA" "$P33_SHA" > "$RESCUE_ROOT/last_write"
clear_matching_journal || fail other-generation-clear
[ -f "$RESCUE_ROOT/last_write" ] || fail other-generation-journal-erased
printf 'format=1\nslot_suffix=_a\nstock_sha=%s\ntarget_sha=%s\n' "$S_SHA" "$P33_SHA" > "$RESCUE_ROOT/last_write"
clear_matching_journal || fail matching-clear
[ ! -e "$RESCUE_ROOT/last_write" ] || fail matching-journal-left
echo 'PASS rescue clears only the matching slot and stock generation journal'

if bash "$REPO/rescue/restore_stock.sh" check last > "$TMP/result" 2>&1; then fail missing-journal; fi
grep -q 'refusing to guess a target slot' "$TMP/result" || fail missing-journal-reason
echo 'PASS missing last-write journal cannot guess a rescue slot'
echo 'patch safety fault injection OK'
