#!/system/bin/sh

# Read-only telemetry: fixed nodes, explicit units, no DTBO reads or cache.
SYS="${PPS_SYSFS_ROOT:-/sys}"
PS="$SYS/class/power_supply"
OPLUS="$SYS/class/oplus_chg/battery"
kv() { printf '%s=%s\n' "$1" "$2"; }
read_value() {
  value=""
  [ -r "$1" ] || return 1
  IFS= read -r value < "$1" 2>/dev/null || [ -n "$value" ] || return 1
  [ -n "$value" ]
}
numeric() {
  number="$1"
  case "$number" in -*) number="${number#-}" ;; esac
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
}
emit_text() {
  key="$1"; shift
  for path in "$@"; do
    read_value "$path" || continue
    kv "$key" "$value"
    return 0
  done
  kv "$key" ""
}
# unit:path candidates. Zero is valid, not a reason to use a stale fallback.
emit_metric() {
  key="$1"; shift
  for candidate in "$@"; do
    unit="${candidate%%:*}"; path="${candidate#*:}"
    read_value "$path" && numeric "$value" || continue
    kv "$key" "$value"
    kv "${key}_unit" "$unit"
    kv "${key}_source" "$path"
    return 0
  done
  kv "$key" ""
  kv "${key}_unit" ""
  kv "${key}_source" ""
}
BAT="$PS/battery"
[ -d "$BAT" ] || BAT="$PS/bms"
USB="$PS/usb"
[ -d "$USB" ] || USB="$PS/usb_port"
AC="$PS/ac"
[ -d "$AC" ] || AC="$PS/mains"
MAIN="$PS/usb-main"
OPLUS_DRIVER=0
BAT_CURRENT_UNIT=uA
# OPlus GKI battery current_now is GAUGE_ITEM_CURR in mA; its USB current_now
# is explicitly multiplied by 1000. Never apply one unit to both supplies.
if [ -d "$OPLUS" ] || { read_value "$BAT/model_name" && [ "$value" = "oplus battery" ]; }; then
  OPLUS_DRIVER=1
  BAT_CURRENT_UNIT=mA
fi
kv schema 2
kv battery_driver "$OPLUS_DRIVER"
if [ ! -d "$BAT" ]; then
  kv state unavailable
  kv message "Battery supply is unavailable"
  exit 1
fi
emit_metric capacity "percent:$BAT/capacity"
emit_text status "$BAT/status"
emit_text health "$BAT/health"
emit_metric temp_raw "deciC:$BAT/temp"
emit_metric vbat_raw "uV:$BAT/voltage_now"
# Vendor cell nodes may expose mV or uV; accept only plausible cell voltages.
if [ "$OPLUS_DRIVER" = 1 ]; then
  # On PJX110 the OPlus voltage_now/voltage_min pair exposes cell max/min.
  emit_metric cell1_raw "cellV:$BAT/voltage_cell1" "cellV:$BAT/cell1_voltage" "cellV:$OPLUS/voltage_cell1" "uV:$BAT/voltage_now"
  emit_metric cell2_raw "cellV:$BAT/voltage_cell2" "cellV:$BAT/cell2_voltage" "cellV:$OPLUS/voltage_cell2" "uV:$BAT/voltage_min"
else
  emit_metric cell1_raw "cellV:$BAT/voltage_cell1" "cellV:$BAT/cell1_voltage"
  emit_metric cell2_raw "cellV:$BAT/voltage_cell2" "cellV:$BAT/cell2_voltage"
fi
emit_metric ibat_raw "$BAT_CURRENT_UNIT:$BAT/current_now"
emit_metric cycle_count "count:$BAT/cycle_count"
emit_metric charge_full_raw "uAh:$BAT/charge_full"
emit_metric charge_full_design_raw "uAh:$BAT/charge_full_design"
emit_text usb_online "$USB/online"
emit_text ac_online "$AC/online"
emit_text usb_type_raw "$USB/usb_type"
emit_text usb_real_type "$USB/real_type"
emit_text typec_mode "$USB/typec_mode"
emit_metric pps_mode "enum:$OPLUS/ppschg_ing"
emit_metric fast_chg_type "enum:$SYS/class/oplus_chg/usb/fast_chg_type"
emit_metric vooc_active "enum:$OPLUS/voocchg_ing"
emit_metric usb_v_raw "uV:$USB/voltage_now" "uV:$MAIN/voltage_now" "uV:$AC/voltage_now"
emit_metric usb_i_raw "uA:$USB/current_now" "uA:$MAIN/current_now" "uA:$MAIN/input_current_now" "uA:$USB/input_current_now" "uA:$AC/current_now"
emit_metric usb_icl_raw "uA:$USB/input_current_limit" "uA:$MAIN/input_current_limit" "uA:$AC/input_current_limit"
emit_text mmi_charging_enable "$BAT/mmi_charging_enable" "$OPLUS/mmi_charging_enable" "$OPLUS/mmi_chg"
emit_text cool_down "$BAT/cool_down" "$OPLUS/cool_down" "$OPLUS/cooldown"
kv state ok
kv timestamp "$(date '+%H:%M:%S' 2>/dev/null)"
