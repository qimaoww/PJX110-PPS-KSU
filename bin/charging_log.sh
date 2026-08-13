#!/system/bin/sh

LOG="$(dmesg 2>/dev/null)"

pps_line="$(printf '%s\n' "$LOG" | grep -E 'OPLUS_CHG\[PPS\].*oplus_third_pps_target_voltage_check' | tail -n 1)"
smart_line="$(printf '%s\n' "$LOG" | grep -E 'voltage_cell1\[[0-9]+\].*voltage_cell2\[[0-9]+\]' | tail -n 1)"
charge_line="$(printf '%s\n' "$LOG" | grep -E 'OPLUS_CHG\[oplus_charge_info\].*BATTERY\[' | tail -n 1)"

vtarget="$(printf '%s\n' "$pps_line" | sed -n 's/.*vtarget_mv=\([0-9]\+\).*/\1/p')"
itarget="$(printf '%s\n' "$pps_line" | sed -n 's/.*Itarget=\([0-9]\+\).*/\1/p')"
last_set="$(printf '%s\n' "$pps_line" | sed -n 's/.*last_vol_set_mv=\([0-9]\+\).*/\1/p')"
vbus_min="$(printf '%s\n' "$pps_line" | sed -n 's/.*vbus_min=\([0-9]\+\).*/\1/p')"

cell1="$(printf '%s\n' "$smart_line" | sed -n 's/.*voltage_cell1\[\([0-9]\+\)\].*/\1/p')"
cell2="$(printf '%s\n' "$smart_line" | sed -n 's/.*voltage_cell2\[\([0-9]\+\)\].*/\1/p')"
batt_i="$(printf '%s\n' "$smart_line" | sed -n 's/.*batt_current\[\(-\{0,1\}[0-9]\+\)\].*/\1/p')"

echo "=== PPS SUMMARY ==="
echo "pps_target_voltage_mv=${vtarget}"
echo "pps_target_current_ma=${itarget}"
echo "pps_last_set_voltage_mv=${last_set}"
echo "pps_vbus_min_mv=${vbus_min}"
echo "cell1_mv=${cell1}"
echo "cell2_mv=${cell2}"
echo "battery_current_ma=${batt_i}"
if [ -n "$cell1" ] && [ -n "$cell2" ]; then
  echo "battery_pack_mv=$((cell1 + cell2))"
fi
echo
echo "=== charging / PPS / PD / CPA / SC8517 ==="
printf '%s\n' "$LOG" | grep -Ei 'pps|cpa|usb.?pd|pdphy|sc8517|virtual.?pps|ufcs|vooc|charge.?pump|oplus_charge_info|voltage_cell1|voltage_cell2' | tail -n 320
