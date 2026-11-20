#!/system/bin/sh
BINDIR="${0%/*}"
MODDIR="${BINDIR%/bin}"
. "$MODDIR/common.sh"

# Confirmation values only: discover the actual device and slot independently.
[ "$#" = 2 ] && is_sha256 "$2" || exit 2
case "$1" in _a|_b) ;; *) exit 2 ;; esac
device_ok || exit 10
lock="$STATE_DIR/toggle.lock"
acquire_dtbo_lock "$lock" || { echo '另一个 DTBO 操作正在执行。'; exit 9; }
tmp=''
trap '[ -z "$tmp" ] || rm -f "$tmp"; release_dtbo_lock "$lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
slot="$(trusted_slot_suffix)"
[ "$slot" = "$1" ] && ! trusted_slot_conflict || { echo '当前槽位已变化或不可信。'; exit 11; }
block="$(find_dtbo_block_for_slot "$slot")" && dtbo_write_target_valid "$block" "$slot" || exit 11
current="$(block_hash "$block")"
[ "$current" = "$2" ] || { echo '当前 DTBO 已变化，请重新校验。'; exit 12; }
family="$(dtbo_family_for_hash "$current")" || exit 12
[ "$(full_stock_owner "$slot" "$current")" = "$family" ] && bundled_family_assets_valid "$family" || {
  echo '未匹配当前槽的原厂 DTBO 与完整内置镜像集。'; exit 13;
}
choice="$(static_choice_path "$slot")" || exit 14
[ ! -L "$choice" ] && { [ ! -e "$choice" ] || [ -f "$choice" ]; } || exit 14
umask 077
tmp="$(mktemp "$STATE_DIR/.full-choice.XXXXXX")" || exit 14
printf '%s\n' "$current" > "$tmp" || exit 14
dtbo_write_target_valid "$block" "$slot" && [ "$(block_hash "$block")" = "$current" ] || exit 12
mv -f "$tmp" "$choice" || exit 14
tmp=''
echo '已选择内置全分区模式，未写入 DTBO。'
