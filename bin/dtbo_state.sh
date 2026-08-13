#!/system/bin/sh
MODDIR="${0%/*}"
MODDIR="${MODDIR%/bin}"
. "$MODDIR/common.sh"

clean() { printf '%s' "$1" | tr '\r\n=' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
kv() { k="$1"; shift; printf '%s=%s\n' "$k" "$(clean "$*")"; }

slot="$(slot_suffix)"
source="$(slot_source)"
trusted_conflict=0
trusted_slot_conflict && trusted_conflict=1
prop_conflict=0
prop_slot_conflict && prop_conflict=1

[ -n "$slot" ] || { kv state error; kv message "Cannot determine A/B slot"; exit 1; }
label="$(slot_label "$slot")"
block="$(find_dtbo_block_for_slot "$slot")" || { kv state error; kv message "DTBO block not found"; exit 1; }
cur="$(block_hash "$block")" || { kv state error; kv message "Failed to read DTBO"; exit 1; }

state="$(detect_profile_for_hash "$slot" "$cur")"
case "$state" in
  stock) text="原厂 DTBO" ;;
  pps33) text="PPS 33W DTBO" ;;
  pps55) text="PPS 55W DTBO" ;;
  *) text="未知/不支持的 DTBO"; state=unknown ;;
esac

kv state "$state"
kv label "$text"
kv slot "$label"
kv slot_suffix "$slot"
kv slot_source "$source"
kv trusted_slot_conflict "$trusted_conflict"
kv prop_slot_conflict "$prop_conflict"
kv block "$block"
kv sha256 "$cur"
kv stock_sha "$(stock_sha_for_slot "$slot")"
kv pps33_sha "$(pps33_sha_for_slot "$slot")"
kv pps55_sha "$(pps55_sha_for_slot "$slot")"
kv ab_supported "A/B"
