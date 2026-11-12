#!/system/bin/sh
BINDIR="${0%/*}"
MODDIR="${BINDIR%/bin}"
PPS_STATE_READ_ONLY=1
. "$MODDIR/common.sh"

# Runtime-only UFCS inhibit. Never accepts a node or partition path as input.
ufcs_paths() {
  UFCS_ROOT=/proc/oplus-votable/UFCS_DISABLE
  UFCS_CONFIG="$STATE_DIR/ufcs.conf"
  UFCS_LOCK="$STATE_DIR/ufcs.lock"
}
ufcs_paths
ufcs_kv() { printf '%s=%s\n' "$1" "$2"; }
ufcs_error() { ufcs_kv state error; ufcs_kv message "$1"; return 1; }

ufcs_config_read() {
  UFCS_SAVED_DISABLE=0; UFCS_BOOT_APPLY=0
  [ -e "$UFCS_CONFIG" ] || return 0
  [ -f "$UFCS_CONFIG" ] && [ ! -L "$UFCS_CONFIG" ] || return 1
  awk -F= 'NF != 2 {bad=1} $1 !~ /^(format|disable|boot_apply)$/ {bad=1}
    seen[$1]++ {bad=1} $1=="format" && $2!="1" {bad=1}
    $1=="disable" && $2!~/^[01]$/ {bad=1} $1=="boot_apply" && $2!~/^[01]$/ {bad=1}
    END {if(bad || seen["format"]!=1 || seen["disable"]!=1 || seen["boot_apply"]!=1)exit 1}' "$UFCS_CONFIG" || return 1
  UFCS_SAVED_DISABLE="$(manifest_value "$UFCS_CONFIG" disable)"
  UFCS_BOOT_APPLY="$(manifest_value "$UFCS_CONFIG" boot_apply)"
  [ "$UFCS_SAVED_DISABLE" = 1 ] || [ "$UFCS_BOOT_APPLY" = 0 ]
}
ufcs_snapshot() {
  [ -r "$UFCS_ROOT/status" ] && [ -r "$UFCS_ROOT/force_val" ] && [ -r "$UFCS_ROOT/force_active" ] || return 1
  UFCS_ACTIVE="$(cat "$UFCS_ROOT/force_active" 2>/dev/null)" || return 1
  UFCS_VALUE="$(cat "$UFCS_ROOT/force_val" 2>/dev/null)" || return 1
  case "$UFCS_ACTIVE" in 0|1) ;; *) return 1 ;; esac
  case "$UFCS_VALUE" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#UFCS_VALUE}" -le 10 ] || return 1
  UFCS_EFFECTIVE="$(sed -n 's/^UFCS_DISABLE: effective=.* type=Set_any v=\([01]\)$/\1/p' "$UFCS_ROOT/status")"
  case "$UFCS_EFFECTIVE" in 0|1) ;; *) return 1 ;; esac
  # A single refresh must not combine before/after values from another writer.
  [ "$UFCS_ACTIVE" = "$(cat "$UFCS_ROOT/force_active" 2>/dev/null)" ] &&
    [ "$UFCS_VALUE" = "$(cat "$UFCS_ROOT/force_val" 2>/dev/null)" ] || return 1
  if [ "$UFCS_ACTIVE" = 1 ]; then
    if [ "$UFCS_VALUE" = 0 ]; then [ "$UFCS_EFFECTIVE" = 0 ] || return 1
    else [ "$UFCS_EFFECTIVE" = 1 ] || return 1; fi
  fi
}
ufcs_status() (
  device_ok || { ufcs_error '仅支持 PJX110'; return 1; }
  config_ok=1
  ufcs_config_read || { config_ok=0; UFCS_SAVED_DISABLE=0; UFCS_BOOT_APPLY=0; }
  ufcs_kv schema 1
  ufcs_kv configured_disable "$UFCS_SAVED_DISABLE"
  ufcs_kv boot_apply "$UFCS_BOOT_APPLY"
  ufcs_kv config_valid "$config_ok"
  if ! ufcs_snapshot; then
    ufcs_kv state unavailable
    ufcs_kv can_set 0
    ufcs_kv message '接口不可用或状态变化，请刷新'
    return 0
  fi
  ufcs_kv state ok
  ufcs_kv active "$UFCS_ACTIVE"
  ufcs_kv value "$UFCS_VALUE"
  ufcs_kv effective_disabled "$UFCS_EFFECTIVE"
  requested=0
  [ "$UFCS_ACTIVE" = 1 ] && [ "$UFCS_VALUE" != 0 ] && requested=1
  ufcs_kv override_disabled "$requested"
  writable=0
  [ -w "$UFCS_ROOT/force_active" ] && [ -w "$UFCS_ROOT/force_val" ] && writable=1
  ufcs_kv can_set "$writable"
  # Never infer protocol negotiation from this inhibit bit.
)
ufcs_write_node() { printf '%s\n' "$2" > "$UFCS_ROOT/$1"; }
ufcs_restore_previous() {
  # Never reinstate a force-allow (active=1,value=0), which could mask protections.
  ufcs_write_node force_active 0 || return 1
  [ "$(cat "$UFCS_ROOT/force_active")" = 0 ] || return 1
  ufcs_write_node force_val "$UFCS_PREVIOUS_VALUE" || return 1
  if [ "$UFCS_PREVIOUS_ACTIVE" = 1 ] && [ "$UFCS_PREVIOUS_VALUE" != 0 ]; then
    ufcs_write_node force_active 1 || return 1
  fi
  ufcs_snapshot
}
ufcs_change_vote() {
  case "$1" in
    1)
      # Drop any existing debug override before replacing its value. This is
      # direct user control, not ownership-based refusal or a background loop.
      ufcs_write_node force_active 0 || return 1
      [ "$(cat "$UFCS_ROOT/force_active")" = 0 ] || return 1
      ufcs_write_node force_val 1 || return 1
      [ "$(cat "$UFCS_ROOT/force_val")" = 1 ] || return 1
      ufcs_write_node force_active 1 || return 1
      ufcs_snapshot && [ "$UFCS_ACTIVE" = 1 ] && [ "$UFCS_VALUE" = 1 ] && [ "$UFCS_EFFECTIVE" = 1 ]
      ;;
    0)
      # Releasing the override returns all thermal/current votes to the driver.
      # Do not write an active zero-value override to force UFCS on.
      ufcs_write_node force_active 0 || return 1
      ufcs_snapshot && [ "$UFCS_ACTIVE" = 0 ]
      ;;
    *) return 1 ;;
  esac
}
ufcs_mutate() (
  action="$1"; desired="${2:-}"; boot_apply="${3:-}"
  [ "$(id -u)" = 0 ] && device_ok || { ufcs_error '需要目标设备 Root 权限'; return 1; }
  case "$action" in
    set) case "$desired:$boot_apply" in 0:0|1:0|1:1) ;; *) ufcs_error '无效设置'; return 1 ;; esac ;;
    boot|restore) ;;
    *) return 1 ;;
  esac
  mkdir -p "$STATE_DIR" || return 1
  acquire_dtbo_lock "$UFCS_LOCK" || { ufcs_error 'UFCS 操作进行中'; return 1; }
  changing=0; temporary="$UFCS_CONFIG.tmp.$$"
  cleanup_ufcs() {
    rc=$?
    trap - EXIT INT TERM HUP
    if [ "$changing" = 1 ]; then
      if ufcs_restore_previous; then ufcs_kv rollback restored
      else ufcs_kv rollback failed; ufcs_kv message '状态恢复失败，请检查接口或重启'; fi
    fi
    rm -f "$temporary"
    release_dtbo_lock "$UFCS_LOCK"
    exit "$rc"
  }
  trap cleanup_ufcs EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if [ "$action" = boot ]; then
    [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] || return 0
    ufcs_config_read || { ufcs_error '开机设置损坏，未应用'; return 1; }
    [ "$UFCS_SAVED_DISABLE:$UFCS_BOOT_APPLY" = 1:1 ] || return 0
    desired=1
  elif [ "$action" = restore ]; then
    desired=0; boot_apply=0
    # An unconfigured module must not clear a different tool's override.
    ufcs_config_read && [ "$UFCS_SAVED_DISABLE" = 1 ] || return 0
  fi
  [ ! -L "$UFCS_CONFIG" ] && [ ! -e "$temporary" ] || return 1
  ufcs_snapshot || { ufcs_error 'UFCS 接口不可用或语义不匹配'; return 1; }
  [ -w "$UFCS_ROOT/force_val" ] && [ -w "$UFCS_ROOT/force_active" ] || { ufcs_error '接口不可写'; return 1; }
  UFCS_PREVIOUS_ACTIVE="$UFCS_ACTIVE"; UFCS_PREVIOUS_VALUE="$UFCS_VALUE"
  if [ "$action" != boot ]; then
    (umask 077; printf 'format=1\ndisable=%s\nboot_apply=%s\n' "$desired" "$boot_apply" > "$temporary") || return 1
  fi
  changing=1
  ufcs_change_vote "$desired" || { ufcs_error '接口写入或回读失败'; return 1; }
  if [ "$action" != boot ]; then
    mv -f "$temporary" "$UFCS_CONFIG" || { ufcs_error '设置保存失败'; return 1; }
  fi
  changing=0
  ufcs_kv result applied
  ufcs_status
)
ufcs_main() {
  case "${1:-status}" in
    status) [ "$#" -le 1 ] && ufcs_status ;;
    set) [ "$#" = 3 ] && ufcs_mutate set "$2" "$3" ;;
    boot|restore) [ "$#" = 1 ] && ufcs_mutate "$1" ;;
    *) ufcs_error 'usage: ufcs_control.sh status|set <0|1> <0|1>|boot|restore' ;;
  esac
}
ufcs_main "$@"
