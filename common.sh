#!/system/bin/sh

F400_STOCK_SHA="1e9b72599353e5d0009fcfe081185ebabd715a2e8ed1e2a8f0b695bc12c3cf17"
F400_PPS33_SHA="6a51bf1c7aa527e11a1c92a975ccda634798ce7cc9a2cfbac3d960feb6b54471"
F400_PPS55_SHA="0e09c040605aa44de44179969d57a4829180adeada10a65c45d844137ed29aaa"
F301_STOCK_SHA="4e6e85b2e4029a862e64bf7d5e74704a7563c980b696ee904cd72aaf59b4674e"
F301_PPS33_SHA="053b3f3105cb30f9a2f09c3d8e510467561778ab847b1aae035c84c24ba9e8a2"
F301_PPS55_SHA="8695bf93da80e1c4e7eb4734998cb3b6826cd8f9193f7cc749b14e09e291db97"
F701_STOCK_SHA="e8dd37efa99c0f59dc839e8b4582db9d619b6624e99bbdb0aee3e3f4c1336918"
F701_PPS33_SHA="ee3ef9ca6edb70438a7fa77e1592501f99a170b0befcc3f383bac8d2b9161f5f"
F701_PPS55_SHA="e0185cf9ae023d9dfbe685d1f859ed07c6948f7ac16bdeaf15a5e74f6d1bc949"
F1001_STOCK_SHA="ad6897d8a52cc8fdcb4423f1716c6c4506ee53338c218b2eaf2811162e7cb011"
F1001_PPS33_SHA="abcf2d37de193e0146c401332537ce34bd8c1444a5f8a4ea8ff880c8177195cc"
F1001_PPS55_SHA="817f4f34b2c320cbd9bd5833e3ba6393759c92627945fcc822aa3815e442c990"

STATE_DIR="/data/adb/PJX110_PPS_KSU"
BACKUP_DIR="$STATE_DIR/backup"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$BACKUP_DIR" "$LOG_DIR" 2>/dev/null

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    busybox sha256sum "$1" | awk '{print $1}'
  fi
}

device_ok() {
  vals="$(
    for k in ro.product.device ro.product.vendor.device ro.product.odm.device ro.build.product ro.product.model; do
      getprop "$k" 2>/dev/null
    done
  )"
  echo "$vals" | grep -Eiq 'corvette|PJX110'
}

normalize_slot() {
  s="$(printf '%s' "$1" | sed "s/[[:space:]\"']//g")"
  case "$s" in
    _a|a|A|0) echo "_a" ;;
    _b|b|B|1) echo "_b" ;;
    *) echo "" ;;
  esac
}

bootconfig_value() {
  key="$1"
  [ -r /proc/bootconfig ] || return 1
  awk -v k="$key" '
    $1 == k {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      gsub(/[[:space:]"]/, "", $0)
      print $0
      exit
    }
  ' /proc/bootconfig 2>/dev/null
}

cmdline_value() {
  key="$1"
  [ -r /proc/cmdline ] || return 1
  tr ' ' '\n' < /proc/cmdline 2>/dev/null |
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }'
}

slot_from_bootconfig() {
  normalize_slot "$(bootconfig_value androidboot.slot_suffix)"
}

slot_from_cmdline() {
  normalize_slot "$(cmdline_value androidboot.slot_suffix)"
}

slot_from_bootctl() {
  command -v bootctl >/dev/null 2>&1 || return 1
  normalize_slot "$(bootctl get-current-slot 2>/dev/null | head -n 1)"
}

slot_from_getprop() {
  s="$(getprop ro.boot.slot_suffix 2>/dev/null)"
  if [ -z "$s" ]; then
    s="$(getprop ro.boot.slot 2>/dev/null)"
  fi
  normalize_slot "$s"
}

slot_suffix() {
  for fn in slot_from_bootconfig slot_from_cmdline slot_from_bootctl slot_from_getprop; do
    s="$($fn 2>/dev/null)"
    case "$s" in
      _a|_b) echo "$s"; return 0 ;;
    esac
  done
  echo ""
}

slot_source() {
  s="$(slot_from_bootconfig 2>/dev/null)"
  [ -n "$s" ] && { echo "/proc/bootconfig"; return 0; }
  s="$(slot_from_cmdline 2>/dev/null)"
  [ -n "$s" ] && { echo "/proc/cmdline"; return 0; }
  s="$(slot_from_bootctl 2>/dev/null)"
  [ -n "$s" ] && { echo "bootctl"; return 0; }
  s="$(slot_from_getprop 2>/dev/null)"
  [ -n "$s" ] && { echo "getprop"; return 0; }
  echo "unknown"
}

