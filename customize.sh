#!/system/bin/sh
ui_print "----------------------------------------"
ui_print " Ace 3 Pro PPS Profiles v1.2.0"
ui_print " PJX110 / corvette"
ui_print " Tested: PJX110_16.0.2.400"
ui_print " Author: qimaoaa"
ui_print "----------------------------------------"

MODDIR="$MODPATH"
. "$MODPATH/common.sh"

if device_ok; then
  ui_print "[+] Device identity: PJX110/corvette detected."
else
  ui_print "[!] Device identity could not be confirmed; installation will continue."
  ui_print "[!] DTBO operations remain protected by WebUI device/hash checks."
fi

set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/templates" 0 0 0755 0644
set_perm_recursive "$MODPATH/rescue" 0 0 0755 0755

runtime_patch_assets_compatible || {
  ui_print "[!] Bundled DTBO patcher/template integrity check failed."
  exit 1
}

INSTALL_LOG="$MODPATH/.install-images.log"
sh "$MODPATH/bin/install_images.sh" > "$INSTALL_LOG" 2>&1
install_rc=$?
while IFS= read -r line; do ui_print "$line"; done < "$INSTALL_LOG"
rm -f "$INSTALL_LOG"
[ "$install_rc" -eq 0 ] || {
  ui_print "[!] Verified image-set extraction failed; installation aborted."
  exit 1
}

if trusted_slot_conflict; then
  ui_print "[!] A/B slot sources disagree; installation continues without DTBO access."
else
  slot="$(slot_suffix)"
  if [ -n "$slot" ]; then
    ui_print "[*] Current slot: $(slot_label "$slot") (source: $(slot_source))"
  else
    ui_print "[!] Active slot could not be determined during installation."
  fi
fi

ui_print ""
ui_print "[+] 19 firmware triplets: ColorOS 15 / 16, selected by exact DTBO SHA256."
ui_print "[+] Only the matching firmware's 72 MiB image triplet is kept after installation."
ui_print "[!] After OTA: reinstall for the new triplet, or manually validate the new stock DTBO in Patch Mode."
ui_print "[+] KernelSU Action button is intentionally disabled."
ui_print "[+] Installation does NOT modify DTBO."
ui_print "[+] All PPS/restore operations are available only inside WebUI."
ui_print "[+] Profiles: stock / PPS 33W / PPS 55W."
ui_print "[+] Other PJX110 firmware can use WebUI Patch Mode only after structural validation."
ui_print "[+] Patch -> Full is manual and one-way for the same DTBO generation."
ui_print "[+] Before any PPS write, an independent per-slot Recovery rescue snapshot is mandatory."
ui_print "[+] This project writes only the selected dtbo_a/dtbo_b partition and no other partition."
ui_print "[+] Every firmware retains its own complete AVB metadata/footer."
ui_print "[+] 33W / 55W confirmed only on PJX110_16.0.2.400."
ui_print "[!] All versions other than PJX110_16.0.2.400 are not hardware-tested."
ui_print "[!] 55W requires a 5A-capable PPS charger and cable."
ui_print "[!] Other firmware versions must pass DTBO hash/compatibility checks first."

ui_print "[*] Bootloader lock properties are advisory only; exact DTBO SHA is the write guard."
