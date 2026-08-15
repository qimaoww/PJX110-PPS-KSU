#!/system/bin/sh
ui_print "----------------------------------------"
ui_print " Ace 3 Pro PPS Profiles v1.1.0"
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
ui_print "[+] Images selected by DTBO SHA256: .400 / .301 / 701 / 1001."
ui_print "[+] KernelSU Action button is intentionally disabled."
ui_print "[+] Installation does NOT modify DTBO."
ui_print "[+] All PPS/restore operations are available only inside WebUI."
ui_print "[+] Profiles: stock / PPS 33W / PPS 55W."
ui_print "[+] 33W / 55W confirmed only on PJX110_16.0.2.400."
ui_print "[!] .301 / 701 / 1001 PPS images are not hardware-tested."
ui_print "[!] 55W requires a 5A-capable PPS charger and cable."
ui_print "[!] Other firmware versions must pass DTBO hash/compatibility checks first."

ui_print "[*] Bootloader lock properties are advisory only; exact DTBO SHA is the write guard."
