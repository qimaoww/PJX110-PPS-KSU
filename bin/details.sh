#!/system/bin/sh
# Bounded, read-only diagnostic scan; no DTBO access or arbitrary root argument.
SYS="${PPS_SYSFS_ROOT:-/sys}"
TIMEOUT=""
for candidate in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
  if [ -x "$candidate" ]; then TIMEOUT="$candidate"; break; fi
done
if [ -z "$TIMEOUT" ]; then
  TIMEOUT="$(command -v timeout)" || { echo 'Scan timeout tool unavailable' >&2; exit 1; }
fi
read_node() {
  case "$TIMEOUT" in
    */busybox) "$TIMEOUT" timeout -s KILL 1 head -c 384 "$1" 2>/dev/null ;;
    *) "$TIMEOUT" -s KILL 1 head -c 384 "$1" 2>/dev/null ;;
  esac
}
n=0
attempts=0
skipped=0
limited=0
for root in "$SYS"/class/power_supply/* "$SYS"/class/oplus_chg/* "$SYS"/kernel/oplus_chg/*; do
  [ -d "$root" ] || continue
  for f in "$root"/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    # Shell matching avoids a grep subprocess for every sysfs entry.
    case "$base" in
      usb_type|*pps*|*pd_*|*pd|*adapter*|*charge_type*|*charger_type*|*cp_*|*ufcs*|*vooc*|*real_type*|*typec*|*current_max*|*voltage_max*) ;;
      *) continue ;;
    esac
    attempts=$((attempts+1))
    if v="$(read_node "$f")"; then
      if [ -n "$v" ]; then
        v="$(printf '%s' "$v" | tr '\r\n' '  ')"
        printf 'detail_%s=%s | %s\n' "$n" "$f" "$v"
        n=$((n+1))
      fi
    else
      skipped=$((skipped+1))
    fi
    if [ "$n" -ge 32 ] || [ "$attempts" -ge 48 ]; then limited=1; break 2; fi
  done
done
printf 'scan_count=%s\nscan_skipped=%s\nscan_limited=%s\nscan_complete=1\n' "$n" "$skipped" "$limited"
