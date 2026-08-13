#!/system/bin/sh

# Ultra-light WebUI telemetry collector.
# No grep/awk/sed/dmesg/sysfs scanning.
# Return raw sysfs values; JavaScript performs unit conversion.

kv() {
  printf '%s=%s\n' "$1" "$2"
}

read_one() {
  f="$1"
  [ -r "$f" ] || return 1
  IFS= read -r v < "$f" 2>/dev/null || return 1
  printf '%s' "$v"
}

read_first() {
  for f in "$@"; do
    [ -r "$f" ] || continue
    IFS= read -r v < "$f" 2>/dev/null || continue
    [ -n "$v" ] || continue
    printf '%s' "$v"
    return 0
  done
  return 1
}

read_first_nonzero_numeric() {
  first=""
  for f in "$@"; do
    [ -r "$f" ] || continue
    IFS= read -r v < "$f" 2>/dev/null || continue
    [ -n "$v" ] || continue
    [ -z "$first" ] && first="$v"
    case "$v" in
      -[0-9]*|[0-9]*)
        [ "$v" = "0" ] && continue
        printf '%s' "$v"
        return 0
        ;;
    esac
  done
  [ -n "$first" ] && printf '%s' "$first"
}

pick_ps() {
  for n in "$@"; do
    p="/sys/class/power_supply/$n"
    [ -d "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

BAT="$(pick_ps battery bms 2>/dev/null)"
USB="$(pick_ps usb usb_port 2>/dev/null)"
AC="$(pick_ps ac mains 2>/dev/null)"
USBMAIN="/sys/class/power_supply/usb-main"

[ -n "$BAT" ] || BAT="/sys/class/power_supply/battery"
[ -n "$USB" ] || USB="/sys/class/power_supply/usb"

capacity="$(read_first "$BAT/capacity")"
status="$(read_first "$BAT/status")"
health="$(read_first "$BAT/health")"
temp_raw="$(read_first "$BAT/temp")"
vbat_raw="$(read_first "$BAT/voltage_now")"
cell1_raw="$(read_first \
  "$BAT/voltage_cell1" \
  "$BAT/cell1_voltage" \
  "/sys/class/oplus_chg/battery/voltage_cell1" \
  "/sys/class/oplus_chg/battery/cell1_voltage")"
cell2_raw="$(read_first \
  "$BAT/voltage_cell2" \
  "$BAT/cell2_voltage" \
  "/sys/class/oplus_chg/battery/voltage_cell2" \
  "/sys/class/oplus_chg/battery/cell2_voltage")"
ibat_raw="$(read_first "$BAT/current_now")"
cycle_raw="$(read_first "$BAT/cycle_count")"
full_raw="$(read_first "$BAT/charge_full")"
design_raw="$(read_first "$BAT/charge_full_design")"
counter_raw="$(read_first "$BAT/charge_counter")"
technology="$(read_first "$BAT/technology")"

usb_online="$(read_first "$USB/online")"
ac_online=""
[ -n "$AC" ] && ac_online="$(read_first "$AC/online")"

usb_type_raw="$(read_first "$USB/usb_type")"
usb_real_type="$(read_first "$USB/real_type")"
typec_mode="$(read_first "$USB/typec_mode")"
scope="$(read_first "$USB/scope")"

# Prefer a non-zero measurement from known Qualcomm/OPlus input supplies.
usb_v_raw="$(read_first_nonzero_numeric \
  "$USB/voltage_now" \
  "$USBMAIN/voltage_now" \
  "$AC/voltage_now")"

usb_i_raw="$(read_first_nonzero_numeric \
  "$USB/current_now" \
  "$USBMAIN/current_now" \
  "$USBMAIN/input_current_now" \
  "$USB/input_current_now" \
  "$AC/current_now")"

usb_icl_raw="$(read_first_nonzero_numeric \
  "$USB/input_current_limit" \
  "$USBMAIN/input_current_limit" \
  "$AC/input_current_limit")"

mmi="$(read_first \
  "$BAT/mmi_charging_enable" \
  "/sys/class/oplus_chg/battery/mmi_charging_enable" \
  "/sys/class/oplus_chg/battery/mmi_chg")"

cool_down="$(read_first \
  "$BAT/cool_down" \
  "/sys/class/oplus_chg/battery/cool_down" \
  "/sys/class/oplus_chg/battery/cooldown")"

charging_enabled="$(read_first \
  "$BAT/charging_enabled" \
  "$USB/charging_enabled")"

input_suspend="$(read_first \
  "$BAT/input_suspend" \
  "$USB/input_suspend")"

kv timestamp "$(date '+%H:%M:%S' 2>/dev/null)"
kv capacity "$capacity"
kv status "$status"
kv health "$health"
kv temp_raw "$temp_raw"
kv vbat_raw "$vbat_raw"
kv cell1_raw "$cell1_raw"
kv cell2_raw "$cell2_raw"
kv ibat_raw "$ibat_raw"
kv cycle_count "$cycle_raw"
kv charge_full_raw "$full_raw"
kv charge_full_design_raw "$design_raw"
kv charge_counter_raw "$counter_raw"
kv technology "$technology"

kv usb_online "$usb_online"
kv ac_online "$ac_online"
kv usb_type_raw "$usb_type_raw"
kv usb_real_type "$usb_real_type"
kv usb_v_raw "$usb_v_raw"
kv usb_i_raw "$usb_i_raw"
kv usb_icl_raw "$usb_icl_raw"
kv typec_mode "$typec_mode"
kv scope "$scope"

kv mmi_charging_enable "$mmi"
kv cool_down "$cool_down"
kv charging_enabled "$charging_enabled"
kv input_suspend "$input_suspend"
