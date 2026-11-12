#!/system/bin/sh
# WebUI read-only entry point. Never route mutations through timeout.
BINDIR="${0%/*}"
case "$#:$1" in
  1:status.sh) seconds=4 ;;
  1:boot_state.sh) seconds=6 ;;
  1:dtbo_state.sh) seconds=25 ;;
  1:charging_log.sh) seconds=12 ;;
  1:details.sh) seconds=8 ;;
  2:ufcs_control.sh) [ "$2" = status ] || exit 2; seconds=4 ;;
  *) exit 2 ;;
esac
# A native deadline bounds work even when the WebView loses its callback.
for busybox in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
  if [ -x "$busybox" ]; then
    exec "$busybox" timeout -s KILL "$seconds" sh "$BINDIR/$1" ${2:+"$2"}
  fi
done
if command -v timeout >/dev/null 2>&1; then
  exec timeout -s KILL "$seconds" sh "$BINDIR/$1" ${2:+"$2"}
fi
echo 'Read timeout tool unavailable' >&2
exit 127