# Return success (0) only when kernel/bootloader-derived slot sources disagree.
trusted_slot_conflict() {
  first=""
  for fn in slot_from_bootconfig slot_from_cmdline slot_from_bootctl; do
    s="$($fn 2>/dev/null)"
    [ -n "$s" ] || continue
    if [ -z "$first" ]; then
      first="$s"
    elif [ "$s" != "$first" ]; then
      return 0
    fi
  done
  return 1
}

# Android properties may be intentionally spoofed by root-hiding modules.
# This is diagnostic only and never a write blocker.
prop_slot_conflict() {
  selected="$(slot_suffix)"
  prop="$(slot_from_getprop 2>/dev/null)"
  [ -n "$selected" ] && [ -n "$prop" ] && [ "$selected" != "$prop" ]
}

slot_label() {
  case "$1" in _a) echo "A" ;; _b) echo "B" ;; *) echo "UNKNOWN" ;; esac
}

dtbo_family_label() {
  case "$1" in
    400) echo "PJX110_16.0.2.400" ;;
    301) echo "PJX110_16.0.1.301" ;;
    701) echo "PJX110_16.0.5.701" ;;
    1001) echo "PJX110_16.0.5.1001" ;;
    *) echo "UNKNOWN" ;;
  esac
}

stock_sha_for_family() {
  case "$1" in
    400) echo "$F400_STOCK_SHA" ;;
    301) echo "$F301_STOCK_SHA" ;;
    701) echo "$F701_STOCK_SHA" ;;
    1001) echo "$F1001_STOCK_SHA" ;;
    *) return 1 ;;
  esac
}

pps33_sha_for_family() {
  case "$1" in
    400) echo "$F400_PPS33_SHA" ;;
    301) echo "$F301_PPS33_SHA" ;;
    701) echo "$F701_PPS33_SHA" ;;
    1001) echo "$F1001_PPS33_SHA" ;;
    *) return 1 ;;
  esac
}

pps55_sha_for_family() {
  case "$1" in
    400) echo "$F400_PPS55_SHA" ;;
    301) echo "$F301_PPS55_SHA" ;;
    701) echo "$F701_PPS55_SHA" ;;
    1001) echo "$F1001_PPS55_SHA" ;;
    *) return 1 ;;
  esac
}

stock_image_for_family() {
  case "$1" in
    400) echo "$MODDIR/images/dtbo_400_stock.img" ;;
    301) echo "$MODDIR/images/dtbo_301_stock.img" ;;
    701) echo "$MODDIR/images/dtbo_701_stock.img" ;;
    1001) echo "$MODDIR/images/dtbo_1001_stock.img" ;;
    *) return 1 ;;
  esac
}

pps33_image_for_family() {
  case "$1" in
    400) echo "$MODDIR/images/dtbo_400_pps33.img" ;;
    301) echo "$MODDIR/images/dtbo_301_pps33.img" ;;
    701) echo "$MODDIR/images/dtbo_701_pps33.img" ;;
    1001) echo "$MODDIR/images/dtbo_1001_pps33.img" ;;
    *) return 1 ;;
  esac
}

pps55_image_for_family() {
  case "$1" in
    400) echo "$MODDIR/images/dtbo_400_pps55.img" ;;
    301) echo "$MODDIR/images/dtbo_301_pps55.img" ;;
    701) echo "$MODDIR/images/dtbo_701_pps55.img" ;;
    1001) echo "$MODDIR/images/dtbo_1001_pps55.img" ;;
    *) return 1 ;;
  esac
}

profile_sha_for_family() {
  family="$1"; profile="$2"
  case "$profile" in
    stock) stock_sha_for_family "$family" ;;
    pps33) pps33_sha_for_family "$family" ;;
    pps55) pps55_sha_for_family "$family" ;;
    *) return 1 ;;
  esac
}

profile_image_for_family() {
  family="$1"; profile="$2"
  case "$profile" in
    stock) stock_image_for_family "$family" ;;
    pps33) pps33_image_for_family "$family" ;;
    pps55) pps55_image_for_family "$family" ;;
    *) return 1 ;;
  esac
}

dtbo_family_for_hash() {
  hash="$1"
  case "$hash" in
    "$F400_STOCK_SHA"|"$F400_PPS33_SHA"|"$F400_PPS55_SHA") echo 400 ;;
    "$F301_STOCK_SHA"|"$F301_PPS33_SHA"|"$F301_PPS55_SHA") echo 301 ;;
    "$F701_STOCK_SHA"|"$F701_PPS33_SHA"|"$F701_PPS55_SHA") echo 701 ;;
    "$F1001_STOCK_SHA"|"$F1001_PPS33_SHA"|"$F1001_PPS55_SHA") echo 1001 ;;
    *) echo unknown; return 1 ;;
  esac
}

