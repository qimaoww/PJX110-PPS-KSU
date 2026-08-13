#!/system/bin/sh

kv() { printf '%s=%s\n' "$1" "$2"; }

read_first() {
  for f in "$@"; do
    [ -r "$f" ] || continue
    IFS= read -r v < "$f" 2>/dev/null || continue
    [ -n "$v" ] || continue
    printf '%s' "$v"
    return 0
  done
}

USB="/sys/class/power_supply/usb"
raw="$(read_first "$USB/usb_type")"
real="$(read_first "$USB/real_type")"

# Linux power_supply enum attributes expose the selected value in [brackets].
active="$(printf '%s' "$raw" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"
[ -n "$active" ] || active="$real"
[ -n "$active" ] || active="$raw"

case "$(printf '%s' "$active" | tr '[:lower:]' '[:upper:]')" in
  PD_PPS|PPS) proto="PPS" ;;
  PD|PD_DRP|USB_PD) proto="PD" ;;
  UFCS) proto="UFCS" ;;
  SUPERVOOC|SVOOC) proto="SUPERVOOC" ;;
  VOOC) proto="VOOC" ;;
  QC*|HVDCP*) proto="QC" ;;
  DCP) proto="DCP / BC1.2" ;;
  CDP) proto="CDP / BC1.2" ;;
  SDP) proto="SDP / USB" ;;
  "") proto="未知" ;;
  *) proto="$active" ;;
esac

kv protocol "$proto"
kv active_usb_type "$active"
kv usb_type_raw "$raw"
kv real_type "$real"
kv protocol_source "power_supply usb_type 当前方括号项"

# Manual deep diagnostics only.
log="$(dmesg 2>/dev/null | grep -Ei '\[CPA\]|pps_online=|ufcs_online=' | tail -n 120)"
pps="$(printf '%s\n' "$log" | grep -Eio 'pps_online=(true|false|[01])' | tail -n1)"
ufcs="$(printf '%s\n' "$log" | grep -Eio 'ufcs_online=(true|false|[01])' | tail -n1)"
kv recent_pps_log "$pps"
kv recent_ufcs_log "$ufcs"
