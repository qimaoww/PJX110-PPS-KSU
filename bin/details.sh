#!/system/bin/sh
clean() { printf '%s' "$1" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
readf() { [ -r "$1" ] || return 1; cat "$1" 2>/dev/null | head -c 384; }
n=0
for root in /sys/class/power_supply/* /sys/class/oplus_chg/* /sys/kernel/oplus_chg/*; do
  [ -d "$root" ] || continue
  for f in "$root"/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    echo "$base" | grep -Eiq 'pps|pd_|pd$|adapter|charge_type|charger_type|cp_|ufcs|vooc|real_type|typec|current_max|voltage_max' || continue
    v="$(readf "$f")"
    [ -n "$v" ] || continue
    printf 'detail_%s=%s | %s\n' "$n" "$f" "$(clean "$v")"
    n=$((n+1))
    [ "$n" -ge 32 ] && exit 0
  done
done
