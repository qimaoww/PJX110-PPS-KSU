#!/system/bin/sh
MODDIR="${0%/*}"
# One bounded boot application, never poll or fight another program's changes.
count=0
while [ "$count" -lt 90 ]; do
  [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] || exit 0
  if [ "$(getprop sys.boot_completed)" = 1 ] && [ -r /proc/oplus-votable/UFCS_DISABLE/status ]; then
    sh "$MODDIR/bin/ufcs_control.sh" boot
    exit $?
  fi
  count=$((count + 1))
  sleep 2
done
exit 0
