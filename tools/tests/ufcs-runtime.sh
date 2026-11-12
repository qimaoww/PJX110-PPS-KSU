#!/usr/bin/env bash
# File fixtures only; no device/proc writes. Run from the repository root.
set -eu
REPO="$(pwd -P)"
SIM="$(mktemp -d "$REPO/investigation/ufcs-runtime.XXXXXX")"
cleanup_test() { case "$SIM" in "$REPO"/investigation/ufcs-runtime.*) rm -rf "$SIM" ;; *) exit 99 ;; esac; }
trap cleanup_test EXIT
PPS_STATE_READ_ONLY=1
MODDIR="$SIM/module"
. "$REPO/common.sh"
STATE_DIR="$SIM/state"
mkdir -p "$STATE_DIR" "$MODDIR" "$SIM/nodes"
eval "$(sed '1,5d; $d' "$REPO/bin/ufcs_control.sh")"
UFCS_ROOT="$SIM/nodes"; UFCS_CONFIG="$STATE_DIR/ufcs.conf"; UFCS_LOCK="$STATE_DIR/ufcs.lock"
id() { echo 0; }
device_ok() { [ "$DEVICE_OK" = 1 ]; }
DEVICE_OK=1; FAIL_NODE=''; DRIVER_DISABLE=0
CALLS="$SIM/writes"
: > "$CALLS"
printf '0\n' > "$UFCS_ROOT/force_active"
printf '0\n' > "$UFCS_ROOT/force_val"
update_status() {
  active="$(cat "$UFCS_ROOT/force_active")"; value="$(cat "$UFCS_ROOT/force_val")"
  effective="$DRIVER_DISABLE"; client=THERMAL_VOTER
  if [ "$active" = 1 ]; then effective=0; [ "$value" = 0 ] || effective=1; client=DEBUG_FORCE_CLIENT; fi
  printf 'UFCS_DISABLE: effective=%s type=Set_any v=%s\n' "$client" "$effective" > "$UFCS_ROOT/status"
}
update_status
ufcs_write_node() {
  case "$1:$2" in force_val:[0-9]*|force_active:0|force_active:1) ;; *) return 99 ;; esac
  printf '%s=%s\n' "$1" "$2" >> "$CALLS"
  if [ "$FAIL_NODE" = "$1" ]; then FAIL_NODE=''; return 1; fi
  printf '%s\n' "$2" > "$UFCS_ROOT/$1"
  update_status
}
run() { ufcs_main "$@" > "$SIM/output" 2>&1; }
fail() { echo "FAIL: $*"; cat "$SIM/output"; exit 1; }
field() { sed -n "s/^$1=//p" "$SIM/output" | head -n 1; }
expect() { [ "$(field "$1")" = "$2" ] || fail "$1 != $2"; }
writes() { wc -l < "$CALLS" | tr -d ' '; }
run status || fail initial-status
expect override_disabled 0; expect boot_apply 0
before="$(writes)"; run boot || fail fresh-boot; [ "$(writes)" = "$before" ] || fail boot-default-write
run set 1 1 || fail disable; expect result applied; expect effective_disabled 1; expect boot_apply 1
run set 0 0 || fail release; expect active 0; expect effective_disabled 0; expect boot_apply 0
echo 'PASS disable/readback/save/release; defaults never apply on boot'
# Explicitly override another tool; no ownership refusal, never force allow.
printf '1\n' > "$UFCS_ROOT/force_active"; printf '9\n' > "$UFCS_ROOT/force_val"; update_status
run set 1 0 || fail explicit-overwrite; expect value 1; expect override_disabled 1
DRIVER_DISABLE=1
run set 0 0 || fail thermal-release; expect active 0; expect effective_disabled 1
echo 'PASS direct user overwrite; release preserves driver thermal inhibition'
DRIVER_DISABLE=0; update_status
run set 1 1 || fail boot-setup
printf '0\n' > "$UFCS_ROOT/force_active"; update_status
run status || fail external-release; expect override_disabled 0; expect boot_apply 1
run boot || fail reapply; expect active 1; expect effective_disabled 1
touch "$MODDIR/disable"
before="$(writes)"; run boot || fail disabled-module; [ "$(writes)" = "$before" ] || fail disabled-module-wrote
rm "$MODDIR/disable"
run restore || fail uninstall-restore
run status || fail after-restore; expect active 0; expect boot_apply 0
echo 'PASS boot reapply, external live readback, disabled module and uninstall restoration'
run set 1 1 || fail rollback-setup
before_config="$(hash_file "$UFCS_CONFIG")"
FAIL_NODE=force_val
if run set 1 0; then fail accepted-write-failure; fi
[ "$(hash_file "$UFCS_CONFIG")" = "$before_config" ] || fail failure-saved-preference
[ "$(cat "$UFCS_ROOT/force_active")" = 1 ] && [ "$(cat "$UFCS_ROOT/force_val")" = 1 ] || fail rollback-original
FAIL_NODE=''
run set 0 0 || fail release-after-failure
echo 'PASS write failure rolls back previous inhibit and retains saved preference'
# Releasing a force-allow on rollback must never reinstate it.
printf '1\n' > "$UFCS_ROOT/force_active"; printf '0\n' > "$UFCS_ROOT/force_val"; update_status
FAIL_NODE=force_val
if run set 1 0; then fail force-allow-failure-accepted; fi
[ "$(cat "$UFCS_ROOT/force_active")" = 0 ] || fail rollback-reenabled-force-allow
FAIL_NODE=''
echo 'PASS rollback never restores a force-allow that could mask protection'
before="$(writes)"
if run set 0 1; then fail invalid-setting; fi
if run set '1;echo BAD' 0; then fail injected-argument; fi
printf 'format=1\ndisable=1\nboot_apply=1\nboot_apply=0\n' > "$UFCS_CONFIG"
if run boot; then fail corrupt-config-boot; fi
[ "$(writes)" = "$before" ] || fail rejected-write
run status || fail corrupt-config-status; expect config_valid 0
run set 1 0 || fail repair-config
rm "$UFCS_CONFIG"
printf 'sentinel\n' > "$SIM/outside"
if MSYS=winsymlinks:nativestrict ln -s "$SIM/outside" "$UFCS_CONFIG" 2>/dev/null && [ -L "$UFCS_CONFIG" ]; then
  if run set 1 1; then fail config-symlink; fi
  [ "$(cat "$SIM/outside")" = sentinel ] || fail symlink-written
  rm "$UFCS_CONFIG"
  echo 'PASS config symlink rejected'
else
  rm -f "$UFCS_CONFIG"
  echo 'SKIP native symlink creation unavailable on this host'
fi
mv "$UFCS_ROOT/status" "$SIM/status"
run status || fail missing-state; expect state unavailable; expect can_set 0
if run set 1 1; then fail missing-write; fi
mv "$SIM/status" "$UFCS_ROOT/status"
DEVICE_OK=0
if run set 1 1; then fail wrong-device; fi
echo 'PASS invalid args/config, missing interface and wrong device fail closed'
if grep -q '^force_active=1$' "$CALLS"; then :; else fail no-disable-exercised; fi
echo 'UFCS runtime regression OK'
