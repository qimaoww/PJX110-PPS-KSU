#!/system/bin/sh
ui_print "----------------------------------------"
ui_print " Ace 3 Pro PPS v1.2.0"
ui_print "----------------------------------------"

MODDIR="$MODPATH"
. "$MODPATH/common.sh"

if device_ok; then
  ui_print "[+] 设备：一加 Ace 3 Pro（PJX110）"
else
  ui_print "[!] 未确认目标机型；是否允许操作以 WebUI 校验为准。"
fi

set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/templates" 0 0 0755 0644
set_perm_recursive "$MODPATH/rescue" 0 0 0755 0755

runtime_patch_assets_compatible || {
  ui_print "[!] 补丁工具或模板校验失败，安装终止。"
  exit 1
}

INSTALL_LOG="$MODPATH/.install-images.log"
sh "$MODPATH/bin/install_images.sh" > "$INSTALL_LOG" 2>&1
install_rc=$?
while IFS= read -r line; do ui_print "$line"; done < "$INSTALL_LOG"
rm -f "$INSTALL_LOG"
[ "$install_rc" -eq 0 ] || {
  ui_print "[!] 镜像提取或校验失败，安装终止。"
  exit 1
}

if trusted_slot_conflict; then
  ui_print "[!] 槽位来源冲突，禁止 DTBO 写入。"
else
  slot="$(slot_suffix)"
  if [ -n "$slot" ]; then
    ui_print "[*] 当前槽：$(slot_label "$slot")"
  else
    ui_print "[!] 无法确认活动槽，禁止 DTBO 写入。"
  fi
fi

ui_print ""
ui_print "[+] 安装完成。重启后打开模块 WebUI 选择档位。"
ui_print "[+] 档位操作仅写当前槽 DTBO，保留完整 AVB。"
ui_print "[!] 保持 Bootloader 解锁；仅 400 固件已实测。"
ui_print "[!] 55W 需要支持 5A PPS 的充电器与线材。"