detect_profile_for_hash() {
  hash="$1"
  case "$hash" in
    "$F400_STOCK_SHA"|"$F301_STOCK_SHA"|"$F701_STOCK_SHA"|"$F1001_STOCK_SHA") echo stock ;;
    "$F400_PPS33_SHA"|"$F301_PPS33_SHA"|"$F701_PPS33_SHA"|"$F1001_PPS33_SHA") echo pps33 ;;
    "$F400_PPS55_SHA"|"$F301_PPS55_SHA"|"$F701_PPS55_SHA"|"$F1001_PPS55_SHA") echo pps55 ;;
    *) echo unknown; return 1 ;;
  esac
}

find_dtbo_block_for_slot() {
  slot="$1"
  case "$slot" in _a|_b) ;; *) return 1 ;; esac
  for p in     "/dev/block/by-name/dtbo${slot}"     "/dev/block/bootdevice/by-name/dtbo${slot}"     "/dev/block/mapper/dtbo${slot}"
  do
    [ -e "$p" ] || continue
    readlink -f "$p" 2>/dev/null || echo "$p"
    return 0
  done
  return 1
}

find_dtbo_block() {
  s="$(slot_suffix)"
  [ -n "$s" ] || return 1
  find_dtbo_block_for_slot "$s"
}

dump_block() {
  block="$1"; out="$2"
  rm -f "$out"
  dd if="$block" of="$out" bs=4194304 2>/dev/null
}

block_hash() {
  block="$1"
  # Hash the block device directly: avoids writing a 24 MiB temporary file.
  hash_file "$block"
}

current_hash() { block_hash "$1"; }

backup_stock() {
  block="$1"; slot="$2"; expected="$3"
  tmp="/data/local/tmp/PJX110_PPS_KSU_backup_$$.img"
  dump_block "$block" "$tmp" || return 1
  h="$(hash_file "$tmp")"
  if [ "$h" != "$expected" ]; then
    echo "[!] Refusing backup: slot $(slot_label "$slot") is not expected stock."
    rm -f "$tmp"; return 1
  fi
  cp -f "$tmp" "$BACKUP_DIR/dtbo${slot}_stock.img" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$BACKUP_DIR/dtbo${slot}_stock.img" 2>/dev/null
  if [ -d /sdcard ] || [ -e /sdcard ]; then
    mkdir -p /sdcard/Ace3Pro_PPS_Backup 2>/dev/null
    cp -f "$tmp" "/sdcard/Ace3Pro_PPS_Backup/dtbo${slot}_stock.img" 2>/dev/null || true
  fi
  rm -f "$tmp"
}

file_size_bytes() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

block_size_bytes() {
  block="$1"
  if command -v blockdev >/dev/null 2>&1; then
    blockdev --getsize64 "$block" 2>/dev/null && return 0
  fi
  return 1
}

write_verify() {
  image="$1"; expected="$2"; block="$3"; fallback="$4"; fallback_sha="$5"

  isz="$(file_size_bytes "$image")"
  bsz="$(block_size_bytes "$block")"
  if [ -n "$bsz" ] && [ "$isz" != "$bsz" ]; then
    echo "[!] Image/partition size mismatch: image=$isz block=$bsz"
    echo "[!] Refusing DTBO write."
    return 1
  fi

  ih="$(hash_file "$image")"
  [ "$ih" = "$expected" ] || { echo "[!] Embedded image hash mismatch; refusing write."; return 1; }

  echo "[*] Writing DTBO..."
  dd if="$image" of="$block" bs=4194304 2>/dev/null || return 1
  sync
  rh="$(block_hash "$block")" || rh=""
  if [ "$rh" = "$expected" ]; then
    echo "[+] DTBO readback verified: $rh"
    return 0
  fi

  echo "[!] Readback verification failed."
  if [ -n "$fallback" ] && [ -f "$fallback" ] && [ "$(hash_file "$fallback")" = "$fallback_sha" ]; then
    echo "[!] Attempting immediate exact-family stock restore..."
    dd if="$fallback" of="$block" bs=4194304 2>/dev/null
    sync
    rh="$(block_hash "$block")" || rh=""
    [ "$rh" = "$fallback_sha" ] && echo "[+] Stock DTBO restored." || echo "[!] WARNING: restore verification failed."
  fi
  return 1
}
