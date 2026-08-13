#!/system/bin/sh
BINDIR="${0%/*}"
MODDIR="${BINDIR%/bin}"
. "$MODDIR/common.sh"

clean() { printf '%s' "$1" | tr '\r\n=' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
kv() { k="$1"; shift; printf '%s=%s\n' "$k" "$(clean "$*")"; }

bc_flash="$(bootconfig_value androidboot.flash.locked 2>/dev/null)"
bc_vbmeta="$(bootconfig_value androidboot.vbmeta.device_state 2>/dev/null)"
cl_flash="$(cmdline_value androidboot.flash.locked 2>/dev/null)"
cl_vbmeta="$(cmdline_value androidboot.vbmeta.device_state 2>/dev/null)"
pr_flash="$(getprop ro.boot.flash.locked 2>/dev/null)"
pr_vbmeta="$(getprop ro.boot.vbmeta.device_state 2>/dev/null)"

summary="未知（仅供参考）"
trusted=""
for v in "$bc_vbmeta" "$cl_vbmeta"; do
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    unlocked) trusted="unlocked"; break ;;
    locked) [ -z "$trusted" ] && trusted="locked" ;;
  esac
done
if [ -z "$trusted" ]; then
  for v in "$bc_flash" "$cl_flash"; do
    case "$v" in
      0) trusted="unlocked"; break ;;
      1) [ -z "$trusted" ] && trusted="locked" ;;
    esac
  done
fi

case "$trusted" in
  unlocked) summary="底层来源显示解锁（仍仅供参考）" ;;
  locked) summary="底层来源显示锁定（仍仅供参考）" ;;
  *)
    case "$(printf '%s' "$pr_vbmeta" | tr '[:upper:]' '[:lower:]')" in
      unlocked) summary="Android 属性显示解锁（可被模块伪装）" ;;
      locked) summary="Android 属性显示锁定（可被模块伪装）" ;;
      *)
        case "$pr_flash" in
          0) summary="Android 属性显示解锁（可被模块伪装）" ;;
          1) summary="Android 属性显示锁定（可被模块伪装）" ;;
        esac
        ;;
    esac
    ;;
esac

conflict=0
case "$trusted" in
  unlocked)
    [ "$pr_flash" = "1" ] && conflict=1
    [ "$(printf '%s' "$pr_vbmeta" | tr '[:upper:]' '[:lower:]')" = "locked" ] && conflict=1
    ;;
  locked)
    [ "$pr_flash" = "0" ] && conflict=1
    [ "$(printf '%s' "$pr_vbmeta" | tr '[:upper:]' '[:lower:]')" = "unlocked" ] && conflict=1
    ;;
esac
[ "$conflict" = "1" ] && summary="$summary；与 Android 属性冲突/可能存在隐藏伪装"

kv boot_state "$summary"
kv boot_state_conflict "$conflict"
kv bootconfig_flash_locked "$bc_flash"
kv bootconfig_vbmeta_state "$bc_vbmeta"
kv cmdline_flash_locked "$cl_flash"
kv cmdline_vbmeta_state "$cl_vbmeta"
kv prop_flash_locked "$pr_flash"
kv prop_vbmeta_state "$pr_vbmeta"
